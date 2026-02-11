#!/bin/bash
set -e

#===============================================================================
# PAQET SERVER ONE-CLICK INSTALLER (Docker Edition)
# 
# This script automatically installs and configures paqet server on Ubuntu/Debian
# with Docker. It auto-detects all network settings.
#
# Usage: curl -sL <url>/install.sh | sudo bash
#    or: sudo bash install.sh
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/paqet"
DEFAULT_PORT=9999
PAQET_VERSION="v1.0.0-alpha.14"

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
    echo "║            One-Click Server Installer (Docker Edition)            ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script supports Ubuntu/Debian only."
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_warn "This script is designed for Ubuntu/Debian. Detected: $ID"
        log_warn "Proceeding anyway, but some features may not work."
    fi
    
    log_info "Detected OS: $PRETTY_NAME"
}

#-------------------------------------------------------------------------------
# Network Detection Functions
#-------------------------------------------------------------------------------

detect_public_ip() {
    log_info "Detecting public IP address..."
    
    # Try multiple services
    PUBLIC_IP=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null || \
                curl -4 -s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "Could not detect public IP address"
        exit 1
    fi
    
    log_success "Public IP: $PUBLIC_IP"
}

detect_interface() {
    log_info "Detecting primary network interface..."
    
    # Get the interface used for default route
    INTERFACE=$(ip route | grep default | head -n1 | awk '{print $5}')
    
    if [[ -z "$INTERFACE" ]]; then
        # Fallback: get first non-loopback interface
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
        log_error "Could not detect local IP address on interface $INTERFACE"
        exit 1
    fi
    
    log_success "Local IP: $LOCAL_IP"
}

detect_gateway_mac() {
    log_info "Detecting gateway MAC address..."
    
    # Get default gateway IP
    GATEWAY_IP=$(ip route | grep default | head -n1 | awk '{print $3}')
    
    if [[ -z "$GATEWAY_IP" ]]; then
        log_error "Could not detect gateway IP"
        exit 1
    fi
    
    log_info "Gateway IP: $GATEWAY_IP"
    
    # Ping gateway to ensure ARP entry exists
    ping -c 1 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
    
    # Get gateway MAC from ARP table
    GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $5}' | head -n1)
    
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "FAILED" ]]; then
        # Try arp command as fallback
        GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | grep -v Address | awk '{print $3}' | head -n1)
    fi
    
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "(incomplete)" ]]; then
        log_error "Could not detect gateway MAC address"
        log_error "Please run: ping $GATEWAY_IP && ip neigh show $GATEWAY_IP"
        exit 1
    fi
    
    log_success "Gateway MAC: $GATEWAY_MAC"
}

detect_architecture() {
    log_info "Detecting system architecture..."
    
    ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64)
            PAQET_ARCH="linux-amd64"
            ;;
        aarch64|arm64)
            PAQET_ARCH="linux-arm64"
            ;;
        armv7l|armhf)
            PAQET_ARCH="linux-arm32"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    log_success "Architecture: $ARCH -> $PAQET_ARCH"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------

install_docker() {
    log_info "Checking Docker installation..."
    
    if command -v docker &> /dev/null; then
        log_success "Docker is already installed"
        return
    fi
    
    log_info "Installing Docker..."
    
    # Install prerequisites
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker installed successfully"
}

install_dependencies() {
    log_info "Installing system dependencies..."
    
    apt-get update
    apt-get install -y curl iptables net-tools iproute2
    
    log_success "Dependencies installed"
}

generate_secret_key() {
    log_info "Generating secure secret key..."
    
    # Generate a random 32-character key
    SECRET_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    if [[ -z "$SECRET_KEY" ]]; then
        # Fallback method
        SECRET_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
    fi
    
    log_success "Secret key generated"
}

