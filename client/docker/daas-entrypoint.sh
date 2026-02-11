#!/bin/bash
set -e

#===============================================================================
# PAQET MIDDLE VPS — DaaS ENTRYPOINT
#
# Works with both:
#   - Pre-built image (binaries in /usr/local/bin/) → instant startup
#   - Runtime download mode (ubuntu/debian base) → downloads on first run
#
# Supports two VLESS modes:
#   REALITY_TRANSPORT=tcp  → VLESS Reality (raw TCP / domain with TLS passthrough)
#   REALITY_TRANSPORT=ws   → VLESS WebSocket (behind HTTP reverse proxy)
#
# Required env: SERVER_IP, SERVER_PORT, SECRET_KEY
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
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.google.com}"
REALITY_TRANSPORT="${REALITY_TRANSPORT:-tcp}"
INITIAL_USER="${INITIAL_USER:-default}"
WS_PATH="${WS_PATH:-/vless-ws}"

mkdir -p "$DATA_DIR"

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$SERVER_IP" || "$SERVER_IP" == "CHANGE_ME" ]]; then
    log_error "SERVER_IP is not set! Edit your docker-compose.yml"
    sleep 300
    exit 1
fi
if [[ -z "$SECRET_KEY" || "$SECRET_KEY" == "CHANGE_ME" ]]; then
    log_error "SECRET_KEY is not set! Edit your docker-compose.yml"
    sleep 300
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
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Locate or download binaries
# ══════════════════════════════════════════════════════════════════════════════

# Find paqet binary (pre-built image or download)
PAQET_BIN=""
if command -v paqet &>/dev/null; then
    PAQET_BIN=$(which paqet)
    log_success "paqet found at $PAQET_BIN (pre-installed)"
elif [[ -f "$DATA_DIR/paqet" ]]; then
    PAQET_BIN="$DATA_DIR/paqet"
    log_success "paqet found at $PAQET_BIN (cached)"
else
    log_info "Downloading paqet $PAQET_VERSION..."
    if ! command -v curl &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl libpcap0.8 iproute2 jq ca-certificates > /dev/null 2>&1
    fi
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) PA="linux-amd64";; aarch64|arm64) PA="linux-arm64";; *) PA="linux-amd64";; esac
    curl -sL "https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-${PA}-${PAQET_VERSION}.tar.gz" -o /tmp/paqet.tar.gz
    tar -xzf /tmp/paqet.tar.gz -C /tmp/
    BIN=$(ls /tmp/paqet* 2>/dev/null | grep -v ".tar.gz" | head -1)
    [[ -n "$BIN" ]] && mv "$BIN" "$DATA_DIR/paqet"
    chmod +x "$DATA_DIR/paqet"
    rm -f /tmp/paqet.tar.gz
    PAQET_BIN="$DATA_DIR/paqet"
    log_success "paqet downloaded"
fi

# Find sing-box binary
SINGBOX_BIN=""
if command -v sing-box &>/dev/null; then
    SINGBOX_BIN=$(which sing-box)
    log_success "sing-box found at $SINGBOX_BIN (pre-installed)"
elif [[ -f "$DATA_DIR/sing-box" ]]; then
    SINGBOX_BIN="$DATA_DIR/sing-box"
    log_success "sing-box found at $SINGBOX_BIN (cached)"
else
    log_info "Downloading sing-box..."
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) SA="amd64";; aarch64|arm64) SA="arm64";; *) SA="amd64";; esac
    SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//' 2>/dev/null)
    [[ -z "$SB_VERSION" || "$SB_VERSION" == "null" ]] && SB_VERSION="1.11.3"
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${SA}.tar.gz" -o /tmp/singbox.tar.gz
    tar -xzf /tmp/singbox.tar.gz -C /tmp/
    mv /tmp/sing-box-*/sing-box "$DATA_DIR/sing-box"
    chmod +x "$DATA_DIR/sing-box"
    rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*
    SINGBOX_BIN="$DATA_DIR/sing-box"
    log_success "sing-box downloaded"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Auto-detect network
# ══════════════════════════════════════════════════════════════════════════════

log_info "Detecting network..."

INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
[[ -z "$INTERFACE" ]] && INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
LOCAL_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
GATEWAY_IP=$(ip route | grep default | head -1 | awk '{print $3}')

# Robust gateway MAC detection with retries
GATEWAY_MAC=""
for attempt in 1 2 3 4 5; do
    ping -c 3 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
    sleep 1
    GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | grep -v FAILED | awk '{print $5}' | grep -iE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1)
    [[ -n "$GATEWAY_MAC" ]] && break
    GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | grep -v Address | awk '{print $3}' | grep -iE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1)
    [[ -n "$GATEWAY_MAC" ]] && break
    GATEWAY_MAC=$(grep "$GATEWAY_IP " /proc/net/arp 2>/dev/null | awk '{print $4}' | grep -v 00:00:00:00:00:00 | head -1)
    [[ -n "$GATEWAY_MAC" ]] && break
    log_warn "MAC attempt $attempt/5 failed, retrying..."
done
# Fallback: any neighbor MAC
if [[ -z "$GATEWAY_MAC" ]]; then
    GATEWAY_MAC=$(ip neigh show 2>/dev/null | grep -v FAILED | awk '{print $5}' | grep -iE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1)
fi
if [[ -z "$GATEWAY_MAC" ]]; then
    GATEWAY_MAC=$(cat /proc/net/arp 2>/dev/null | grep -v 'HW address' | grep -v '00:00:00:00:00:00' | awk '{print $4}' | head -1)
fi

if [[ -z "$INTERFACE" || -z "$LOCAL_IP" || -z "$GATEWAY_MAC" ]]; then
    log_error "Network detection failed: iface=$INTERFACE ip=$LOCAL_IP gwmac=$GATEWAY_MAC"
    log_error "Debug - ip neigh:"
    ip neigh show 2>&1 || true
    log_error "Debug - /proc/net/arp:"
    cat /proc/net/arp 2>&1 || true
    log_error "Sleeping 5 min (check logs then restart)"
    sleep 300
    exit 1
