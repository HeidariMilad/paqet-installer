#!/bin/bash
set -e

#===============================================================================
# PAQET MIDDLE VPS — DaaS ENTRYPOINT
#
# Supports two VLESS modes:
#   REALITY_TRANSPORT=tcp  → VLESS Reality (needs raw TCP port access)
#   REALITY_TRANSPORT=ws   → VLESS WebSocket (works behind DaaS HTTP proxy)
#
# Required env: SERVER_IP, SERVER_PORT, SECRET_KEY
# Optional env: REALITY_PORT, REALITY_SNI, REALITY_TRANSPORT, INITIAL_USER,
#               DAAS_DOMAIN, DAAS_PORT, WS_PATH, PAQET_VERSION
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Configuration ────────────────────────────────────────────────────────────
DATA_DIR="/opt/data"
PAQET_VERSION="${PAQET_VERSION:-v1.0.0-alpha.14}"
REALITY_PORT="${REALITY_PORT:-8443}"
REALITY_SNI="${REALITY_SNI:-www.google.com}"
REALITY_TRANSPORT="${REALITY_TRANSPORT:-tcp}"
INITIAL_USER="${INITIAL_USER:-default}"
WS_PATH="${WS_PATH:-/vless-ws}"

mkdir -p "$DATA_DIR"

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$SERVER_IP" || "$SERVER_IP" == "CHANGE_ME" ]]; then
    log_error "SERVER_IP is not set! Edit your docker-compose.yml"
    exit 1
fi
if [[ -z "$SECRET_KEY" || "$SECRET_KEY" == "CHANGE_ME" ]]; then
    log_error "SECRET_KEY is not set! Edit your docker-compose.yml"
    exit 1
fi
SERVER_PORT="${SERVER_PORT:-9999}"

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║          Paqet Middle VPS — DaaS Edition Starting...            ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
log_info "Server: $SERVER_IP:$SERVER_PORT"
log_info "Mode: $REALITY_TRANSPORT | Port: $REALITY_PORT"
[[ "$REALITY_TRANSPORT" == "ws" ]] && log_info "WebSocket: domain=${DAAS_DOMAIN:-auto} path=$WS_PATH"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Install dependencies & download binaries
# ══════════════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_info "Installing system dependencies..."
    apt-get update -qq
    apt-get install -y -qq libpcap-dev iproute2 iptables jq openssl curl ca-certificates > /dev/null 2>&1
    log_success "Dependencies installed"
}

download_paqet() {
    if [[ -f "$DATA_DIR/paqet" ]]; then
        log_success "paqet binary found (cached)"
        return
    fi
    log_info "Downloading paqet $PAQET_VERSION..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)         PA="linux-amd64" ;;
        aarch64|arm64)  PA="linux-arm64" ;;
        *)              PA="linux-amd64" ;;
    esac
    curl -sL "https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-${PA}-${PAQET_VERSION}.tar.gz" -o /tmp/paqet.tar.gz
    tar -xzf /tmp/paqet.tar.gz -C /tmp/
    BIN=$(ls /tmp/paqet* 2>/dev/null | grep -v ".tar.gz" | head -1)
    [[ -n "$BIN" ]] && mv "$BIN" "$DATA_DIR/paqet"
    chmod +x "$DATA_DIR/paqet"
    rm -f /tmp/paqet.tar.gz
    log_success "paqet downloaded"
}

download_singbox() {
    if [[ -f "$DATA_DIR/sing-box" ]]; then
        log_success "sing-box binary found (cached)"
        return
    fi
    log_info "Downloading sing-box (latest)..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SA="amd64" ;;
        aarch64|arm64) SA="arm64" ;;
        *)       SA="amd64" ;;
    esac
    SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
    if [[ -z "$SB_VERSION" || "$SB_VERSION" == "null" ]]; then
        SB_VERSION="1.11.3"
        log_warn "Could not fetch latest sing-box version, using $SB_VERSION"
    fi
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${SA}.tar.gz" -o /tmp/singbox.tar.gz
    tar -xzf /tmp/singbox.tar.gz -C /tmp/
    mv /tmp/sing-box-*/sing-box "$DATA_DIR/sing-box"
    chmod +x "$DATA_DIR/sing-box"
    rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*
    log_success "sing-box $SB_VERSION downloaded"
}

install_dependencies
download_paqet
download_singbox

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Auto-detect network
# ══════════════════════════════════════════════════════════════════════════════

log_info "Detecting network configuration..."

INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
[[ -z "$INTERFACE" ]] && INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)

LOCAL_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

GATEWAY_IP=$(ip route | grep default | head -1 | awk '{print $3}')
ping -c 1 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $5}' | head -1)
[[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "FAILED" ]] && \
    GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | grep -v Address | awk '{print $3}' | head -1)

if [[ -z "$INTERFACE" || -z "$LOCAL_IP" || -z "$GATEWAY_MAC" ]]; then
    log_error "Network detection failed: iface=$INTERFACE ip=$LOCAL_IP gwmac=$GATEWAY_MAC"
    exit 1
