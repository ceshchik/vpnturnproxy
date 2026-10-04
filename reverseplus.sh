#!/usr/bin/env bash
#
# setup-reverse-proxy.sh
# Интерактивно настраивает реверс-прокси в Nginx:
# - Для нового домена: получает сертификат Let's Encrypt и создаёт HTTPS-конфиг.
# - Для существующего домена: дополняет существующий конфиг новым location-блоком
#   (или заменяет существующий с подтверждения) без перезаписи всего файла.
#
# Использование: sudo ./setup-reverse-proxy.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root (sudo ./setup-reverse-proxy.sh)" >&2
  exit 1
fi

WEBROOT="/var/www/letsencrypt"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

# ---------- Вопросы пользователю ----------
read -rp "Домен (например panel.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Домен не может быть пустым" >&2
  exit 1
fi

CONF_FILE="$SITES_AVAILABLE/${DOMAIN}.conf"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

# Проверяем, существует ли уже конфигурация
CONFIG_EXISTS=0
if [[ -f "$CONF_FILE" ]]; then
  CONFIG_EXISTS=1
  echo
  echo "--> Обнаружен существующий конфиг: $CONF_FILE"
  echo "--> Режим: добавление/обновление блока location."
fi

# Запрос location
read -rp "Путь location (например / или /api/) [/]: " LOCATION_PATH
LOCATION_PATH="${LOCATION_PATH:-/}"

# Нормализуем: убираем пробелы по краям
LOCATION_PATH="$(echo "$LOCATION_PATH" | xargs)"

# Если путь не начинается со слэша или модификаторов nginx (=, ~, ^~, @), добавляем слэш
if [[ ! "$LOCATION_PATH" =~ ^(/|=|~|\^~|@) ]]; then
  LOCATION_PATH="/$LOCATION_PATH"
fi

# Запрос порта / адреса бэкенда
read -rp "Локальный порт бэкенда [8000]: " BACKEND_PORT
BACKEND_PORT="${BACKEND_PORT:-8000}"