setup_iptables() {
    log_info "Configuring iptables rules for port $PORT..."
    
    # Remove existing rules if any (ignore errors)
    iptables -t raw -D PREROUTING -p tcp --dport "$PORT" -j NOTRACK 2>/dev/null || true
    iptables -t raw -D OUTPUT -p tcp --sport "$PORT" -j NOTRACK 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --sport "$PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true
    
    # Add rules
    iptables -t raw -A PREROUTING -p tcp --dport "$PORT" -j NOTRACK
    iptables -t raw -A OUTPUT -p tcp --sport "$PORT" -j NOTRACK
    iptables -t mangle -A OUTPUT -p tcp --sport "$PORT" --tcp-flags RST RST -j DROP
    
    log_success "iptables rules configured"
    
    # Make rules persistent
    log_info "Making iptables rules persistent..."
    
    # Install iptables-persistent if not present
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent 2>/dev/null || true
    
    # Save rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    log_success "iptables rules saved"
}

create_install_directory() {
    log_info "Creating installation directory: $INSTALL_DIR"
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_success "Installation directory created"
}

create_dockerfile() {
    log_info "Creating Dockerfile..."
    
    cat > "$INSTALL_DIR/Dockerfile" << 'DOCKERFILE'
FROM debian:bookworm-slim

# Avoid interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    libpcap-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy binary and config
COPY paqet /app/paqet
COPY config.yaml /app/config.yaml

# Make binary executable
RUN chmod +x /app/paqet

# Run paqet
ENTRYPOINT ["/app/paqet", "run", "-c", "/app/config.yaml"]
DOCKERFILE

    log_success "Dockerfile created"
}

download_paqet() {
    log_info "Downloading paqet ${PAQET_VERSION} for ${PAQET_ARCH}..."
    
    DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-${PAQET_ARCH}-${PAQET_VERSION}.tar.gz"
    
    curl -sL "$DOWNLOAD_URL" -o paqet.tar.gz
    
    if [[ ! -f paqet.tar.gz ]]; then
        log_error "Failed to download paqet"
        exit 1
    fi
    
    tar -xzf paqet.tar.gz
    rm paqet.tar.gz
    
    # Find and rename the binary
    BINARY_NAME=$(ls paqet* 2>/dev/null | head -n1)
    if [[ -n "$BINARY_NAME" && "$BINARY_NAME" != "paqet" ]]; then
        mv "$BINARY_NAME" paqet
    fi
    
    chmod +x paqet
    
    log_success "paqet downloaded and extracted"
}

create_server_config() {
    log_info "Creating server configuration..."
    
    cat > "$INSTALL_DIR/config.yaml" << YAML
# paqet Server Configuration
# Auto-generated by installer on $(date)

role: "server"

log:
  level: "info"

listen:
  addr: ":${PORT}"

network:
  interface: "${INTERFACE}"
  ipv4:
    addr: "${LOCAL_IP}:${PORT}"
    router_mac: "${GATEWAY_MAC}"
  tcp:
    local_flag: ["PA"]

transport:
  protocol: "kcp"
  conn: 1
  kcp:
    mode: "fast"
    key: "${SECRET_KEY}"
YAML

    log_success "Server configuration created"
}

create_docker_compose() {
    log_info "Creating docker-compose.yml..."
    
    cat > "$INSTALL_DIR/docker-compose.yml" << YAML
version: '3.8'

services:
  paqet:
    build: .
    container_name: paqet-server
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./logs:/app/logs
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
YAML

    log_success "docker-compose.yml created"
}