fi
log_success "Network: iface=$INTERFACE ip=$LOCAL_IP gw_mac=$GATEWAY_MAC"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Setup iptables (may fail in K8s — that's OK)
# ══════════════════════════════════════════════════════════════════════════════

log_info "Configuring iptables for port $SERVER_PORT..."
iptables -t raw -D PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -D OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true
iptables -t raw -A PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK 2>/dev/null || log_warn "iptables failed (normal in K8s)"
iptables -t raw -A OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true
log_success "iptables done"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Create paqet client config
# ══════════════════════════════════════════════════════════════════════════════

log_info "Writing paqet client config..."
cat > "$DATA_DIR/paqet-config.yaml" << PAQETCFG
role: "client"
log:
  level: "info"
socks5:
  - listen: "127.0.0.1:1080"
network:
  interface: "${INTERFACE}"
  ipv4:
    addr: "${LOCAL_IP}:0"
    router_mac: "${GATEWAY_MAC}"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "${SERVER_IP}:${SERVER_PORT}"
transport:
  protocol: "kcp"
  conn: 1
  kcp:
    mode: "fast"
    key: "${SECRET_KEY}"
PAQETCFG
log_success "paqet config written"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create sing-box config (first run only)
# ══════════════════════════════════════════════════════════════════════════════

if [[ ! -f "$DATA_DIR/sing-box-config.json" ]]; then

    UUID=$("$DATA_DIR/sing-box" generate uuid)
    echo "$UUID" > "$DATA_DIR/uuid"

    # Detect public IP
    PUBLIC_IP=""
    for url in https://ifconfig.me https://api.ipify.org https://checkip.amazonaws.com https://ipv4.icanhazip.com; do
        PUBLIC_IP=$(curl -4 -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        echo "$PUBLIC_IP" | grep -qP '^\d+\.\d+\.\d+\.\d+$' && break
        PUBLIC_IP=""
    done
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
    echo "$PUBLIC_IP" > "$DATA_DIR/public_ip"

    if [[ "$REALITY_TRANSPORT" == "ws" ]]; then
        # ────────────────────────────────────────────────────────────────
        # WEBSOCKET MODE — for DaaS behind HTTP/HTTPS proxy
        # No TLS (proxy handles it), no Reality, no flow
        # ────────────────────────────────────────────────────────────────
        log_info "Generating VLESS WebSocket config (DaaS mode)..."

        DAAS_DOMAIN="${DAAS_DOMAIN:-$PUBLIC_IP}"
        DAAS_PORT="${DAAS_PORT:-443}"

        cat > "$DATA_DIR/sing-box-config.json" << SINGCFG
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": ${REALITY_PORT},
    "users": [{ "uuid": "${UUID}", "name": "${INITIAL_USER}" }],
    "transport": { "type": "ws", "path": "${WS_PATH}" }
  }],
  "outbounds": [
    { "type": "socks", "tag": "paqet-proxy", "server": "127.0.0.1", "server_port": 1080 },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "paqet-proxy" }
}
SINGCFG

        VLESS_URL="vless://${UUID}@${DAAS_DOMAIN}:${DAAS_PORT}?encryption=none&security=tls&sni=${DAAS_DOMAIN}&type=ws&host=${DAAS_DOMAIN}&path=${WS_PATH}#paqet-middle"

        cat > "$DATA_DIR/user-config.txt" << USERCFG

