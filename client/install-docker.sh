#!/bin/bash
set -e

#===============================================================================
# PAQET MIDDLE VPS ONE-CLICK INSTALLER (Docker Compose / DaaS Edition)
#
# Installs paqet client + reality-ezpz in a single Docker Compose stack.
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
    echo "║            paqet client + reality-ezpz (VLESS Reality)           ║"
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

create_paqet_config() {
    log_info "Creating paqet client configuration..."

    cat > "$INSTALL_DIR/config.yaml" << YAML
# paqet Client Configuration (Docker Middle VPS)
# Auto-generated on $(date)
# Traffic: Your Device -> This VPS (VLESS) -> Server VPS (paqet)

role: "client"

log:
  level: "info"

socks5:
  - listen: "0.0.0.0:1080"

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
YAML

    log_success "Paqet client config created"
}

create_dockerfile() {
    log_info "Creating Dockerfile for paqet client..."

    cat > "$INSTALL_DIR/Dockerfile.paqet" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    libpcap-dev \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG PAQET_VERSION=v1.0.0-alpha.14
ARG PAQET_ARCH=linux-amd64

RUN curl -sL "https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-${PAQET_ARCH}-${PAQET_VERSION}.tar.gz" -o paqet.tar.gz \
    && tar -xzf paqet.tar.gz \
    && rm paqet.tar.gz \
    && BINARY_NAME=$(ls paqet* 2>/dev/null | head -n1) \
    && if [ -n "$BINARY_NAME" ] && [ "$BINARY_NAME" != "paqet" ]; then mv "$BINARY_NAME" paqet; fi \
    && chmod +x /app/paqet

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
DOCKERFILE

    log_success "Dockerfile created"
}

create_entrypoint() {
    log_info "Creating entrypoint script..."

    cat > "$INSTALL_DIR/entrypoint.sh" << 'SCRIPT'
#!/bin/bash
set -e

echo "========================================="
echo "  Paqet Client Container Starting..."
echo "========================================="

PAQET_PORT="${PAQET_SERVER_PORT:-9999}"

echo "[INFO] Setting up iptables rules for port $PAQET_PORT..."

iptables -t raw -D PREROUTING -p tcp --dport "$PAQET_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -D OUTPUT -p tcp --sport "$PAQET_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --sport "$PAQET_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true

iptables -t raw -A PREROUTING -p tcp --dport "$PAQET_PORT" -j NOTRACK 2>/dev/null || echo "[WARN] Could not set PREROUTING rule"
iptables -t raw -A OUTPUT -p tcp --sport "$PAQET_PORT" -j NOTRACK 2>/dev/null || echo "[WARN] Could not set OUTPUT raw rule"
iptables -t mangle -A OUTPUT -p tcp --sport "$PAQET_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || echo "[WARN] Could not set mangle rule"

echo "[INFO] iptables rules configured"
echo "[INFO] Starting paqet client..."
echo "[INFO] SOCKS5 proxy: 0.0.0.0:1080"
echo ""

exec /app/paqet run -c /app/config.yaml
SCRIPT

    chmod +x "$INSTALL_DIR/entrypoint.sh"
    log_success "Entrypoint script created"
}