create_management_script() {
    log_info "Creating management scripts..."
    
    # Main management script
    cat > "$INSTALL_DIR/paqet-ctl" << 'SCRIPT'
#!/bin/bash

INSTALL_DIR="/opt/paqet"
cd "$INSTALL_DIR"

case "$1" in
    start)
        echo "Starting paqet server..."
        docker compose up -d --build
        echo "Done. Check status with: paqet-ctl status"
        ;;
    stop)
        echo "Stopping paqet server..."
        docker compose down
        echo "Done."
        ;;
    restart)
        echo "Restarting paqet server..."
        docker compose restart
        echo "Done."
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f --tail=100
        ;;
    config)
        cat "$INSTALL_DIR/config.yaml"
        ;;
    client-config)
        cat "$INSTALL_DIR/client-config.yaml"
        ;;
    info)
        cat "$INSTALL_DIR/connection-info.txt"
        ;;
    update)
        echo "Updating paqet..."
        docker compose down
        docker compose build --no-cache
        docker compose up -d
        echo "Done."
        ;;
    uninstall)
        echo "Uninstalling paqet..."
        docker compose down
        docker rmi paqet-paqet 2>/dev/null || true
        echo "Docker containers removed."
        echo "To completely remove, run: rm -rf $INSTALL_DIR"
        ;;
    *)
        echo "Paqet Server Management"
        echo ""
        echo "Usage: paqet-ctl <command>"
        echo ""
        echo "Commands:"
        echo "  start         Start the paqet server"
        echo "  stop          Stop the paqet server"
        echo "  restart       Restart the paqet server"
        echo "  status        Show server status"
        echo "  logs          Show server logs (follow mode)"
        echo "  config        Show server configuration"
        echo "  client-config Show client configuration template"
        echo "  info          Show connection information"
        echo "  update        Rebuild and restart the server"
        echo "  uninstall     Remove paqet containers"
        ;;
esac
SCRIPT

    chmod +x "$INSTALL_DIR/paqet-ctl"
    
    # Create symlink for easy access
    ln -sf "$INSTALL_DIR/paqet-ctl" /usr/local/bin/paqet-ctl
    
    log_success "Management script created: paqet-ctl"
}

create_client_config_template() {
    log_info "Creating client configuration template..."
    
    cat > "$INSTALL_DIR/client-config.yaml" << YAML
# paqet Client Configuration
# Generated for server: ${PUBLIC_IP}:${PORT}
# 
# INSTRUCTIONS:
# 1. Download paqet for your OS from:
#    https://github.com/hanselime/paqet/releases/tag/${PAQET_VERSION}
#
# 2. Save this file as config.yaml on your client machine
#
# 3. IMPORTANT: Update the following values for YOUR client machine:
#    - network.interface: Your network interface (run: ip a)
#    - network.ipv4.addr: Your local IP (run: ip a)
#    - network.ipv4.router_mac: Your gateway MAC (run: ip neigh)
#
# 4. Run: sudo ./paqet run -c config.yaml
#
# 5. Configure your apps to use SOCKS5 proxy at 127.0.0.1:1080

role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"          # CHANGE THIS: Your network interface
  ipv4:
    addr: "192.168.1.100:0"  # CHANGE THIS: Your local IP (keep :0 for random port)
    router_mac: "aa:bb:cc:dd:ee:ff"  # CHANGE THIS: Your gateway MAC address

server:
  addr: "${PUBLIC_IP}:${PORT}"  # Server address (already configured)

transport:
  protocol: "kcp"
  conn: 1
  kcp:
    mode: "fast"
    key: "${SECRET_KEY}"  # Secret key (already configured - DO NOT CHANGE)
YAML

    log_success "Client configuration template created"
}