# Формируем целевой URL для proxy_pass
if [[ "$BACKEND_PORT" =~ ^http://|^https:// ]]; then
  PROXY_TARGET="$BACKEND_PORT"
else
  PROXY_TARGET="http://127.0.0.1:${BACKEND_PORT}"
fi

# ---------- Установка необходимых пакетов ----------
if ! command -v nginx >/dev/null 2>&1; then
  echo "Устанавливаю nginx..."
  apt-get update -qq
  apt-get install -y nginx
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Устанавливаю python3..."
  apt-get update -qq
  apt-get install -y python3
fi

# ==============================================================================
# СЦЕНАРИЙ 1: КОНФИГ УЖЕ СУЩЕСТВУЕТ — ДОПОЛНЯЕМ НОВЫМ LOCATION
# ==============================================================================
if [[ "$CONFIG_EXISTS" -eq 1 ]]; then
  # Проверяем через Python, есть ли уже такой location в целевом блоке server
  CHECK_STATUS=$(python3 - "$CONF_FILE" "$DOMAIN" "$LOCATION_PATH" << 'PYEOF'
import sys, re

conf_file = sys.argv[1]
domain = sys.argv[2]
loc_path = sys.argv[3]

with open(conf_file, "r", encoding="utf-8") as f:
    content = f.read()

# Проверяем наличие директивы location с данным путем
loc_clean = " ".join(loc_path.strip().split())
escaped = re.escape(loc_clean)
pattern = rf"([ \t]*location\s+(?:[=~*^@]+\s+)?[\"']?{escaped}[\"']?(?:\s|\{{)[^\{{]*\{{)"

if re.search(pattern, content):
    print("EXISTS")
else:
    print("NOT_FOUND")
PYEOF
)

  OVERWRITE="false"
  if [[ "$CHECK_STATUS" == "EXISTS" ]]; then
    echo
    echo "Внимание: location '${LOCATION_PATH}' уже присутствует в ${CONF_FILE}."
    read -rp "Перезаписать существующий блок location? [y/N]: " CONFIRM_OVERWRITE
    if [[ ! "$CONFIRM_OVERWRITE" =~ ^[yY]([eE][sS])?$ ]]; then
      echo "Отменено пользователем. Конфигурация не изменена."
      exit 0
    fi
    OVERWRITE="true"
  fi

  # Создаем резервную копию перед модификацией
  BACKUP_FILE="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$CONF_FILE" "$BACKUP_FILE"
  echo "Создана резервная копия: $BACKUP_FILE"

  # Модифицируем файл через Python
  MODIFY_RESULT=$(python3 - "$CONF_FILE" "$DOMAIN" "$LOCATION_PATH" "$PROXY_TARGET" "$OVERWRITE" << 'PYEOF'
import sys, re

conf_file = sys.argv[1]
domain = sys.argv[2]
loc_path = sys.argv[3]
backend_target = sys.argv[4]
overwrite = sys.argv[5].lower() == "true"

with open(conf_file, "r", encoding="utf-8") as f:
    content = f.read()

def parse_server_blocks(text):
    blocks = []
    i = 0
    n = len(text)
    depth = 0
    body_start = -1
    full_start = 0
    in_comment = False
    in_quote = None
    last_server_kw = -1

    while i < n:
        c = text[i]
        if in_comment:
            if c == "\n":
                in_comment = False
            i += 1
            continue
        if in_quote:
            if c == in_quote and (i == 0 or text[i-1] != "\\"):
                in_quote = None
            i += 1
            continue
        if c == "#":
            in_comment = True
            i += 1
            continue
        if c in ("\"", "'"):
            in_quote = c
            i += 1
            continue

        if depth == 0:
            if text[i:i+6] == "server" and (i == 0 or not text[i-1].isalnum()) and not text[i+6].isalnum():
                last_server_kw = i

        if c == "{":
            if depth == 0:
                body_start = i
                full_start = last_server_kw if last_server_kw != -1 else i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and body_start != -1:
                blocks.append({
                    "full_start": full_start,
                    "body_start": body_start,
                    "end": i,
                    "content": text[full_start:i+1]
                })
                body_start = -1
                last_server_kw = -1
        i += 1
    return blocks

blocks = parse_server_blocks(content)
if not blocks:
    print("ERROR_NO_SERVER_BLOCKS")
    sys.exit(0)

# Приоритет выбора блока:
# 1. Блок с 443/ssl и указанным доменом
# 2. Блок с 443/ssl
# 3. Блок с доменом
# 4. Последний блок в файле
target = None
for b in blocks:
    c = b["content"]
    if ("443" in c or "ssl" in c) and domain in c:
        target = b
        break
if not target:
    for b in blocks:
        c = b["content"]
        if "443" in c or "ssl" in c:
            target = b
            break
if not target:
    for b in blocks:
        if domain in b["content"]:
            target = b
            break
if not target:
    target = blocks[-1]

loc_clean = " ".join(loc_path.strip().split())
escaped = re.escape(loc_clean)
pattern = rf"([ \t]*location\s+(?:[=~*^@]+\s+)?[\"']?{escaped}[\"']?(?:\s|\{{)[^\{{]*\{{)"

target_text = content[target["full_start"]:target["end"] + 1]
m = re.search(pattern, target_text)

new_block = f"""    location {loc_path} {{
        proxy_pass {backend_target};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }}"""

if m:
    if not overwrite:
        print("ALREADY_EXISTS")
        sys.exit(0)
    # Перезаписываем существующий location
    abs_start = target["full_start"] + m.start()
    depth = 1
    i = target["full_start"] + m.end()
    n = len(content)
    end = -1
    in_comment = False
    in_quote = None
    while i < n and depth > 0:
        c = content[i]
        if in_comment:
            if c == "\n":
                in_comment = False
            i += 1
            continue
        if in_quote:
            if c == in_quote and (i == 0 or content[i-1] != "\\"):
                in_quote = None
            i += 1
            continue
        if c == "#":
            in_comment = True
        elif c in ("\"", "'"):
            in_quote = c
            i += 1
            continue
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    new_content = content[:abs_start] + new_block.strip("\r\n") + content[end:]
    action = "UPDATED"
else:
    # Вставляем перед закрывающей скобкой } целевого блока
    insert_pos = target["end"]
    prefix = content[:insert_pos].rstrip()
    suffix = content[insert_pos:]
    new_content = prefix + "\n\n" + new_block.rstrip() + "\n" + suffix
    action = "ADDED"

with open(conf_file, "w", encoding="utf-8") as f:
    f.write(new_content)

print(action)
PYEOF
)

  if [[ "$MODIFY_RESULT" == "ERROR_NO_SERVER_BLOCKS" ]]; then
    echo "Ошибка: в файле $CONF_FILE не найдено блоков server { ... }" >&2
    exit 1
  fi

  # Убеждаемся, что симлинк включён
  mkdir -p "$SITES_ENABLED"
  ln -sf "$CONF_FILE" "$SITES_ENABLED/${DOMAIN}.conf"

  # Проверяем валидность конфигурации nginx
  echo "Проверяю синтаксис nginx..."
  if ! nginx -t; then
    echo "ОШИБКА: Конфигурация nginx некорректна! Восстанавливаю файл из резервной копии..." >&2
    cp "$BACKUP_FILE" "$CONF_FILE"
    nginx -t
    exit 1
  fi

  systemctl reload nginx

  echo
  if [[ "$MODIFY_RESULT" == "UPDATED" ]]; then
    echo "Готово! Location '${LOCATION_PATH}' успешно обновлен в ${CONF_FILE}."
  else
    echo "Готово! Новый location '${LOCATION_PATH}' успешно добавлен в ${CONF_FILE}."
  fi
  echo "Проксирование: ${DOMAIN}${LOCATION_PATH} -> ${PROXY_TARGET}"
  exit 0
fi

# ==============================================================================
# СЦЕНАРИЙ 2: НОВЫЙ ДОМЕН — ВЫПУСК СЕРТИФИКАТА И ПЕРВИЧНАЯ НАСТРОЙКА
# ==============================================================================
read -rp "E-mail для Let's Encrypt (Enter — пропустить): " LE_EMAIL

if [[ "$DOMAIN" == *.ru ]]; then
  echo
  echo "ВНИМАНИЕ: Let's Encrypt и ZeroSSL по политике блокируют выпуск для доменов .ru"
  echo "(rejectedIdentifier). Certbot ниже, скорее всего, завершится ошибкой."
  echo "Рабочий вариант в этом случае — ACME-клиент с ZeroSSL/Google Trust Services"
  echo "через EAB-ключи, либо выпуск на поддомен не в зоне .ru."
  read -rp "Продолжить всё равно? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]] || exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "Устанавливаю certbot..."
  apt-get update -qq
  apt-get install -y certbot
fi

mkdir -p "$WEBROOT"
mkdir -p "$SITES_AVAILABLE"
mkdir -p "$SITES_ENABLED"

# ---------- Определяем синтаксис http2 под установленную версию nginx ----------
NGINX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
NGINX_MAJOR="$(echo "$NGINX_VER" | cut -d. -f1)"
NGINX_MINOR="$(echo "$NGINX_VER" | cut -d. -f2)"

# начиная с 1.25.1 директива "listen ... http2" устарела в пользу "http2 on;"
USE_NEW_HTTP2_SYNTAX=0
if [[ "$NGINX_MAJOR" -gt 1 ]] || { [[ "$NGINX_MAJOR" -eq 1 ]] && [[ "$NGINX_MINOR" -ge 25 ]]; }; then
  USE_NEW_HTTP2_SYNTAX=1
fi

# ---------- Шаг 1: временный HTTP-конфиг для ACME challenge ----------
cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "$CONF_FILE" "$SITES_ENABLED/${DOMAIN}.conf"

nginx -t
systemctl reload nginx

# ---------- Шаг 2: получение сертификата ----------
CERTBOT_ARGS=(certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos)
if [[ -n "$LE_EMAIL" ]]; then
  CERTBOT_ARGS+=(--email "$LE_EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

echo "Получаю сертификат для ${DOMAIN}..."
certbot "${CERTBOT_ARGS[@]}"

if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  echo "Сертификат не получен, конфиг остаётся в HTTP-режиме. Смотри вывод certbot выше." >&2
  exit 1
fi

# ---------- Шаг 3: финальный HTTPS-конфиг с reverse proxy ----------
if [[ "$USE_NEW_HTTP2_SYNTAX" -eq 1 ]]; then
  LISTEN_LINE="    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
else
  LISTEN_LINE="    listen 443 ssl http2;
    listen [::]:443 ssl http2;"
fi

cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
${LISTEN_LINE}
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    location ${LOCATION_PATH} {
        proxy_pass ${PROXY_TARGET};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

nginx -t
systemctl reload nginx

echo
echo "Готово. ${DOMAIN}${LOCATION_PATH} -> ${PROXY_TARGET} (проксирование через nginx)."
echo "Конфиг: ${CONF_FILE}"
echo "Автопродление сертификата обычно уже настроено через systemd-таймер certbot"
echo "(проверить: systemctl list-timers | grep certbot)."
