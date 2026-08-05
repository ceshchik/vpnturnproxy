#!/usr/bin/env bash
#
# vk-turn-proxy + WireGuard — установка и управление клиентами.
#
# Использование:
#   ./vk-turn-proxy-setup.sh install
#   ./vk-turn-proxy-setup.sh add-client "<ссылка на VK-звонок>" [номер_ip]
#   ./vk-turn-proxy-setup.sh uninstall
#
# Пример:
#   ./vk-turn-proxy-setup.sh install
#   ./vk-turn-proxy-setup.sh add-client "https://vk.ru/call/join/xxxxxxxx" 2
#   ./vk-turn-proxy-setup.sh add-client "https://vk.ru/call/join/yyyyyyyy" 3
#
# Запускать от root на самом VPS.

set -euo pipefail

WG_IF="wg-vk"
WG_SUBNET="192.168.200"
WG_PORT="51820"
VKT_PORT="56000"
VKT_DIR="/opt/vk-turn-proxy"
WG_CONF="/etc/wireguard/${WG_IF}.conf"

log() { echo -e "\n== $* =="; }

detect_iface() {
    ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'
}

detect_pubip() {
    curl -4 -s ifconfig.me
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unsupported" ;;
    esac
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Запусти от root (sudo -i, затем повторно запусти скрипт)." >&2
        exit 1
    fi
}

cmd_install() {
    require_root

    log "Определение окружения"
    IFACE=$(detect_iface)
    ARCH=$(detect_arch)
    [ "$ARCH" = "unsupported" ] && { echo "Неизвестная архитектура: $(uname -m)"; exit 1; }
    echo "Внешний интерфейс: $IFACE"
    echo "Архитектура: $ARCH"

    log "Установка пакетов"
    apt update
    apt install -y wireguard curl python3

    log "Генерация ключей и конфига WireGuard"
    umask 077
    SERVER_PRIV=$(wg genkey)
    mkdir -p /etc/wireguard
    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_SUBNET}.1/24
ListenPort = $WG_PORT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o $IFACE -j MASQUERADE
PostUp = iptables -I FORWARD -i $WG_IF -j ACCEPT
PostUp = iptables -I FORWARD -o $WG_IF -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT
PostDown = iptables -D FORWARD -o $WG_IF -j ACCEPT
EOF
    # ^ MASQUERADE + явный ACCEPT в FORWARD — на VPS с уже настроенным
    #   прокси-стеком (Xray и т.п.) политика FORWARD нередко DROP по умолчанию.

    log "Форвардинг пакетов (постоянно)"
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    sysctl --system > /dev/null

    log "Поднятие интерфейса"
    wg-quick down "$WG_IF" 2>/dev/null || true
    wg-quick up "$WG_IF"
    systemctl enable "wg-quick@${WG_IF}" > /dev/null

    log "Скачивание vk-turn-proxy (server-linux-${ARCH})"
    mkdir -p "$VKT_DIR" && cd "$VKT_DIR"
    curl -L -o "server-linux-${ARCH}" \
        "https://github.com/anton48/vk-turn-proxy/releases/latest/download/server-linux-${ARCH}"
    chmod +x "server-linux-${ARCH}"

    PUBIP=$(detect_pubip)
    echo "Публичный IP сервера: $PUBIP"

    log "Настройка systemd-сервиса vk-turn-proxy"
    cat > /etc/systemd/system/vk-turn-proxy.service <<EOF
[Unit]
Description=vk-turn-proxy server
After=network.target wg-quick@${WG_IF}.service

[Service]
ExecStart=${VKT_DIR}/server-linux-${ARCH} -listen 0.0.0.0:${VKT_PORT} -connect 127.0.0.1:${WG_PORT} -srtp -logfile /var/log/srtp.server.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now vk-turn-proxy

    log "Скачивание quick_link.py"
    curl -L -o "${VKT_DIR}/quick_link.py" \
        "https://raw.githubusercontent.com/anton48/vk-turn-proxy-ios/main/quick_link.py"

    cat <<EOF

====================================================================
Готово.

  Публичный адрес vk-turn-proxy: ${PUBIP}:${VKT_PORT}

Не забудь открыть порт ${VKT_PORT} (TCP и UDP) в firewall/security group.

Дальше добавляй клиентов:
  $0 add-client "<ссылка на VK-звонок>" [номер_ip, по умолчанию 2]