╔═══════════════════════════════════════════════════════════════════════════════╗
║              VLESS WebSocket — Client Configuration (DaaS)                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

  User:        ${INITIAL_USER}
  Domain:      ${DAAS_DOMAIN}

  VLESS URL (paste into Shadowrocket / v2rayNG):
  ──────────────────────────────────────────────
  ${VLESS_URL}

  Manual Config (Shadowrocket):
  ─────────────────────────────
    Address:     ${DAAS_DOMAIN}
    Port:        ${DAAS_PORT}
    UUID:        ${UUID}
    Security:    tls
    SNI:         ${DAAS_DOMAIN}
    Transport:   ws
    WS Host:     ${DAAS_DOMAIN}
    WS Path:     ${WS_PATH}

  Traffic Chain:
  ──────────────
    Your Device → DaaS (VLESS WS :${DAAS_PORT}) → paqet → Server (:${SERVER_PORT})

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
        log_success "VLESS WebSocket config generated"

    else
        # ────────────────────────────────────────────────────────────────
        # REALITY MODE — for raw TCP port access
        # ────────────────────────────────────────────────────────────────
        log_info "Generating VLESS Reality config..."

        KEYPAIR=$("$DATA_DIR/sing-box" generate reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $NF}')
        SHORT_ID=$(openssl rand -hex 8)
        echo "$PUBLIC_KEY" > "$DATA_DIR/public_key"
        echo "$PRIVATE_KEY" > "$DATA_DIR/private_key"
        echo "$SHORT_ID" > "$DATA_DIR/short_id"

        cat > "$DATA_DIR/sing-box-config.json" << SINGCFG
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": ${REALITY_PORT},
    "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision", "name": "${INITIAL_USER}" }],
    "tls": {
      "enabled": true,
      "server_name": "${REALITY_SNI}",
      "reality": {
        "enabled": true,
        "handshake": { "server": "${REALITY_SNI}", "server_port": 443 },
        "private_key": "${PRIVATE_KEY}",
        "short_id": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [
    { "type": "socks", "tag": "paqet-proxy", "server": "127.0.0.1", "server_port": 1080 },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "paqet-proxy" }
}
SINGCFG

        VLESS_URL="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#paqet-middle"

        cat > "$DATA_DIR/user-config.txt" << USERCFG

╔═══════════════════════════════════════════════════════════════════════════════╗
║                   VLESS Reality — Client Configuration                       ║
╚═══════════════════════════════════════════════════════════════════════════════╝

  User:        ${INITIAL_USER}
  VPS IP:      ${PUBLIC_IP}

  VLESS URL (paste into Shadowrocket / v2rayNG):
  ──────────────────────────────────────────────
  ${VLESS_URL}

  Manual Config:
  ──────────────
    Address:     ${PUBLIC_IP}
    Port:        ${REALITY_PORT}
    UUID:        ${UUID}
    Flow:        xtls-rprx-vision
    Security:    reality
    SNI:         ${REALITY_SNI}
    Public Key:  ${PUBLIC_KEY}
    Short ID:    ${SHORT_ID}
    Transport:   tcp
    Fingerprint: chrome

  Traffic Chain:
  ──────────────
    Your Device → This VPS (VLESS :${REALITY_PORT}) → Server (paqet :${SERVER_PORT})

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
        log_success "VLESS Reality config generated"
    fi

    log_success "User config saved to /opt/data/user-config.txt"
else
    log_success "VLESS config found (cached from previous run)"
    UUID=$(cat "$DATA_DIR/uuid" 2>/dev/null || echo "unknown")
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Create user management helper
# ══════════════════════════════════════════════════════════════════════════════

cat > "$DATA_DIR/manage-users.sh" << 'MGMT'
#!/bin/bash
DATA_DIR="/opt/data"
CONFIG="$DATA_DIR/sing-box-config.json"
case "$1" in
    show) cat "$DATA_DIR/user-config.txt" 2>/dev/null || echo "No user config found." ;;
    add)
        NAME="${2:?Usage: manage-users.sh add <username>}"
        NEW_UUID=$("$DATA_DIR/sing-box" generate uuid)
        jq --arg uuid "$NEW_UUID" --arg name "$NAME" \
            '.inbounds[0].users += [{"uuid": $uuid, "name": $name}]' \
            "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        echo "User added: $NAME (UUID: $NEW_UUID)"
        echo "Restart container to apply."
        ;;
    list) jq -r '.inbounds[0].users[] | "  \(.name)  \(.uuid)"' "$CONFIG" 2>/dev/null ;;
    *) echo "Usage: manage-users.sh <show|add|list> [args]" ;;
esac
MGMT
chmod +x "$DATA_DIR/manage-users.sh"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Start both services
# ══════════════════════════════════════════════════════════════════════════════

echo ""
log_info "Starting paqet client (background)..."
"$DATA_DIR/paqet" run -c "$DATA_DIR/paqet-config.yaml" &
PAQET_PID=$!
sleep 3

if kill -0 $PAQET_PID 2>/dev/null; then
    log_success "paqet client running (PID $PAQET_PID, SOCKS5 on 127.0.0.1:1080)"
else
    log_error "paqet client failed to start!"
    exit 1
fi

log_info "Starting sing-box (VLESS on port $REALITY_PORT, transport=$REALITY_TRANSPORT)..."
"$DATA_DIR/sing-box" run -c "$DATA_DIR/sing-box-config.json" &
SINGBOX_PID=$!
sleep 2

if kill -0 $SINGBOX_PID 2>/dev/null; then
    log_success "sing-box running (PID $SINGBOX_PID)"
else
    log_error "sing-box failed to start!"
    kill $PAQET_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    ✅ PAQET MIDDLE VPS IS RUNNING!                          ║"
echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ -f "$DATA_DIR/user-config.txt" ]]; then
    cat "$DATA_DIR/user-config.txt"
fi

# ── Process supervisor ───────────────────────────────────────────────────────
cleanup() {
    log_warn "Shutting down..."
    kill $PAQET_PID $SINGBOX_PID 2>/dev/null || true
    wait $PAQET_PID $SINGBOX_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

wait -n $PAQET_PID $SINGBOX_PID 2>/dev/null || true

if ! kill -0 $PAQET_PID 2>/dev/null; then log_error "paqet exited unexpectedly"; fi
if ! kill -0 $SINGBOX_PID 2>/dev/null; then log_error "sing-box exited unexpectedly"; fi

kill $PAQET_PID $SINGBOX_PID 2>/dev/null || true
log_error "Service crashed — container will restart"
exit 1
