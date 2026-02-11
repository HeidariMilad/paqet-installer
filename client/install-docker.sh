#!/bin/bash
set -e

#===============================================================================
# PAQET MIDDLE VPS ONE-CLICK INSTALLER (Docker Compose / DaaS Edition)
#
# Self-contained paqet client + sing-box VLESS in a single Docker container.
# Traffic chain: Your Device (Shadowrocket) -> This VPS (VLESS) -> Server VPS (paqet)
#
# Usage: curl -sL <url>/client/install-docker.sh | sudo bash
#    or: sudo bash install-docker.sh
#
# Designed for DaaS (Docker as a Service) environments — only Docker required.
#===============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
INSTALL_DIR="/opt/paqet-middle"
REALITY_DATA_DIR="/opt/reality-ezpz"
DEFAULT_SERVER_PORT=9999
PAQET_VERSION="v1.0.0-alpha.14"
REALITY_PORT=443
REALITY_TRANSPORT="tcp"
REALITY_SNI="www.google.com"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                   ║"
    echo "║   ██████╗  █████╗  ██████╗ ███████╗████████╗                      ║"
    echo "║   ██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝                      ║"
    echo "║   ██████╔╝███████║██║   ██║█████╗     ██║                         ║"
    echo "║   ██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝     ██║                         ║"
    echo "║   ██║     ██║  ██║╚██████╔╝███████╗   ██║                         ║"
    echo "║   ╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝   ╚═╝                         ║"
    echo "║                                                                   ║"
    echo "║       Middle VPS Installer (Docker Compose / DaaS Edition)       ║"
    echo "║          paqet client + sing-box (VLESS Reality / WS)            ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Network Detection
#-------------------------------------------------------------------------------

detect_interface() {
    log_info "Detecting primary network interface..."
    INTERFACE=$(ip route | grep default | head -n1 | awk '{print $5}')
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
    fi
    if [[ -z "$INTERFACE" ]]; then
        log_error "Could not detect network interface"
        exit 1
    fi
    log_success "Network interface: $INTERFACE"
}

detect_local_ip() {
    log_info "Detecting local IP address..."
    LOCAL_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -z "$LOCAL_IP" ]]; then
        log_error "Could not detect local IP on interface $INTERFACE"
        exit 1
    fi
    log_success "Local IP: $LOCAL_IP"
}

detect_public_ip() {
    log_info "Detecting public IP address..."
    PUBLIC_IP=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "Could not detect public IP (non-critical)"
        PUBLIC_IP="UNKNOWN"
    fi
    log_success "Public IP: $PUBLIC_IP"
}

detect_gateway_mac() {
    log_info "Detecting gateway MAC address..."
    GATEWAY_IP=$(ip route | grep default | head -n1 | awk '{print $3}')
    if [[ -z "$GATEWAY_IP" ]]; then
        log_error "Could not detect gateway IP"
        exit 1
    fi
    log_info "Gateway IP: $GATEWAY_IP"
    ping -c 1 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
    GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $5}' | head -n1)
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "FAILED" ]]; then
        GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | grep -v Address | awk '{print $3}' | head -n1)
    fi
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "(incomplete)" ]]; then
        log_error "Could not detect gateway MAC address"
        log_error "Try: ping $GATEWAY_IP && ip neigh show $GATEWAY_IP"
        exit 1
    fi
    log_success "Gateway MAC: $GATEWAY_MAC"
}

detect_architecture() {
    log_info "Detecting system architecture..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)         PAQET_ARCH="linux-amd64" ;;
        aarch64|arm64)  PAQET_ARCH="linux-arm64" ;;
        armv7l|armhf)   PAQET_ARCH="linux-arm32" ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    log_success "Architecture: $ARCH -> $PAQET_ARCH"
}

#-------------------------------------------------------------------------------
# Docker Installation
#-------------------------------------------------------------------------------

install_docker() {
    log_info "Checking Docker installation..."

    if command -v docker &> /dev/null; then
        log_success "Docker is already installed"
        # Ensure compose plugin is available
        if docker compose version &> /dev/null; then
            log_success "Docker Compose plugin is available"
        else
            log_info "Installing Docker Compose plugin..."
            apt-get update && apt-get install -y docker-compose-plugin 2>/dev/null || true
        fi
        return
    fi

    log_info "Installing Docker..."

    # Install prerequisites
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Start Docker
    systemctl start docker 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true

    log_success "Docker installed successfully"
}