====================================================================
EOF
}

cmd_add_client() {
    require_root

    local VK_LINK="${1:?Укажи ссылку VK-звонка первым аргументом}"
    local SUFFIX="${2:-2}"

    [ -f "$WG_CONF" ] || { echo "Не найден $WG_CONF — сначала выполни: $0 install" >&2; exit 1; }
    [ -f "${VKT_DIR}/quick_link.py" ] || { echo "Не найден quick_link.py — сначала выполни: $0 install" >&2; exit 1; }

    local SERVER_PUB PUBIP DUMMY_PRIV
    SERVER_PUB=$(wg show "$WG_IF" public-key)
    PUBIP=$(detect_pubip)
    DUMMY_PRIV=$(wg genkey)
    # ^ на случай, если CONFIG.privateKey должен быть валидным base64-ключом
    #   ещё до генерации: -gen-peer-key всё равно перезапишет его своим.

    cd "$VKT_DIR"

    log "Заполнение CONFIG в quick_link.py"
    # Заменяем значения по имени ключа (что бы там ни стояло — REPLACE_ME
    # или прошлый вызов), удаляем строку presharedKey целиком (не обязательна).
    sed -i -E "s|(\"peerAddress\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${PUBIP}:${VKT_PORT}\2|" quick_link.py
    sed -i -E "s|(\"peerPublicKey\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${SERVER_PUB}\2|" quick_link.py
    sed -i -E "s|(\"vkLink\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${VK_LINK}\2|" quick_link.py
    sed -i -E "s|(\"privateKey\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${DUMMY_PRIV}\2|" quick_link.py
    sed -i -E '/"presharedKey"[[:space:]]*:[[:space:]]*"[^"]*",?/d' quick_link.py

    log "Генерация ключей клиента (192.168.200.${SUFFIX}/24)"
    OUTPUT=$(python3 quick_link.py -gen-peer-key "192.168.200.${SUFFIX}/24")
    echo "$OUTPUT"

    echo "$OUTPUT" | awk '/^\[Peer\]/{flag=1} flag' >> "$WG_CONF"

    log "Применение конфига без разрыва туннеля"
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")

    cat <<EOF

====================================================================
Клиент добавлен: 192.168.200.${SUFFIX}/24

Ссылка vkturnproxy://import?data=... выше — открой её на iPhone
(или Settings → Import from connection link в приложении).
====================================================================
EOF
}

cmd_uninstall() {
    require_root

    echo "Будут удалены:"
    echo "  - сервис vk-turn-proxy (systemd) и бинарник в ${VKT_DIR}"
    echo "  - интерфейс ${WG_IF} и файл ${WG_CONF} (вместе с ключами и списком клиентов)"
    echo "  - файл /etc/sysctl.d/99-wireguard.conf"
    read -r -p "Продолжить? [y/N] " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) echo "Отменено."; exit 0 ;;
    esac

    log "Остановка и удаление vk-turn-proxy"
    systemctl disable --now vk-turn-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/vk-turn-proxy.service
    systemctl daemon-reload

    log "Остановка и удаление WireGuard-интерфейса"
    wg-quick down "$WG_IF" 2>/dev/null || true
    systemctl disable "wg-quick@${WG_IF}" 2>/dev/null || true
    rm -f "$WG_CONF"

    log "Удаление файлов"
    rm -rf "$VKT_DIR"
    rm -f /etc/sysctl.d/99-wireguard.conf

    cat <<EOF

====================================================================
Готово. vk-turn-proxy и интерфейс ${WG_IF} удалены.

Не тронуто (удали вручную при необходимости):
  - пакет wireguard (apt remove wireguard, если больше не нужен)
  - открытый порт ${VKT_PORT} в firewall/security group
  - net.ipv4.ip_forward=1 в реальном ядре до перезагрузки
    (если forwarding нужен другим сервисам на сервере — не трогай)
====================================================================
EOF
}

case "${1:-}" in
    install)
        cmd_install
        ;;
    add-client)
        shift
        cmd_add_client "$@"
        ;;
    uninstall)
        cmd_uninstall
        ;;
    *)
        echo "Использование:"
        echo "  $0 install"
        echo "  $0 add-client \"<ссылка на VK-звонок>\" [номер_ip]"
        echo "  $0 uninstall"
        exit 1
        ;;
esac