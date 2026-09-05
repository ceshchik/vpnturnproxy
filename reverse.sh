#!/usr/bin/env bash
#
# Nginx decoy site + grpc_pass фронт для VLESS/XHTTP — установщик.
#
# Скрипт НЕ устанавливает и не настраивает Xray — только nginx.
# Вы сами поднимаете Xray с любым inbound (VLESS/XHTTP), который слушает
# локальный порт (например 127.0.0.1:10000), указанный в конце скрипта.
#
# Что делает скрипт:
#   1. Ставит nginx, certbot
#   2. Разворачивает статическую "CDN"-заглушку на 80/443
#   3. Получает Let's Encrypt сертификат (webroot-метод)
#   4. Спрашивает у вас секретный path и порт Xray
#   5. Пишет nginx-конфиг: "/" -> заглушка, path -> grpc_pass 127.0.0.1:PORT
#   6. Печатает домен, path и порт, который нужно указать в "listen"
#      вашего Xray-инбаунда (например "127.0.0.1:10000")
#
# Запускать от root на чистом Ubuntu/Debian.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Проверки и ввод параметров
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Запускайте от root: sudo bash $0" >&2
  exit 1
fi

read -rp "Домен (уже указывает A/AAAA-записью на этот сервер): " DOMAIN
read -rp "E-mail для Let's Encrypt (для уведомлений об истечении сертификата): " LE_EMAIL
read -rp "Секретный path для XHTTP (например /assets/abc123/, можно без слэшей — добавлю сам): " XPATH_INPUT
read -rp "Локальный порт Xray (например 10000): " XRAY_PORT

if [[ -z "${DOMAIN}" || -z "${LE_EMAIL}" || -z "${XPATH_INPUT}" || -z "${XRAY_PORT}" ]]; then
  echo "Домен, e-mail, path и порт обязательны." >&2
  exit 1
fi

# Проверка что порт - число
if ! [[ "${XRAY_PORT}" =~ ^[0-9]+$ ]] || [[ "${XRAY_PORT}" -lt 1 || "${XRAY_PORT}" -gt 65535 ]]; then
  echo "Порт должен быть числом от 1 до 65535" >&2
  exit 1
fi

# Нормализуем path: гарантируем "/" в начале и в конце
XPATH="${XPATH_INPUT}"
[[ "${XPATH}" != /* ]] && XPATH="/${XPATH}"
[[ "${XPATH}" != */ ]] && XPATH="${XPATH}/"

# Адрес для подключения nginx к Xray
XRAY_BACKEND="127.0.0.1:${XRAY_PORT}"

WEBROOT="/var/www/${DOMAIN}"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"

echo
echo "== Параметры =="
echo "Домен:           ${DOMAIN}"
echo "Path:            ${XPATH}"
echo "Xray backend:    ${XRAY_BACKEND}"
echo

# ---------------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot curl openssl ufw

# ---------------------------------------------------------------------------
# 2. Статическая "CDN"-заглушка
# --------------------------------

# ---------------------------------------------------------------------------
# 3. Временный HTTP-вхост для выпуска сертификата (webroot)
# ---------------------------------------------------------------------------
cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf "${NGINX_SITE}" "${NGINX_SITE_LINK}"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl reload nginx || systemctl restart nginx

# ---------------------------------------------------------------------------
# 4. Сертификат Let's Encrypt
# ---------------------------------------------------------------------------
certbot certonly --webroot -w "${WEBROOT}" \
  -d "${DOMAIN}" \
  -m "${LE_EMAIL}" \
  --agree-tos --non-interactive --no-eff-email

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "Сертификат не выпущен — проверьте DNS-запись домена и вывод certbot выше." >&2
  exit 1
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ---------------------------------------------------------------------------
# 5. Полный nginx-конфиг: TLS + decoy + grpc_pass на локальный порт Xray
# ---------------------------------------------------------------------------
cat > "${NGINX_SITE}" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    server_tokens off;
    client_header_timeout 5m;
    keepalive_timeout 5m;

    # Секретный путь XHTTP -> локальный порт вашего Xray-инбаунда
    location ${XPATH} {
        proxy_pass http://${XRAY_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        client_body_timeout 5m;
        client_max_body_size 0;
    }
}

# HTTP -> редирект на HTTPS (ACME challenge оставляем живым для продления)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

nginx -t
systemctl restart nginx

# ---------------------------------------------------------------------------
# 6. Firewall
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 7. Итог
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " Nginx настроен. Xray нужно поднять отдельно."
echo "======================================================================"
echo "Домен:             ${DOMAIN}"
echo "Path:              ${XPATH}"
echo "Nginx site:        ${NGINX_SITE}"
echo
echo "В inbound вашего Xray укажите:"
echo "  \"listen\": \"${XRAY_BACKEND}\","
echo "  \"protocol\": \"vless\" (или другой),"
echo "  streamSettings.network = \"grpc\","
echo "  streamSettings.grpcSettings.serviceName = \"${XPATH%/}\""
echo
echo "Пример конфига Xray inbound:"
echo "{"
echo "  \"listen\": \"${XRAY_BACKEND}\","
echo "  \"protocol\": \"vless\","
echo "  \"settings\": { ... },"
echo "  \"streamSettings\": {"
echo "    \"network\": \"grpc\","
echo "    \"grpcSettings\": {"
echo "      \"serviceName\": \"${XPATH%/}\""
echo "    }"
echo "  }"
echo "}"
echo "======================================================================"