#-------------------------------------------------------------------------------
# User Input
#-------------------------------------------------------------------------------

get_server_info() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                   PAQET SERVER CONNECTION DETAILS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Enter the details from your paqet server (run 'paqet-ctl info' on server)"
    echo ""

    echo -n "Server IP address: "
    read SERVER_IP < /dev/tty
    echo -n "Server port [$DEFAULT_SERVER_PORT]: "
    read SERVER_PORT < /dev/tty
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_SERVER_PORT}"
    echo -n "Secret key: "
    read SECRET_KEY < /dev/tty

    if [[ -z "$SERVER_IP" || -z "$SECRET_KEY" ]]; then
        log_error "Server IP and secret key are required"
        exit 1
    fi

    echo ""
    log_success "Server: $SERVER_IP:$SERVER_PORT"
}

get_reality_options() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                  REALITY-EZPZ CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Configure VLESS Reality for incoming connections (from your Mac/phone)"
    echo ""

    echo -n "Reality port [$REALITY_PORT]: "
    read INPUT_PORT < /dev/tty
    REALITY_PORT="${INPUT_PORT:-$REALITY_PORT}"

    echo -n "Transport protocol (tcp/http/grpc/ws) [$REALITY_TRANSPORT]: "
    read INPUT_TRANSPORT < /dev/tty
    REALITY_TRANSPORT="${INPUT_TRANSPORT:-$REALITY_TRANSPORT}"

    echo -n "SNI domain [$REALITY_SNI]: "
    read INPUT_SNI < /dev/tty
    REALITY_SNI="${INPUT_SNI:-$REALITY_SNI}"

    echo -n "Create initial username [default]: "
    read REALITY_INITIAL_USER < /dev/tty
    REALITY_INITIAL_USER="${REALITY_INITIAL_USER:-default}"

    echo ""
    log_success "Reality: port=$REALITY_PORT transport=$REALITY_TRANSPORT sni=$REALITY_SNI"
}

#-------------------------------------------------------------------------------
# File Generation
#-------------------------------------------------------------------------------

create_install_directory() {
    log_info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$REALITY_DATA_DIR"
    log_success "Directories created"
}

create_dockerfile() {
    log_info "Creating Dockerfile..."

    cat > "$INSTALL_DIR/Dockerfile.paqet" << 'DOCKERFILE'
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libpcap0.8 \
        iproute2 \
        iptables \
        iputils-ping \
        net-tools \
        curl \
        jq \
        ca-certificates \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Download paqet binary
ARG PAQET_VERSION=v1.0.0-alpha.14
ARG TARGETARCH=amd64
RUN PAQET_ARCH="linux-${TARGETARCH}" && \
    curl -sL "https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-${PAQET_ARCH}-${PAQET_VERSION}.tar.gz" -o /tmp/paqet.tar.gz && \
    tar -xzf /tmp/paqet.tar.gz -C /tmp/ && \
    BIN=$(ls /tmp/paqet* 2>/dev/null | grep -v ".tar.gz" | head -1) && \
    mv "$BIN" /usr/local/bin/paqet && \
    chmod +x /usr/local/bin/paqet && \
    rm -f /tmp/paqet.tar.gz

# Download sing-box binary
ARG SB_VERSION=1.11.3
RUN curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${TARGETARCH}.tar.gz" -o /tmp/singbox.tar.gz && \
    tar -xzf /tmp/singbox.tar.gz -C /tmp/ && \
    mv /tmp/sing-box-*/sing-box /usr/local/bin/sing-box && \
    chmod +x /usr/local/bin/sing-box && \
    rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*

WORKDIR /opt/data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
DOCKERFILE

    log_success "Dockerfile created"
}

create_entrypoint() {
    log_info "Creating entrypoint script..."

    cat > "$INSTALL_DIR/entrypoint.sh" << 'SCRIPT'
#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

DATA_DIR="/opt/data"
PAQET_VERSION="${PAQET_VERSION:-v1.0.0-alpha.14}"
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.google.com}"
REALITY_TRANSPORT="${REALITY_TRANSPORT:-tcp}"
INITIAL_USER="${INITIAL_USER:-default}"

mkdir -p "$DATA_DIR"

# Validate required env vars
if [[ -z "$SERVER_IP" || "$SERVER_IP" == "CHANGE_ME" ]]; then
    log_error "SERVER_IP is not set!"; sleep 300; exit 1
