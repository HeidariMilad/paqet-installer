#!/bin/bash
set -e

#===============================================================================
# PAQET CLIENT ONE-CLICK INSTALLER - macOS
#
# This script automatically installs and configures paqet client on macOS.
# It auto-detects your network settings.
#
# Usage: sudo bash install-macos.sh
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
    echo "║               Client Installer - macOS                            ║"
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

check_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Network Detection Functions
#-------------------------------------------------------------------------------

detect_interface() {
    log_info "Detecting primary network interface..."
    
    # Get the default route interface
    INTERFACE=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}')
    
    if [[ -z "$INTERFACE" ]]; then
        # Fallback: try common interfaces
        for iface in en0 en1 en2; do
            if ifconfig "$iface" 2>/dev/null | grep -q "inet "; then
                INTERFACE="$iface"
                break
            fi
        done
    fi
    
    if [[ -z "$INTERFACE" ]]; then
        log_error "Could not detect network interface"
        exit 1
    fi
    
    log_success "Network interface: $INTERFACE"
}

detect_local_ip() {
    log_info "Detecting local IP address..."
    
    LOCAL_IP=$(ifconfig "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}')
    
    if [[ -z "$LOCAL_IP" ]]; then
        log_error "Could not detect local IP address on interface $INTERFACE"
        exit 1
    fi
    
    log_success "Local IP: $LOCAL_IP"
}

detect_gateway_mac() {
    log_info "Detecting gateway MAC address..."
    
    # Get default gateway IP
    GATEWAY_IP=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
    
    if [[ -z "$GATEWAY_IP" ]]; then
        log_error "Could not detect gateway IP"
        exit 1
    fi
    
    log_info "Gateway IP: $GATEWAY_IP"
    
    # Ping gateway to ensure ARP entry exists
    ping -c 1 -W 1 "$GATEWAY_IP" > /dev/null 2>&1 || true
    
    # Get gateway MAC from ARP table
    GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | grep -v Address | awk '{print $4}')
    
    if [[ -z "$GATEWAY_MAC" || "$GATEWAY_MAC" == "(incomplete)" ]]; then
        log_error "Could not detect gateway MAC address"
        log_error "Please run: ping $GATEWAY_IP && arp -n $GATEWAY_IP"
        exit 1
    fi
    
    log_success "Gateway MAC: $GATEWAY_MAC"
}

detect_architecture() {
    log_info "Detecting system architecture..."
    
    ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64)
            PAQET_ARCH="darwin-amd64"
            ;;
        arm64)
            PAQET_ARCH="darwin-arm64"
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

check_xcode_tools() {
    log_info "Checking Xcode Command Line Tools (required for libpcap)..."
    
    if ! xcode-select -p &> /dev/null; then
        log_info "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        
        echo ""
        log_warn "Please complete the Xcode Command Line Tools installation"
        log_warn "Then run this script again"
        exit 0
    fi
    
    log_success "Xcode Command Line Tools installed"
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
    # Get the actual user's home directory (not root's)
    ACTUAL_USER="${SUDO_USER:-$USER}"
    ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)
    INSTALL_DIR="$ACTUAL_HOME/.paqet"
    
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
    
    # Fix ownership
    ACTUAL_USER="${SUDO_USER:-$USER}"
    chown -R "$ACTUAL_USER" "$INSTALL_DIR"
    
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

    # Fix ownership
    ACTUAL_USER="${SUDO_USER:-$USER}"
    chown "$ACTUAL_USER" "$INSTALL_DIR/config.yaml"
    
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
    
    # Fix ownership
    ACTUAL_USER="${SUDO_USER:-$USER}"
    chown "$ACTUAL_USER" "$INSTALL_DIR/start.sh"
    
    # Create symlink
    ln -sf "$INSTALL_DIR/start.sh" /usr/local/bin/paqet-client 2>/dev/null || true
    
    log_success "Run script created"
}

create_launchd_service() {
    log_info "Creating launchd service (optional)..."
    
    ACTUAL_USER="${SUDO_USER:-$USER}"
    ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)
    
    cat > "/Library/LaunchDaemons/com.paqet.client.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.paqet.client</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/paqet</string>
        <string>run</string>
        <string>-c</string>
        <string>${INSTALL_DIR}/config.yaml</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/paqet.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/paqet.err</string>
</dict>
</plist>
PLIST

    log_success "Launchd service created"
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
    echo -e "     ${BLUE}sudo launchctl load /Library/LaunchDaemons/com.paqet.client.plist${NC}"
    echo "  Stop service:"
    echo -e "     ${BLUE}sudo launchctl unload /Library/LaunchDaemons/com.paqet.client.plist${NC}"
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
    echo "  Configure System Proxy:"
    echo "     System Preferences → Network → Advanced → Proxies → SOCKS Proxy"
    echo "     Server: 127.0.0.1  Port: 1080"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                             UNINSTALL${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  To completely remove paqet client:"
    echo -e "     ${BLUE}curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-macos.sh | sudo bash -s -- --uninstall${NC}"
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
    
    # Get actual user's home
    ACTUAL_USER="${SUDO_USER:-$USER}"
    ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)
    INSTALL_DIR="$ACTUAL_HOME/.paqet"
    
    # Stop and remove launchd service
    log_info "Stopping launchd service..."
    launchctl unload /Library/LaunchDaemons/com.paqet.client.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/com.paqet.client.plist 2>/dev/null || true
    log_success "Launchd service removed"
    
    # Remove symlink
    log_info "Removing symlinks..."
    rm -f /usr/local/bin/paqet-client 2>/dev/null || true
    log_success "Symlinks removed"
    
    # Remove installation directory
    log_info "Removing installation directory..."
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
        check_macos
        uninstall_paqet
        exit 0
    fi
    
    print_banner
    
    check_root
    check_macos
    check_xcode_tools
    
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
    create_install_directory
    download_paqet
    create_client_config
    create_run_script
    create_launchd_service
    
    # Done
    print_completion_message
}

main "$@"
