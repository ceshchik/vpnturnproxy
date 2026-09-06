#!/usr/bin/env bash
#
# setup-reverse-proxy.sh
# Интерактивно спрашивает домен и локальный порт, получает сертификат
# Let's Encrypt (certbot, webroot-метод) и ставит nginx-конфиг реверс-прокси.
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

read -rp "Локальный порт бэкенда [8000]: " BACKEND_PORT
BACKEND_PORT="${BACKEND_PORT:-8000}"

read -rp "E-mail для Let's Encrypt (Enter — пропустить): " LE_EMAIL

if [[ "$DOMAIN" == *.ru ]]; then
  echo
  echo "ВНИМАНИЕ: Let's Encrypt и ZeroSSL по политике блокируют выпуск для доменов .ru"
  echo "(rejectedIdentifier). Certbot ниже, скорее всего, завершится ошибкой."
  echo "Рабочий вариант в этом случае — ACME-клиент с ZeroSSL/Google Trust Services"
  echo "через EAB-ключи, либо выпуск на поддомен не в зоне .ru."
  read -rp "Продолжить всё равно? [y/N]: " CONFIRM
  [[ "${CONFIRM,,}" == "y" ]] || exit 1
fi

CONF_FILE="$SITES_AVAILABLE/${DOMAIN}.conf"

# ---------- Установка пакетов ----------
if ! command -v nginx >/dev/null 2>&1; then
  echo "Устанавливаю nginx..."
  apt-get update -qq
  apt-get install -y nginx
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "Устанавливаю certbot..."
  apt-get update -qq
  apt-get install -y certbot
fi

mkdir -p "$WEBROOT"

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

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
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

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
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
echo "Готово. ${DOMAIN} -> https://127.0.0.1:${BACKEND_PORT} (проксирование через nginx)."
echo "Конфиг: ${CONF_FILE}"
echo "Автопродление сертификата обычно уже настроено через systemd-таймер certbot"
echo "(проверить: systemctl list-timers | grep certbot)."