fi
if [[ -z "$SECRET_KEY" || "$SECRET_KEY" == "CHANGE_ME" ]]; then
    log_error "SECRET_KEY is not set!"; sleep 300; exit 1
fi
SERVER_PORT="${SERVER_PORT:-9999}"

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║          Paqet Middle VPS — Starting...                          ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
log_info "Server: $SERVER_IP:$SERVER_PORT"
log_info "Mode: $REALITY_TRANSPORT | Port: $REALITY_PORT"

# Locate binaries
PAQET_BIN=$(command -v paqet || echo "$DATA_DIR/paqet")
SINGBOX_BIN=$(command -v sing-box || echo "$DATA_DIR/sing-box")

# Auto-detect network
log_info "Detecting network..."
INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
[[ -z "$INTERFACE" ]] && INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
LOCAL_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
GATEWAY_IP=$(ip route | grep default | head -1 | awk '{print $3}')

GATEWAY_MAC=""
for attempt in 1 2 3 4 5; do
    ping -c 3 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true; sleep 1
    GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | grep -v FAILED | awk '{print $5}' | grep -iE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1)
    [[ -n "$GATEWAY_MAC" ]] && break
    GATEWAY_MAC=$(cat /proc/net/arp 2>/dev/null | grep "$GATEWAY_IP " | awk '{print $4}' | grep -v 00:00:00:00:00:00 | head -1)
    [[ -n "$GATEWAY_MAC" ]] && break
    log_warn "MAC attempt $attempt/5 failed, retrying..."
done
[[ -z "$GATEWAY_MAC" ]] && GATEWAY_MAC=$(ip neigh show 2>/dev/null | grep -v FAILED | awk '{print $5}' | grep -iE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1)

if [[ -z "$INTERFACE" || -z "$LOCAL_IP" || -z "$GATEWAY_MAC" ]]; then
    log_error "Network detection failed: iface=$INTERFACE ip=$LOCAL_IP gwmac=$GATEWAY_MAC"
    ip neigh show 2>&1 || true; cat /proc/net/arp 2>&1 || true
    sleep 300; exit 1
fi
log_success "Network: iface=$INTERFACE ip=$LOCAL_IP gw=$GATEWAY_MAC"

# iptables (may fail in some environments)
iptables -t raw -A PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -A OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true

# Write paqet config
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