create_connection_info() {
    log_info "Creating connection information file..."
    
    cat > "$INSTALL_DIR/connection-info.txt" << INFO
╔═══════════════════════════════════════════════════════════════════════════════╗
║                        PAQET SERVER CONNECTION INFO                           ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Installation completed: $(date)

SERVER DETAILS
══════════════
  Public IP:     ${PUBLIC_IP}
  Port:          ${PORT}
  Interface:     ${INTERFACE}
  Local IP:      ${LOCAL_IP}
  Gateway MAC:   ${GATEWAY_MAC}

SECRET KEY (Keep this safe!)
════════════════════════════
  ${SECRET_KEY}

CLIENT SETUP INSTRUCTIONS
═════════════════════════
1. Download paqet for your OS:
   https://github.com/hanselime/paqet/releases/tag/${PAQET_VERSION}

2. Copy the client configuration:
   - File location: ${INSTALL_DIR}/client-config.yaml
   - Or run: paqet-ctl client-config

3. Edit the client config and update these values for YOUR machine:
   - network.interface: Your network interface (e.g., en0, eth0, wlan0)
   - network.ipv4.addr: Your local IP address
   - network.ipv4.router_mac: Your gateway's MAC address

4. Run the client:
   sudo ./paqet run -c config.yaml

5. Configure applications to use SOCKS5 proxy:
   Host: 127.0.0.1
   Port: 1080

6. Test with curl:
   curl https://httpbin.org/ip --proxy socks5h://127.0.0.1:1080

MANAGEMENT COMMANDS
═══════════════════
  paqet-ctl start        - Start the server
  paqet-ctl stop         - Stop the server
  paqet-ctl restart      - Restart the server
  paqet-ctl status       - Check server status
  paqet-ctl logs         - View server logs
  paqet-ctl client-config - Show client configuration
  paqet-ctl info         - Show this information

TROUBLESHOOTING
═══════════════
- Ensure firewall allows TCP port ${PORT}
- Check logs: paqet-ctl logs
- Verify iptables rules: sudo iptables -t raw -L -n

INFO

    log_success "Connection information saved"
}

build_and_start() {
    log_info "Building Docker image and starting paqet server..."
    
    cd "$INSTALL_DIR"
    
    docker compose up -d --build
    
    # Wait a moment and check status
    sleep 3
    
    if docker compose ps | grep -q "Up"; then
        log_success "Paqet server is running!"
    else
        log_error "Failed to start paqet server. Check logs with: paqet-ctl logs"
        exit 1
    fi
}

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
    echo -e "${YELLOW}                            SERVER INFORMATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Server Address:${NC}  ${PUBLIC_IP}:${PORT}"
    echo -e "  ${GREEN}Secret Key:${NC}      ${SECRET_KEY}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                              NEXT STEPS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Get client configuration:"
    echo -e "     ${BLUE}paqet-ctl client-config${NC}"
    echo ""
    echo "  2. View all connection details:"
    echo -e "     ${BLUE}paqet-ctl info${NC}"
    echo ""
    echo "  3. Check server status:"
    echo -e "     ${BLUE}paqet-ctl status${NC}"
    echo ""
    echo "  4. View logs:"
    echo -e "     ${BLUE}paqet-ctl logs${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠️  IMPORTANT: Save your secret key securely!${NC}"
    echo -e "  ${YELLOW}    You'll need it to configure the client.${NC}"
    echo ""
    echo -e "  Files saved to: ${INSTALL_DIR}"
    echo ""
}

#-------------------------------------------------------------------------------
# Main Installation Flow
#-------------------------------------------------------------------------------

main() {
    print_banner
    
    check_root
    check_os
    
    # Get port from argument or use default
    PORT="${1:-$DEFAULT_PORT}"
    log_info "Using port: $PORT"
    
    # Detect network settings
    detect_architecture
    detect_interface
    detect_local_ip
    detect_public_ip
    detect_gateway_mac
    
    # Generate secret key
    generate_secret_key
    
    echo ""
    log_info "Starting installation..."
    echo ""
    
    # Install dependencies
    install_dependencies
    install_docker
    
    # Setup iptables (must be done on host, not in container)
    setup_iptables
    
    # Create installation directory and files
    create_install_directory
    download_paqet
    create_dockerfile
    create_server_config
    create_docker_compose
    create_management_script
    create_client_config_template
    create_connection_info
    
    # Build and start
    build_and_start
    
    # Print completion message
    print_completion_message
}

# Run main function with optional port argument
main "$@"
