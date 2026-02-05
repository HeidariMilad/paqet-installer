# Paqet One-Click Installer

Automatically install and configure [paqet](https://github.com/hanselime/paqet) server and client with a single command. No technical knowledge required.

## What is Paqet?

Paqet is a bidirectional packet-level proxy that bypasses OS-level firewalls using raw sockets. It uses KCP for secure, encrypted transport.

---

# Server Installation (Ubuntu/Debian VPS)

SSH into your Ubuntu/Debian VPS and run:

```bash
curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/install.sh | sudo bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

### Custom Port

By default, the server uses port `9999`. To use a different port:

```bash
sudo ./install.sh 8888
```

## What the Installer Does

1. **Detects** your server's network configuration automatically:
   - Public IP address
   - Network interface (eth0, ens3, etc.)
   - Local IP address
   - Gateway MAC address
   - System architecture (amd64/arm64)

2. **Installs** all required dependencies:
   - Docker & Docker Compose
   - libpcap (inside container)
   - iptables utilities

3. **Configures** everything:
   - Downloads the correct paqet binary
   - Generates a secure secret key
   - Creates server configuration
   - Sets up required iptables rules
   - Makes iptables rules persistent
   - Creates Docker container

4. **Starts** the server automatically

5. **Generates** a ready-to-use client configuration

## After Installation

### View Connection Info

```bash
paqet-ctl info
```

This shows:
- Server IP and port
- Secret key
- Client setup instructions

### Get Client Configuration

```bash
paqet-ctl client-config
```

Copy this configuration to your client machine and update the network settings for your local machine.

### Management Commands

| Command | Description |
|---------|-------------|
| `paqet-ctl start` | Start the server |
| `paqet-ctl stop` | Stop the server |
| `paqet-ctl restart` | Restart the server |
| `paqet-ctl status` | Check server status |
| `paqet-ctl logs` | View server logs |
| `paqet-ctl config` | Show server configuration |
| `paqet-ctl client-config` | Show client configuration template |
| `paqet-ctl info` | Show all connection details |
| `paqet-ctl update` | Rebuild and restart |
| `paqet-ctl uninstall` | Remove containers |

---

# Client Installation (One-Click)

Use the one-click installers for your operating system. They automatically detect your network settings!

## Linux Client

```bash
curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-linux.sh | sudo bash
```

Or download and run:
```bash
wget https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-linux.sh
sudo bash install-linux.sh
```

## macOS Client

```bash
curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-macos.sh | sudo bash
```

Or download and run:
```bash
curl -O https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-macos.sh
sudo bash install-macos.sh
```

## Windows Client

1. Open PowerShell **as Administrator**
2. Run:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
iwr -useb https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/client/install-windows.ps1 | iex
```

Or download `install-windows.ps1` and run it as Administrator.

**Note:** Windows requires [Npcap](https://npcap.com/#download) to be installed first.

---

## What the Client Installers Do

1. **Auto-detect** your network settings (interface, IP, gateway MAC)
2. **Download** the correct paqet binary for your OS/architecture
3. **Prompt** for server IP, port, and secret key
4. **Create** configuration file
5. **Create** start scripts and optional system service

---

## Manual Client Setup

If you prefer manual setup:

### 1. Download Paqet for Your OS

Go to [Paqet Releases](https://github.com/hanselime/paqet/releases) and download:
- **macOS (Intel)**: `paqet-darwin-amd64-*.tar.gz`
- **macOS (Apple Silicon)**: `paqet-darwin-arm64-*.tar.gz`
- **Linux (x64)**: `paqet-linux-amd64-*.tar.gz`
- **Windows**: `paqet-windows-amd64-*.zip`

### 2. Get Your Client's Network Info

**On macOS:**
```bash
# Network interface
route -n get default | grep interface

# Your IP
ifconfig en0 | grep "inet "

# Gateway MAC
arp -n $(route -n get default | grep gateway | awk '{print $2}')
```

**On Linux:**
```bash
# Network interface & IP
ip a

# Gateway MAC
ip route | grep default  # Get gateway IP
ip neigh show <gateway_ip>
```

**On Windows (PowerShell):**
```powershell
# Interface info
Get-NetAdapter | Select-Object Name, InterfaceGuid

# IP and Gateway
ipconfig /all

# Gateway MAC
arp -a <gateway_ip>
```

### 3. Configure the Client

Get the client config from your server:
```bash
paqet-ctl client-config
```

Save it as `config.yaml` and update these values:
- `network.interface`: Your interface name (en0, eth0, wlan0, etc.)
- `network.ipv4.addr`: Your local IP (keep `:0` for random port)
- `network.ipv4.router_mac`: Your gateway's MAC address

### 4. Run the Client

```bash
# Extract
tar -xzf paqet-*.tar.gz

# Run (requires root for raw sockets)
sudo ./paqet run -c config.yaml
```

### 5. Test the Connection

```bash
curl https://httpbin.org/ip --proxy socks5h://127.0.0.1:1080
```

The response should show your **server's** public IP, not your client's IP.

### 6. Configure Applications

Set your applications to use SOCKS5 proxy:
- **Host**: `127.0.0.1`
- **Port**: `1080`

## Troubleshooting

### Server won't start
```bash
# Check logs
paqet-ctl logs

# Verify iptables rules
sudo iptables -t raw -L -n
sudo iptables -t mangle -L -n
```

### Connection timeout
1. Ensure your VPS firewall/security group allows TCP port 9999 (or your custom port)
2. Verify the secret key matches on client and server
3. Check that MAC addresses are correct

### "Permission denied" on client
Paqet requires root/admin privileges for raw sockets:
```bash
sudo ./paqet run -c config.yaml
```

### Can't detect gateway MAC
```bash
# Force ARP cache update
ping -c 1 <gateway_ip>
ip neigh show <gateway_ip>
```

## Security Notes

- **Keep your secret key safe** - anyone with it can connect to your server
- **Don't use standard ports** (80, 443) - iptables rules affect all traffic on those ports
- The connection is encrypted using AES via KCP

## Files Location

All files are installed to `/opt/paqet/`:
- `config.yaml` - Server configuration
- `client-config.yaml` - Client configuration template
- `connection-info.txt` - Full connection details
- `docker-compose.yml` - Docker configuration
- `Dockerfile` - Container build file
- `paqet` - The paqet binary

## Uninstall

```bash
# Remove containers
paqet-ctl uninstall

# Remove all files
sudo rm -rf /opt/paqet
sudo rm /usr/local/bin/paqet-ctl

# Remove iptables rules (replace PORT with your port)
sudo iptables -t raw -D PREROUTING -p tcp --dport PORT -j NOTRACK
sudo iptables -t raw -D OUTPUT -p tcp --sport PORT -j NOTRACK
sudo iptables -t mangle -D OUTPUT -p tcp --sport PORT --tcp-flags RST RST -j DROP
```

## License

This installer is provided as-is. Paqet is licensed under MIT.