# Generate sing-box config (first run only)
if [[ ! -f "$DATA_DIR/sing-box-config.json" ]]; then
    UUID=$("$SINGBOX_BIN" generate uuid)
    echo "$UUID" > "$DATA_DIR/uuid"
    PUBLIC_IP=""
    for url in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
        PUBLIC_IP=$(curl -4 -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        echo "$PUBLIC_IP" | grep -qP '^\d+\.\d+\.\d+\.\d+$' && break
        PUBLIC_IP=""
    done
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
    echo "$PUBLIC_IP" > "$DATA_DIR/public_ip"
    CONNECT_ADDR="${DAAS_DOMAIN:-$PUBLIC_IP}"
    CONNECT_PORT="${DAAS_PORT:-$REALITY_PORT}"

    if [[ "$REALITY_TRANSPORT" == "grpc" || "$REALITY_TRANSPORT" == "tcp" ]]; then
        log_info "Generating VLESS Reality config..."
        KEYPAIR=$("$SINGBOX_BIN" generate reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $NF}')
        SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        echo "$PUBLIC_KEY" > "$DATA_DIR/public_key"
        echo "$PRIVATE_KEY" > "$DATA_DIR/private_key"
        echo "$SHORT_ID" > "$DATA_DIR/short_id"

        if [[ "$REALITY_TRANSPORT" == "grpc" ]]; then
            TRANSPORT_BLOCK='"transport": { "type": "grpc", "service_name": "grpc" },'
            FLOW_FIELD=""
            VLESS_URL="vless://${UUID}@${CONNECT_ADDR}:${CONNECT_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=grpc&serviceName=grpc#paqet-middle"
        else
            TRANSPORT_BLOCK=""
            FLOW_FIELD='"flow": "xtls-rprx-vision",'
            VLESS_URL="vless://${UUID}@${CONNECT_ADDR}:${CONNECT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#paqet-middle"
        fi

        cat > "$DATA_DIR/sing-box-config.json" << SINGCFG
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": ${REALITY_PORT},
    "users": [{ "uuid": "${UUID}", ${FLOW_FIELD} "name": "${INITIAL_USER}" }],
    ${TRANSPORT_BLOCK}
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
    Security:    reality
    SNI:         ${REALITY_SNI}
    Public Key:  ${PUBLIC_KEY}
    Short ID:    ${SHORT_ID}
    Transport:   ${REALITY_TRANSPORT}
    Fingerprint: chrome

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
    else
        log_info "Generating VLESS WebSocket config..."
        WS_PATH="${WS_PATH:-/vless-ws}"
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
║              VLESS WebSocket — Client Configuration                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝

  User:        ${INITIAL_USER}
  VLESS URL:   ${VLESS_URL}

╚═══════════════════════════════════════════════════════════════════════════════╝
USERCFG
    fi
    log_success "VLESS config generated"
else
    log_success "VLESS config found (cached)"
fi

# Start services
echo ""
log_info "Starting paqet client..."
"$PAQET_BIN" run -c "$DATA_DIR/paqet-config.yaml" &
PAQET_PID=$!
sleep 3

if kill -0 $PAQET_PID 2>/dev/null; then
    log_success "paqet running (SOCKS5 on 127.0.0.1:1080)"
else
    log_error "paqet failed to start!"; exit 1
fi

log_info "Starting sing-box (port $REALITY_PORT, $REALITY_TRANSPORT)..."
"$SINGBOX_BIN" run -c "$DATA_DIR/sing-box-config.json" &
SINGBOX_PID=$!
sleep 2

if kill -0 $SINGBOX_PID 2>/dev/null; then
    log_success "sing-box running"
else
    log_error "sing-box failed!"; kill $PAQET_PID 2>/dev/null || true; exit 1
fi

echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              ✅ PAQET MIDDLE VPS IS RUNNING!                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

[[ -f "$DATA_DIR/user-config.txt" ]] && cat "$DATA_DIR/user-config.txt"

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
SCRIPT

    chmod +x "$INSTALL_DIR/entrypoint.sh"
    log_success "Entrypoint script created"
}

create_docker_compose() {
    log_info "Creating docker-compose.yml..."

    cat > "$INSTALL_DIR/docker-compose.yml" << YAML
#===============================================================================
# Paqet Middle VPS Stack (Self-Contained)
# Traffic: Your Device (VLESS) -> sing-box -> paqet-client -> Server VPS
#
# Single container runs both paqet (SOCKS5) and sing-box (VLESS Reality/WS)
#===============================================================================

services:

  paqet-middle:
    build:
      context: .
      dockerfile: Dockerfile.paqet
    container_name: paqet-middle
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      - SERVER_IP=${SERVER_IP}
      - SERVER_PORT=${SERVER_PORT}
      - SECRET_KEY=${SECRET_KEY}
      - REALITY_PORT=${REALITY_PORT}
      - REALITY_TRANSPORT=${REALITY_TRANSPORT}
      - REALITY_SNI=${REALITY_SNI}
      - INITIAL_USER=${REALITY_INITIAL_USER}
      - PAQET_VERSION=${PAQET_VERSION}
    volumes:
      - ${REALITY_DATA_DIR}:/opt/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
YAML

    log_success "docker-compose.yml created"
}