create_docker_compose() {
    log_info "Creating docker-compose.yml..."

    cat > "$INSTALL_DIR/docker-compose.yml" << YAML
#===============================================================================
# Paqet Middle VPS Stack
# Traffic: Your Device (VLESS) -> reality-ezpz -> paqet-client -> Server VPS
#===============================================================================

services:

  # ── Paqet Client ──────────────────────────────────────────────────────────
  # Connects to the paqet server via raw sockets / KCP tunnel.
  # Exposes SOCKS5 proxy on port 1080 for reality-ezpz to route through.
  paqet-client:
    build:
      context: .
      dockerfile: Dockerfile.paqet
      args:
        PAQET_VERSION: "${PAQET_VERSION}"
        PAQET_ARCH: "${PAQET_ARCH}"
    container_name: paqet-client
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      - PAQET_SERVER_PORT=${SERVER_PORT}
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # ── Reality-EZPZ (sing-box) ──────────────────────────────────────────────
  # Provides VLESS Reality endpoint for external clients (Shadowrocket, etc.)
  # Routes all outbound traffic through paqet's SOCKS5 proxy.
  reality-ezpz:
    image: ghcr.io/aleskxyz/reality-ezpz:latest
    container_name: reality-ezpz
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${REALITY_DATA_DIR}:/opt/reality-ezpz
    environment:
      - TRANSPORT=${REALITY_TRANSPORT}
      - DOMAIN=${REALITY_SNI}
      - PORT=${REALITY_PORT}
      - CORE=sing-box
      - SECURITY=reality
      - OUTBOUND_PROTOCOL=socks
      - OUTBOUND_ADDRESS=127.0.0.1
      - OUTBOUND_PORT=1080
    depends_on:
      - paqet-client
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
REALITY_DIR="/opt/reality-ezpz"

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
        docker compose logs -f --tail=100 ${2:-}
        ;;
    logs-paqet)
        docker compose logs -f --tail=100 paqet-client
        ;;
    logs-reality)
        docker compose logs -f --tail=100 reality-ezpz
        ;;
    config)
        echo -e "${CYAN}═══ Paqet Client Config ═══${NC}"
        cat "$INSTALL_DIR/config.yaml"
        ;;
    reality-add-user)
        USERNAME="${2:?Usage: paqet-middle-ctl reality-add-user <username>}"
        echo -e "${BLUE}Adding user: $USERNAME${NC}"
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --add-user="$USERNAME"
        echo -e "${GREEN}User added.${NC} Show config: paqet-middle-ctl reality-show-user $USERNAME"
        ;;
    reality-list-users)
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --list-users
        ;;
    reality-show-user)
        USERNAME="${2:?Usage: paqet-middle-ctl reality-show-user <username>}"
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --show-user="$USERNAME"
        ;;
    reality-delete-user)
        USERNAME="${2:?Usage: paqet-middle-ctl reality-delete-user <username>}"
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --delete-user="$USERNAME"
        echo -e "${GREEN}User deleted.${NC}"
        ;;
    reality-menu)
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --menu
        ;;
    reality-config)
        docker exec -it reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --show-server-config
        ;;
    info)
        [[ -f "$INSTALL_DIR/connection-info.txt" ]] && cat "$INSTALL_DIR/connection-info.txt" || echo "No info file."
        ;;
    update)
        echo -e "${BLUE}Updating stack...${NC}"
        docker compose down
        docker compose build --no-cache
        docker compose up -d
        echo -e "${GREEN}Done.${NC}"
        ;;
    uninstall)
        echo -e "${YELLOW}Uninstalling...${NC}"
        docker compose down -v
        docker rmi paqet-middle-paqet-client 2>/dev/null || true
        echo -e "${GREEN}Containers removed.${NC}"
        echo "Full removal: rm -rf $INSTALL_DIR $REALITY_DIR"
        ;;
    *)
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}    Paqet Middle VPS (paqet-client + reality-ezpz)      ${CYAN}║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Usage:${NC} paqet-middle-ctl <command>"
        echo ""
        echo -e "${CYAN}── Stack ─────────────────────────────────────────────────${NC}"
        echo "  start / stop / restart / status"
        echo "  logs [service]  / logs-paqet / logs-reality"
        echo "  config          Show paqet client config"
        echo ""
        echo -e "${CYAN}── Reality-EZPZ Users ────────────────────────────────────${NC}"
        echo "  reality-add-user <name>     Add VLESS user"
        echo "  reality-list-users          List users"
        echo "  reality-show-user <name>    Show config & QR code"
        echo "  reality-delete-user <name>  Delete user"
        echo "  reality-menu                TUI management menu"
        echo "  reality-config              Show server config"
        echo ""
        echo -e "${CYAN}── Maintenance ───────────────────────────────────────────${NC}"
        echo "  info / update / uninstall"
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
    ↓ VLESS Reality (port $REALITY_PORT)
  This VPS ($PUBLIC_IP) — reality-ezpz + paqet-client
    ↓ KCP tunnel (port $SERVER_PORT)
  Server VPS ($SERVER_IP) — paqet-server

THIS VPS DETAILS
════════════════
  Public IP:       $PUBLIC_IP
  Interface:       $INTERFACE
  Local IP:        $LOCAL_IP
  Gateway MAC:     $GATEWAY_MAC

PAQET SERVER
════════════
  Server:          $SERVER_IP:$SERVER_PORT
  Secret Key:      $SECRET_KEY

REALITY-EZPZ
═════════════
  VLESS Port:      $REALITY_PORT
  Transport:       $REALITY_TRANSPORT
  SNI Domain:      $REALITY_SNI
  Initial User:    $REALITY_INITIAL_USER