fi
log_success "Network: iface=$INTERFACE ip=$LOCAL_IP gw=$GATEWAY_MAC"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Setup iptables (may fail in K8s — that's OK)
# ══════════════════════════════════════════════════════════════════════════════

iptables -t raw -A PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -A OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Create paqet client config
# ══════════════════════════════════════════════════════════════════════════════

log_info "Writing paqet config..."
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

    UUID=$("$SINGBOX_BIN" generate uuid)
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

    # Use DAAS_DOMAIN for connection address if set
    CONNECT_ADDR="${DAAS_DOMAIN:-$PUBLIC_IP}"
    CONNECT_PORT="${DAAS_PORT:-$REALITY_PORT}"

    if [[ "$REALITY_TRANSPORT" == "ws" ]]; then
        # ── WEBSOCKET MODE ──
        log_info "Generating VLESS WebSocket config..."

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

        VLESS_URL="vless://${UUID}@${CONNECT_ADDR}:${CONNECT_PORT}?encryption=none&security=tls&sni=${CONNECT_ADDR}&type=ws&host=${CONNECT_ADDR}&path=${WS_PATH}#paqet-middle"

        cat > "$DATA_DIR/user-config.txt" << USERCFG

╔═══════════════════════════════════════════════════════════════════════════════╗
║              VLESS WebSocket — Client Configuration (DaaS)                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

  User:        ${INITIAL_USER}
  Domain:      ${CONNECT_ADDR}

  VLESS URL (paste into Shadowrocket / v2rayNG):
  ──────────────────────────────────────────────
  ${VLESS_URL}

  Manual Config:
  ──────────────
    Address:     ${CONNECT_ADDR}
    Port:        ${CONNECT_PORT}
    UUID:        ${UUID}
    Security:    tls
    SNI:         ${CONNECT_ADDR}
    Transport:   ws
    WS Host:     ${CONNECT_ADDR}
    WS Path:     ${WS_PATH}

  Traffic Chain:
    Your Device → DaaS (VLESS WS) → paqet → Server (:${SERVER_PORT})

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
        log_success "VLESS WebSocket config generated"

    else
        # ── REALITY MODE ──
        log_info "Generating VLESS Reality config..."

        KEYPAIR=$("$SINGBOX_BIN" generate reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $NF}')
        SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
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

        VLESS_URL="vless://${UUID}@${CONNECT_ADDR}:${CONNECT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#paqet-middle"

        cat > "$DATA_DIR/user-config.txt" << USERCFG

╔═══════════════════════════════════════════════════════════════════════════════╗
║                   VLESS Reality — Client Configuration                       ║
╚═══════════════════════════════════════════════════════════════════════════════╝

  User:        ${INITIAL_USER}
  Address:     ${CONNECT_ADDR}

  VLESS URL (paste into Shadowrocket / v2rayNG):
  ──────────────────────────────────────────────
  ${VLESS_URL}

  Manual Config:
  ──────────────
    Address:     ${CONNECT_ADDR}
    Port:        ${CONNECT_PORT}
    UUID:        ${UUID}
    Flow:        xtls-rprx-vision
    Security:    reality
    SNI:         ${REALITY_SNI}
    Public Key:  ${PUBLIC_KEY}
    Short ID:    ${SHORT_ID}
    Transport:   tcp
    Fingerprint: chrome

  Traffic Chain:
    Your Device → This VPS (VLESS :${CONNECT_PORT}) → Server (paqet :${SERVER_PORT})

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
        log_success "VLESS Reality config generated"
    fi

    log_success "User config saved to /opt/data/user-config.txt"
else
    log_success "VLESS config found (cached)"
    UUID=$(cat "$DATA_DIR/uuid" 2>/dev/null || echo "unknown")
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Create user management helper
# ══════════════════════════════════════════════════════════════════════════════

cat > "$DATA_DIR/manage-users.sh" << 'MGMT'
#!/bin/bash
DATA_DIR="/opt/data"
CONFIG="$DATA_DIR/sing-box-config.json"
SB=$(command -v sing-box || echo "$DATA_DIR/sing-box")
case "$1" in
    show) cat "$DATA_DIR/user-config.txt" 2>/dev/null || echo "No config found." ;;
    add)
        NAME="${2:?Usage: manage-users.sh add <username>}"
        NEW_UUID=$("$SB" generate uuid)
        jq --arg uuid "$NEW_UUID" --arg name "$NAME" \
            '.inbounds[0].users += [{"uuid": $uuid, "name": $name}]' \
            "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        echo "User: $NAME | UUID: $NEW_UUID"
        echo "Restart container to apply."
        ;;
    list) jq -r '.inbounds[0].users[] | "  \(.name)  \(.uuid)"' "$CONFIG" 2>/dev/null ;;
    *) echo "Usage: manage-users.sh <show|add|list>" ;;
esac
MGMT
chmod +x "$DATA_DIR/manage-users.sh"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Start services
# ══════════════════════════════════════════════════════════════════════════════

echo ""
log_info "Starting paqet client..."
"$PAQET_BIN" run -c "$DATA_DIR/paqet-config.yaml" &
PAQET_PID=$!
sleep 3

if kill -0 $PAQET_PID 2>/dev/null; then
    log_success "paqet running (SOCKS5 on 127.0.0.1:1080)"
else
    log_error "paqet failed to start!"
    exit 1
fi

log_info "Starting sing-box (port $REALITY_PORT, $REALITY_TRANSPORT)..."
"$SINGBOX_BIN" run -c "$DATA_DIR/sing-box-config.json" &
SINGBOX_PID=$!
sleep 2

if kill -0 $SINGBOX_PID 2>/dev/null; then
    log_success "sing-box running"
else
    log_error "sing-box failed to start!"
    kill $PAQET_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              ✅ PAQET MIDDLE VPS IS RUNNING!                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

[[ -f "$DATA_DIR/user-config.txt" ]] && cat "$DATA_DIR/user-config.txt"

# ── Process supervisor ───────────────────────────────────────────────────────
cleanup() {
    kill $PAQET_PID $SINGBOX_PID 2>/dev/null || true
    wait $PAQET_PID $SINGBOX_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

wait -n $PAQET_PID $SINGBOX_PID 2>/dev/null || true
kill $PAQET_PID $SINGBOX_PID 2>/dev/null || true
log_error "Service crashed — container will restart"
exit 1