create_management_script() {
    log_info "Creating management script..."

    cat > "$INSTALL_DIR/paqet-middle-ctl" << 'SCRIPT'
#!/bin/bash
INSTALL_DIR="/opt/paqet-middle"
DATA_DIR="/opt/reality-ezpz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$INSTALL_DIR" 2>/dev/null || { echo -e "${RED}[ERROR]${NC} Install dir not found: $INSTALL_DIR"; exit 1; }

case "$1" in
    start)
        echo -e "${BLUE}Starting paqet middle VPS stack...${NC}"
        docker compose up -d --build
        echo -e "${GREEN}Done.${NC} Check: paqet-middle-ctl status"
        ;;
    stop)
        echo -e "${BLUE}Stopping stack...${NC}"
        docker compose down
        echo -e "${GREEN}Done.${NC}"
        ;;
    restart)
        echo -e "${BLUE}Restarting stack...${NC}"
        docker compose restart
        echo -e "${GREEN}Done.${NC}"
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f --tail=100 paqet-middle
        ;;
    show-user)
        if [[ -f "$DATA_DIR/user-config.txt" ]]; then
            cat "$DATA_DIR/user-config.txt"
        else
            echo -e "${YELLOW}No user config found. Wait for container to start.${NC}"
        fi
        ;;
    add-user)
        USERNAME="${2:?Usage: paqet-middle-ctl add-user <username>}"
        echo -e "${BLUE}Adding user: $USERNAME${NC}"
        docker exec -it paqet-middle bash /opt/data/manage-users.sh add "$USERNAME"
        echo -e "${YELLOW}Restart the container to apply: paqet-middle-ctl restart${NC}"
        ;;
    list-users)
        docker exec -it paqet-middle bash /opt/data/manage-users.sh list
        ;;
    info)
        [[ -f "$INSTALL_DIR/connection-info.txt" ]] && cat "$INSTALL_DIR/connection-info.txt" || echo "No info file."
        ;;
    update)
        echo -e "${BLUE}Updating stack...${NC}"
        docker compose down
        rm -f "$DATA_DIR/sing-box-config.json" 2>/dev/null || true
        docker compose build --no-cache
        docker compose up -d
        echo -e "${GREEN}Done.${NC}"
        ;;
    reset)
        echo -e "${YELLOW}Resetting VLESS config (will regenerate keys on next start)...${NC}"
        docker compose down
        rm -f "$DATA_DIR/sing-box-config.json" "$DATA_DIR/user-config.txt" "$DATA_DIR/uuid" \
              "$DATA_DIR/public_key" "$DATA_DIR/private_key" "$DATA_DIR/short_id" 2>/dev/null || true
        docker compose up -d
        echo -e "${GREEN}Done.${NC} View new config: paqet-middle-ctl show-user"
        ;;
    uninstall)
        echo -e "${YELLOW}Uninstalling...${NC}"
        docker compose down -v
        docker rmi paqet-middle-paqet-middle 2>/dev/null || true
        echo -e "${GREEN}Containers removed.${NC}"
        echo "Full removal: rm -rf $INSTALL_DIR $DATA_DIR"
        ;;
    *)
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}        Paqet Middle VPS (paqet + sing-box)              ${CYAN}║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Usage:${NC} paqet-middle-ctl <command>"
        echo ""
        echo -e "${CYAN}── Stack ─────────────────────────────────────────────────${NC}"
        echo "  start             Start the stack"
        echo "  stop              Stop the stack"
        echo "  restart           Restart the stack"
        echo "  status            Show container status"
        echo "  logs              Show container logs"
        echo ""
        echo -e "${CYAN}── User Management ───────────────────────────────────────${NC}"
        echo "  show-user              Show VLESS connection config"
        echo "  add-user <name>        Add a VLESS user"
        echo "  list-users             List all users"
        echo ""
        echo -e "${CYAN}── Maintenance ───────────────────────────────────────────${NC}"
        echo "  info              Show connection information"
        echo "  update            Rebuild and restart"
        echo "  reset             Regenerate VLESS keys"
        echo "  uninstall         Remove all containers"
        echo ""
        ;;
esac
SCRIPT

    chmod +x "$INSTALL_DIR/paqet-middle-ctl"
    ln -sf "$INSTALL_DIR/paqet-middle-ctl" /usr/local/bin/paqet-middle-ctl 2>/dev/null || true

    log_success "Management script created: paqet-middle-ctl"
}

create_connection_info() {
    log_info "Creating connection information file..."

    cat > "$INSTALL_DIR/connection-info.txt" << INFO
╔═══════════════════════════════════════════════════════════════════════════════╗
║                     PAQET MIDDLE VPS CONNECTION INFO                         ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Installation completed: $(date)

TRAFFIC CHAIN
═════════════
  Your Device (Shadowrocket/v2rayNG)
    ↓ VLESS (port $REALITY_PORT, $REALITY_TRANSPORT)
  This VPS ($PUBLIC_IP) — paqet-middle (sing-box + paqet)
    ↓ KCP tunnel (port $SERVER_PORT)
  Server VPS ($SERVER_IP) — paqet-server

PAQET SERVER
════════════
  Server:          $SERVER_IP:$SERVER_PORT

VLESS SETTINGS
══════════════
  VLESS Port:      $REALITY_PORT
  Transport:       $REALITY_TRANSPORT
  SNI Domain:      $REALITY_SNI
  Initial User:    $REALITY_INITIAL_USER

HOW TO USE
══════════
  1. View VLESS connection config for Shadowrocket:
     paqet-middle-ctl show-user

  2. Add more users:
     paqet-middle-ctl add-user <name>

  3. Check status:
     paqet-middle-ctl status

  4. View logs:
     paqet-middle-ctl logs

MANAGEMENT COMMANDS
═══════════════════
  paqet-middle-ctl start / stop / restart / status / logs
  paqet-middle-ctl show-user / add-user <name> / list-users
  paqet-middle-ctl info / update / reset / uninstall

INFO

    log_success "Connection information saved"
}