HOW TO USE
══════════
  1. Show user connection config (for Shadowrocket):
     paqet-middle-ctl reality-show-user $REALITY_INITIAL_USER

  2. Add more users:
     paqet-middle-ctl reality-add-user <name>

  3. Check status:
     paqet-middle-ctl status

  4. View logs:
     paqet-middle-ctl logs

MANAGEMENT COMMANDS
═══════════════════
  paqet-middle-ctl start / stop / restart / status
  paqet-middle-ctl logs / logs-paqet / logs-reality
  paqet-middle-ctl reality-add-user <name>
  paqet-middle-ctl reality-list-users
  paqet-middle-ctl reality-show-user <name>
  paqet-middle-ctl reality-delete-user <name>
  paqet-middle-ctl reality-menu
  paqet-middle-ctl info

INFO

    log_success "Connection information saved"
}

create_reality_setup_script() {
    log_info "Creating reality-ezpz bootstrap script..."

    # This script runs after containers are up to initialize reality-ezpz
    cat > "$INSTALL_DIR/setup-reality.sh" << SCRIPT
#!/bin/bash
set -e

echo "Waiting for reality-ezpz container to be ready..."
sleep 5

# Check if reality-ezpz container is running
if ! docker ps --format '{{.Names}}' | grep -q "reality-ezpz"; then
    echo "[WARN] reality-ezpz container not running yet, waiting longer..."
    sleep 10
fi

# Run initial setup with configured options
echo "Running reality-ezpz initial setup..."
docker exec reality-ezpz bash -c "
    cd /opt/reality-ezpz && \\
    bash reality-ezpz.sh \\
        --transport=${REALITY_TRANSPORT} \\
        --domain=${REALITY_SNI} \\
        --port=${REALITY_PORT} \\
        --core=sing-box \\
        --security=reality \\
        --add-user=${REALITY_INITIAL_USER} \\
    2>&1 || true
"

echo ""
echo "Setup complete! Showing user config..."
echo ""
docker exec reality-ezpz bash /opt/reality-ezpz/reality-ezpz.sh --show-user="${REALITY_INITIAL_USER}" 2>/dev/null || true
SCRIPT

    chmod +x "$INSTALL_DIR/setup-reality.sh"
    log_success "Reality setup script created"
}

#-------------------------------------------------------------------------------
# Build & Start
#-------------------------------------------------------------------------------

build_and_start() {
    log_info "Building and starting Docker Compose stack..."

    cd "$INSTALL_DIR"
    docker compose up -d --build

    sleep 3

    if docker compose ps | grep -q "Up\|running"; then
        log_success "Docker Compose stack is running!"
    else
        log_warn "Stack may not be fully ready yet. Check: paqet-middle-ctl status"
    fi
}

setup_reality() {
    log_info "Setting up reality-ezpz with initial user..."

    bash "$INSTALL_DIR/setup-reality.sh" 2>&1 || {
        log_warn "Reality-EZPZ auto-setup encountered an issue."
        log_warn "You can manually configure it with: paqet-middle-ctl reality-menu"
    }
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
    echo "    ↓ VLESS Reality (port $REALITY_PORT)"
    echo "  This VPS ($PUBLIC_IP)"
    echo "    ↓ KCP tunnel (port $SERVER_PORT)"
    echo "  Server VPS ($SERVER_IP)"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                            NEXT STEPS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Get your VLESS connection config for Shadowrocket:"
    echo -e "     ${BLUE}paqet-middle-ctl reality-show-user $REALITY_INITIAL_USER${NC}"
    echo ""
    echo "  2. Add more users:"
    echo -e "     ${BLUE}paqet-middle-ctl reality-add-user <username>${NC}"
    echo ""
    echo "  3. Check everything is running:"
    echo -e "     ${BLUE}paqet-middle-ctl status${NC}"
    echo ""
    echo "  4. View logs if needed:"
    echo -e "     ${BLUE}paqet-middle-ctl logs${NC}"
    echo ""
    echo "  5. Open TUI menu for advanced config:"
    echo -e "     ${BLUE}paqet-middle-ctl reality-menu${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠️  IMPORTANT: Use 'paqet-middle-ctl reality-show-user $REALITY_INITIAL_USER'${NC}"
    echo -e "  ${YELLOW}    to get the VLESS config string/QR code for your client app.${NC}"
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
    create_paqet_config
    create_dockerfile
    create_entrypoint
    create_docker_compose
    create_management_script
    create_reality_setup_script
    create_connection_info

    # Build & start
    build_and_start

    # Initialize reality-ezpz
    setup_reality

    # Done
    print_completion_message
}

main "$@"
