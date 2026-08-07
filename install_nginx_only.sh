#!/usr/bin/env bash
#
# Nginx decoy site + grpc_pass фронт для VLESS/XHTTP — установщик.
#
# Скрипт НЕ устанавливает и не настраивает Xray — только nginx.
# Вы сами поднимаете Xray с любым inbound (VLESS/XHTTP), который слушает
# unix-сокет /dev/shm/xrxh.socket (права 0666), выведенный в конце скрипта.
#
# Что делает скрипт:
#   1. Ставит nginx, certbot
#   2. Разворачивает статическую "CDN"-заглушку на 80/443
#   3. Получает Let's Encrypt сертификат (webroot-метод)
#   4. Спрашивает у вас секретный path
#   5. Пишет nginx-конфиг: "/" -> заглушка, path -> grpc_pass unix:/dev/shm/xrxh.socket
#   6. Печатает домен, path и путь к сокету, который нужно указать в "listen"
#      вашего Xray-инбаунда (например "/dev/shm/xrxh.socket,0666")
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

if [[ -z "${DOMAIN}" || -z "${LE_EMAIL}" || -z "${XPATH_INPUT}" ]]; then
  echo "Домен, e-mail и path обязательны." >&2
  exit 1
fi

# Нормализуем path: гарантируем "/" в начале и в конце
XPATH="${XPATH_INPUT}"
[[ "${XPATH}" != /* ]] && XPATH="/${XPATH}"
[[ "${XPATH}" != */ ]] && XPATH="${XPATH}/"

# Unix-сокет, на который nginx будет проксировать xhttp. Тот же путь и права
# (,0666) нужно указать в "listen" вашего Xray-инбаунда:
# "listen": "/dev/shm/xrxh.socket,0666"
SOCK="/dev/shm/xrxh.socket"

WEBROOT="/var/www/${DOMAIN}"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"

echo
echo "== Параметры =="
echo "Домен:       ${DOMAIN}"
echo "Path:        ${XPATH}"
echo "Unix-сокет:  ${SOCK} (права 0666)"
echo

# ---------------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot curl openssl ufw

# ---------------------------------------------------------------------------
# 2. Статическая "CDN"-заглушка
# ---------------------------------------------------------------------------
mkdir -p "${WEBROOT}"
cat > "${WEBROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Static Asset Node</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:#0b0d12;color:#c9d1d9;
       display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
  .box{text-align:center;max-width:520px;padding:2rem}
  h1{font-size:1.4rem;font-weight:600;letter-spacing:.02em;color:#e6edf3}
  p{color:#8b949e;line-height:1.5}
  code{background:#161b22;padding:.15rem .4rem;border-radius:4px;font-size:.85em}
</style>
</head>
<body>
  <div class="box">
    <h1>Edge node online</h1>
    <p>This host serves static assets for an internal content-delivery pool.
    Direct browsing is not supported — requests are expected to include a
    valid signed <code>Origin</code> path.</p>
  </div>
</body>
</html>
HTML

mkdir -p "${WEBROOT}/.well-known/acme-challenge"

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

    # Секретный путь XHTTP -> unix-сокет вашего Xray-инбаунда
    location ${XPATH} {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:${SOCK};
    }

    # Скрытые/служебные файлы — не отдавать
    location ~ /\. {
        deny all;
    }

    # Всё остальное — обычная заглушка "CDN"
    location / {
        try_files \$uri \$uri/ =404;
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
echo "Домен:            ${DOMAIN}"
echo "Path:              ${XPATH}"
echo "Nginx site:        ${NGINX_SITE}"
echo
echo "В inbound вашего Xray укажите:"
echo "  \"listen\": \"${SOCK},0666\","
echo "  streamSettings.xhttpSettings.path = \"${XPATH}\""
echo "======================================================================"
