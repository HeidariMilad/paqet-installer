#!/bin/bash
set -e

#===============================================================================
# PAQET CLIENT ONE-CLICK INSTALLER - Linux
#
# This script automatically installs and configures paqet client on Linux.
# It auto-detects your network settings.
#
# Usage: sudo bash install-linux.sh
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
INSTALL_DIR="$HOME/.paqet"
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
    echo "║               Client Installer - Linux                            ║"
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

#-------------------------------------------------------------------------------
# Network Detection Functions
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
        log_error "Could not detect local IP address on interface $INTERFACE"
        exit 1
    fi
    
    log_success "Local IP: $LOCAL_IP"
}

detect_gateway_mac() {
    log_info "Detecting gateway MAC address..."
    
    GATEWAY_IP=$(ip route | grep default | head -n1 | awk '{print $3}')
    
    if [[ -z "$GATEWAY_IP" ]]; then
        log_error "Could not detect gateway IP"
        exit 1
    fi
    
    log_info "Gateway IP: $GATEWAY_IP"
    
    # Ping gateway to ensure ARP entry exists
    ping -c 1 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
    
    GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $5}' | head -n1)
    
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "FAILED" ]]; then
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

install_dependencies() {
    log_info "Installing dependencies..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y libpcap-dev curl
    elif command -v yum &> /dev/null; then
        yum install -y libpcap-devel curl
    elif command -v dnf &> /dev/null; then
        dnf install -y libpcap-devel curl
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm libpcap curl
    else
        log_warn "Could not detect package manager. Please install libpcap manually."
    fi
    
    log_success "Dependencies installed"
}

get_server_info() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                    SERVER CONNECTION DETAILS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Enter the details from your paqet server (run 'paqet-ctl info' on server)"
    echo ""
    
    # Use /dev/tty to read input even when script is piped
    echo -n "Server IP address: "
    read SERVER_IP < /dev/tty
    echo -n "Server port [9999]: "
    read SERVER_PORT < /dev/tty
    SERVER_PORT="${SERVER_PORT:-9999}"
    echo -n "Secret key: "
    read SECRET_KEY < /dev/tty
    
    if [[ -z "$SERVER_IP" || -z "$SECRET_KEY" ]]; then
        log_error "Server IP and secret key are required"
        exit 1
    fi
    
    echo ""
    log_success "Server: $SERVER_IP:$SERVER_PORT"
}

create_install_directory() {
    log_info "Creating installation directory: $INSTALL_DIR"
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_success "Installation directory created"
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
    
    BINARY_NAME=$(ls paqet* 2>/dev/null | head -n1)
    if [[ -n "$BINARY_NAME" && "$BINARY_NAME" != "paqet" ]]; then
        mv "$BINARY_NAME" paqet
    fi
    
    chmod +x paqet
    
    log_success "paqet downloaded and extracted"
}

create_client_config() {
    log_info "Creating client configuration..."
    
    cat > "$INSTALL_DIR/config.yaml" << YAML
# paqet Client Configuration
# Auto-generated on $(date)

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
YAML

    log_success "Client configuration created"
}

create_run_script() {
    log_info "Creating run script..."
    
    cat > "$INSTALL_DIR/start.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
echo "Starting paqet client..."
echo "SOCKS5 proxy will be available at 127.0.0.1:1080"
echo "Press Ctrl+C to stop"
echo ""
sudo ./paqet run -c config.yaml
SCRIPT

    chmod +x "$INSTALL_DIR/start.sh"
    
    # Create symlink
    ln -sf "$INSTALL_DIR/start.sh" /usr/local/bin/paqet-client 2>/dev/null || true
    
    log_success "Run script created"
}

create_systemd_service() {
    log_info "Creating systemd service (optional)..."
    
    cat > /etc/systemd/system/paqet-client.service << SERVICE
[Unit]
Description=Paqet Client
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/paqet run -c $INSTALL_DIR/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    
    log_success "Systemd service created (use 'systemctl start paqet-client' to run as service)"
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
    echo -e "${YELLOW}                              HOW TO USE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Start the client:"
    echo -e "     ${BLUE}sudo $INSTALL_DIR/start.sh${NC}"
    echo "  or:"
    echo -e "     ${BLUE}sudo paqet-client${NC}"
    echo ""
    echo "  Run as system service:"
    echo -e "     ${BLUE}sudo systemctl start paqet-client${NC}"
    echo -e "     ${BLUE}sudo systemctl enable paqet-client${NC}  (start on boot)"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                           PROXY SETTINGS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  SOCKS5 Proxy: 127.0.0.1:1080"
    echo ""
    echo "  Test with curl:"
    echo -e "     ${BLUE}curl https://httpbin.org/ip --proxy socks5h://127.0.0.1:1080${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                             UNINSTALL${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  To completely remove paqet client:"
    echo -e "     ${BLUE}curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-linux.sh | sudo bash -s -- --uninstall${NC}"
    echo ""
    echo -e "  Files installed to: ${INSTALL_DIR}"
    echo ""
}

#-------------------------------------------------------------------------------
# Uninstall Function
#-------------------------------------------------------------------------------

uninstall_paqet() {
    print_banner
    
    echo -e "${YELLOW}Uninstalling paqet client...${NC}"
    echo ""
    
    # Stop and disable systemd service
    log_info "Stopping systemd service..."
    systemctl stop paqet-client 2>/dev/null || true
    systemctl disable paqet-client 2>/dev/null || true
    rm -f /etc/systemd/system/paqet-client.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log_success "Systemd service removed"
    
    # Remove symlink
    log_info "Removing symlinks..."
    rm -f /usr/local/bin/paqet-client 2>/dev/null || true
    log_success "Symlinks removed"
    
    # Remove installation directory
    log_info "Removing installation directory..."
    INSTALL_DIR="/root/.paqet"
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log_success "Installation directory removed: $INSTALL_DIR"
    else
        log_warn "Installation directory not found: $INSTALL_DIR"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Paqet client has been completely uninstalled.${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# Main Installation Flow
#-------------------------------------------------------------------------------

main() {
    # Check for uninstall flag
    if [[ "$1" == "--uninstall" || "$1" == "-u" ]]; then
        check_root
        uninstall_paqet
        exit 0
    fi
    
    print_banner
    
    check_root
    
    # Detect network settings
    detect_architecture
    detect_interface
    detect_local_ip
    detect_gateway_mac
    
    # Get server connection details
    get_server_info
    
    echo ""
    log_info "Starting installation..."
    echo ""
    
    # Install
    install_dependencies
    create_install_directory
    download_paqet
    create_client_config
    create_run_script
    create_systemd_service
    
    # Done
    print_completion_message
}

main "$@"