#-------------------------------------------------------------------------------
# Build & Start
#-------------------------------------------------------------------------------

build_and_start() {
    log_info "Building and starting Docker Compose stack..."

    cd "$INSTALL_DIR"
    docker compose up -d --build

    sleep 5

    if docker compose ps | grep -q "Up\|running"; then
        log_success "Docker Compose stack is running!"
        echo ""
        log_info "Waiting for VLESS config to be generated..."
        sleep 8
        if [[ -f "$REALITY_DATA_DIR/user-config.txt" ]]; then
            cat "$REALITY_DATA_DIR/user-config.txt"
        else
            log_info "Config will appear in logs: paqet-middle-ctl logs"
        fi
    else
        log_warn "Stack may not be fully ready yet. Check: paqet-middle-ctl status"
    fi
}

#-------------------------------------------------------------------------------
# Completion Message
#-------------------------------------------------------------------------------

print_completion_message() {
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                               ║"
    echo "║                    ✅ INSTALLATION COMPLETED SUCCESSFULLY!                    ║"
    echo "║                                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                          TRAFFIC CHAIN${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Your Mac/Phone (Shadowrocket)"
    echo "    ↓ VLESS $REALITY_TRANSPORT (port $REALITY_PORT)"
    echo "  This VPS ($PUBLIC_IP) — paqet-middle"
    echo "    ↓ KCP tunnel (port $SERVER_PORT)"
    echo "  Server VPS ($SERVER_IP)"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                            NEXT STEPS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Get your VLESS connection config for Shadowrocket:"
    echo -e "     ${BLUE}paqet-middle-ctl show-user${NC}"
    echo ""
    echo "  2. Add more users:"
    echo -e "     ${BLUE}paqet-middle-ctl add-user <username>${NC}"
    echo ""
    echo "  3. Check everything is running:"
    echo -e "     ${BLUE}paqet-middle-ctl status${NC}"
    echo ""
    echo "  4. View logs:"
    echo -e "     ${BLUE}paqet-middle-ctl logs${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠️  IMPORTANT: Use 'paqet-middle-ctl show-user' to get the VLESS URL${NC}"
    echo -e "  ${YELLOW}    for your client app (Shadowrocket/v2rayNG).${NC}"
    echo ""
    echo -e "  Files: $INSTALL_DIR"
    echo ""
}

#-------------------------------------------------------------------------------
# Uninstall
#-------------------------------------------------------------------------------

uninstall() {
    print_banner
    echo -e "${YELLOW}Uninstalling paqet middle VPS stack...${NC}"
    echo ""

    cd "$INSTALL_DIR" 2>/dev/null && {
        log_info "Stopping Docker containers..."
        docker compose down -v 2>/dev/null || true
        log_success "Containers stopped"
    }

    log_info "Removing symlinks..."
    rm -f /usr/local/bin/paqet-middle-ctl 2>/dev/null || true
    log_success "Symlinks removed"

    log_info "Removing installation directories..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$REALITY_DATA_DIR" 2>/dev/null || true
    log_success "Directories removed"

    echo ""
    echo -e "${GREEN}✅ Paqet middle VPS stack has been completely uninstalled.${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    # Check for uninstall flag
    if [[ "$1" == "--uninstall" || "$1" == "-u" ]]; then
        check_root
        uninstall
        exit 0
    fi

    print_banner

    check_root

    # Detect network
    detect_architecture
    detect_interface
    detect_local_ip
    detect_public_ip
    detect_gateway_mac

    # Get user input
    get_server_info
    get_reality_options

    echo ""
    log_info "Starting installation..."
    echo ""

    # Install Docker if needed
    install_docker

    # Create files
    create_install_directory
    create_dockerfile
    create_entrypoint
    create_docker_compose
    create_management_script
    create_connection_info

    # Build & start
    build_and_start

    # Done
    print_completion_message
}

main "$@"
