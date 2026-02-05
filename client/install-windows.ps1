#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Paqet Client One-Click Installer for Windows

.DESCRIPTION
    This script automatically installs and configures paqet client on Windows.
    It auto-detects your network settings.

.NOTES
    Requirements:
    - Windows 10/11 or Windows Server 2016+
    - PowerShell 5.1 or higher
    - Npcap (will prompt to install if not present)
    - Run as Administrator

.EXAMPLE
    .\install-windows.ps1
#>

$ErrorActionPreference = "Stop"

# Configuration
$INSTALL_DIR = "$env:LOCALAPPDATA\paqet"
$PAQET_VERSION = "v1.0.0-alpha.14"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                                                   ║" -ForegroundColor Cyan
    Write-Host "  ║   ██████╗  █████╗  ██████╗ ███████╗████████╗                      ║" -ForegroundColor Cyan
    Write-Host "  ║   ██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝                      ║" -ForegroundColor Cyan
    Write-Host "  ║   ██████╔╝███████║██║   ██║█████╗     ██║                         ║" -ForegroundColor Cyan
    Write-Host "  ║   ██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝     ██║                         ║" -ForegroundColor Cyan
    Write-Host "  ║   ██║     ██║  ██║╚██████╔╝███████╗   ██║                         ║" -ForegroundColor Cyan
    Write-Host "  ║   ╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝   ╚═╝                         ║" -ForegroundColor Cyan
    Write-Host "  ║                                                                   ║" -ForegroundColor Cyan
    Write-Host "  ║               Client Installer - Windows                          ║" -ForegroundColor Cyan
    Write-Host "  ║                                                                   ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Info($message) {
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $message
}

function Write-Success($message) {
    Write-Host "[SUCCESS] " -ForegroundColor Green -NoNewline
    Write-Host $message
}

function Write-Warning($message) {
    Write-Host "[WARNING] " -ForegroundColor Yellow -NoNewline
    Write-Host $message
}

function Write-Error($message) {
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $message
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#-------------------------------------------------------------------------------
# Network Detection Functions
#-------------------------------------------------------------------------------

function Get-NetworkInterface {
    Write-Info "Detecting primary network interface..."
    
    # Get the active network adapter with default gateway
    $adapter = Get-NetAdapter | Where-Object { 
        $_.Status -eq 'Up' -and 
        (Get-NetIPConfiguration -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).IPv4DefaultGateway
    } | Select-Object -First 1
    
    if (-not $adapter) {
        Write-Error "Could not detect network interface"
        exit 1
    }
    
    $script:INTERFACE_NAME = $adapter.Name
    $script:INTERFACE_GUID = $adapter.InterfaceGuid
    $script:INTERFACE_INDEX = $adapter.ifIndex
    
    Write-Success "Network interface: $INTERFACE_NAME"
    Write-Info "Interface GUID: $INTERFACE_GUID"
    
    return $adapter
}

function Get-LocalIP {
    Write-Info "Detecting local IP address..."
    
    $ipConfig = Get-NetIPAddress -InterfaceIndex $INTERFACE_INDEX -AddressFamily IPv4 | 
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | 
                Select-Object -First 1
    
    if (-not $ipConfig) {
        Write-Error "Could not detect local IP address"
        exit 1
    }
    
    $script:LOCAL_IP = $ipConfig.IPAddress
    Write-Success "Local IP: $LOCAL_IP"
}

function Get-GatewayMAC {
    Write-Info "Detecting gateway MAC address..."
    
    # Get default gateway
    $gateway = (Get-NetIPConfiguration -InterfaceIndex $INTERFACE_INDEX).IPv4DefaultGateway
    
    if (-not $gateway) {
        Write-Error "Could not detect gateway IP"
        exit 1
    }
    
    $script:GATEWAY_IP = $gateway.NextHop
    Write-Info "Gateway IP: $GATEWAY_IP"
    
    # Ping gateway to populate ARP cache
    Test-Connection -ComputerName $GATEWAY_IP -Count 1 -Quiet | Out-Null
    
    # Get MAC from ARP table
    $arpEntry = Get-NetNeighbor -IPAddress $GATEWAY_IP -ErrorAction SilentlyContinue | 
                Where-Object { $_.State -ne 'Unreachable' } |
                Select-Object -First 1
    
    if (-not $arpEntry -or -not $arpEntry.LinkLayerAddress) {
        Write-Error "Could not detect gateway MAC address"
        Write-Error "Please run: ping $GATEWAY_IP; arp -a $GATEWAY_IP"
        exit 1
    }
    
    # Convert MAC format from XX-XX-XX-XX-XX-XX to xx:xx:xx:xx:xx:xx
    $script:GATEWAY_MAC = ($arpEntry.LinkLayerAddress -replace '-', ':').ToLower()
    Write-Success "Gateway MAC: $GATEWAY_MAC"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------

function Test-Npcap {
    Write-Info "Checking Npcap installation..."
    
    $npcapPath = "$env:SystemRoot\System32\Npcap"
    $npcapInstalled = Test-Path $npcapPath
    
    if (-not $npcapInstalled) {
        Write-Warning "Npcap is not installed!"
        Write-Host ""
        Write-Host "  Npcap is required for paqet to work on Windows." -ForegroundColor Yellow
        Write-Host "  Please download and install Npcap from: " -NoNewline
        Write-Host "https://npcap.com/#download" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Installation options:" -ForegroundColor Yellow
        Write-Host "    - Check 'Install Npcap in WinPcap API-compatible Mode'"
        Write-Host ""
        
        $response = Read-Host "Would you like to open the download page? (Y/n)"
        if ($response -ne 'n' -and $response -ne 'N') {
            Start-Process "https://npcap.com/#download"
        }
        
        Write-Host ""
        Write-Warning "Please install Npcap and run this script again."
        exit 0
    }
    
    Write-Success "Npcap is installed"
}

function Get-ServerInfo {
    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                      SERVER CONNECTION DETAILS" -ForegroundColor Yellow
    Write-Host "  ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Enter the details from your paqet server (run 'paqet-ctl info' on server)"
    Write-Host ""
    
    $script:SERVER_IP = Read-Host "  Server IP address"
    $portInput = Read-Host "  Server port [9999]"
    $script:SERVER_PORT = if ($portInput) { $portInput } else { "9999" }
    $script:SECRET_KEY = Read-Host "  Secret key"
    
    if (-not $SERVER_IP -or -not $SECRET_KEY) {
        Write-Error "Server IP and secret key are required"
        exit 1
    }
    
    Write-Host ""
    Write-Success "Server: ${SERVER_IP}:${SERVER_PORT}"
}

function New-InstallDirectory {
    Write-Info "Creating installation directory: $INSTALL_DIR"
    
    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    }
    
    Write-Success "Installation directory created"
}

function Get-Paqet {
    Write-Info "Downloading paqet $PAQET_VERSION for Windows..."
    
    $downloadUrl = "https://github.com/hanselime/paqet/releases/download/$PAQET_VERSION/paqet-windows-amd64-$PAQET_VERSION.zip"
    $zipPath = "$INSTALL_DIR\paqet.zip"
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    }
    catch {
        Write-Error "Failed to download paqet: $_"
        exit 1
    }
    
    # Extract
    Expand-Archive -Path $zipPath -DestinationPath $INSTALL_DIR -Force
    Remove-Item $zipPath -Force
    
    # Find and rename binary
    $binary = Get-ChildItem -Path $INSTALL_DIR -Filter "paqet*.exe" | Select-Object -First 1
    if ($binary -and $binary.Name -ne "paqet.exe") {
        Rename-Item -Path $binary.FullName -NewName "paqet.exe" -Force
    }
    
    Write-Success "paqet downloaded and extracted"
}

function New-ClientConfig {
    Write-Info "Creating client configuration..."
    
    # Format interface GUID for Npcap
    $npcapInterface = "\Device\NPF_$INTERFACE_GUID"
    
    $config = @"
# paqet Client Configuration
# Auto-generated on $(Get-Date)

role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "$INTERFACE_NAME"
  guid: "$npcapInterface"
  ipv4:
    addr: "${LOCAL_IP}:0"
    router_mac: "$GATEWAY_MAC"
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
    key: "$SECRET_KEY"
"@
    
    $config | Out-File -FilePath "$INSTALL_DIR\config.yaml" -Encoding utf8
    
    Write-Success "Client configuration created"
}

function New-RunScript {
    Write-Info "Creating run scripts..."
    
    # PowerShell run script
    $psScript = @"
# Paqet Client Launcher
`$ErrorActionPreference = "Stop"

Write-Host "Starting paqet client..." -ForegroundColor Cyan
Write-Host "SOCKS5 proxy will be available at 127.0.0.1:1080" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

Set-Location "$INSTALL_DIR"
& ".\paqet.exe" run -c config.yaml
"@
    
    $psScript | Out-File -FilePath "$INSTALL_DIR\start.ps1" -Encoding utf8
    
    # Batch file for easy double-click
    $batScript = @"
@echo off
echo Starting paqet client...
echo SOCKS5 proxy will be available at 127.0.0.1:1080
echo Press Ctrl+C to stop
echo.
cd /d "$INSTALL_DIR"
paqet.exe run -c config.yaml
pause
"@
    
    $batScript | Out-File -FilePath "$INSTALL_DIR\start.bat" -Encoding ascii
    
    # Create desktop shortcut
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\Paqet Client.lnk")
        $Shortcut.TargetPath = "$INSTALL_DIR\start.bat"
        $Shortcut.WorkingDirectory = $INSTALL_DIR
        $Shortcut.Description = "Start Paqet Client"
        $Shortcut.Save()
        Write-Success "Desktop shortcut created"
    }
    catch {
        Write-Warning "Could not create desktop shortcut"
    }
    
    Write-Success "Run scripts created"
}

function New-WindowsService {
    Write-Info "Creating Windows service (optional)..."
    
    # Create NSSM-style service configuration batch
    $serviceScript = @"
@echo off
REM Paqet Client Service Installation
REM Run this script as Administrator to install/uninstall the service

if "%1"=="install" (
    echo Installing paqet-client service...
    sc create paqet-client binPath= "$INSTALL_DIR\paqet.exe run -c $INSTALL_DIR\config.yaml" start= auto DisplayName= "Paqet Client"
    sc description paqet-client "Paqet SOCKS5 Proxy Client"
    echo Service installed. Start with: sc start paqet-client
    goto :end
)

if "%1"=="uninstall" (
    echo Stopping and removing paqet-client service...
    sc stop paqet-client
    sc delete paqet-client
    echo Service removed.
    goto :end
)

if "%1"=="start" (
    sc start paqet-client
    goto :end
)

if "%1"=="stop" (
    sc stop paqet-client
    goto :end
)

echo Usage: service.bat [install^|uninstall^|start^|stop]

:end
"@
    
    $serviceScript | Out-File -FilePath "$INSTALL_DIR\service.bat" -Encoding ascii
    
    Write-Success "Service script created (run 'service.bat install' as Admin to install)"
}

function Write-CompletionMessage {
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║                                                                               ║" -ForegroundColor Green
    Write-Host "  ║                    ✓ INSTALLATION COMPLETED SUCCESSFULLY!                    ║" -ForegroundColor Green
    Write-Host "  ║                                                                               ║" -ForegroundColor Green
    Write-Host "  ╚═══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                                HOW TO USE" -ForegroundColor Yellow
    Write-Host "  ═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Start the client (choose one method):" -ForegroundColor White
    Write-Host ""
    Write-Host "    1. Double-click the " -NoNewline
    Write-Host "'Paqet Client'" -ForegroundColor Cyan -NoNewline
    Write-Host " shortcut on your Desktop"
    Write-Host ""
    Write-Host "    2. Run in PowerShell (as Administrator):"
    Write-Host "       " -NoNewline
    Write-Host "$INSTALL_DIR\start.ps1" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    3. Run the batch file:"
    Write-Host "       " -NoNewline
    Write-Host "$INSTALL_DIR\start.bat" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  Install as Windows Service (run as Administrator):"
    Write-Host "       " -NoNewline
    Write-Host "$INSTALL_DIR\service.bat install" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                             PROXY SETTINGS" -ForegroundColor Yellow
    Write-Host "  ═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  SOCKS5 Proxy: " -NoNewline
    Write-Host "127.0.0.1:1080" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Configure in Windows:"
    Write-Host "    Settings → Network & Internet → Proxy → Manual proxy setup"
    Write-Host "    Or use a browser extension like FoxyProxy/SwitchyOmega"
    Write-Host ""
    Write-Host "  Test with curl:"
    Write-Host "       " -NoNewline
    Write-Host "curl https://httpbin.org/ip --proxy socks5h://127.0.0.1:1080" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  Files installed to: " -NoNewline
    Write-Host "$INSTALL_DIR" -ForegroundColor Cyan
    Write-Host ""
}

#-------------------------------------------------------------------------------
# Main Installation Flow
#-------------------------------------------------------------------------------

function Main {
    Write-Banner
    
    if (-not (Test-Administrator)) {
        Write-Error "This script must be run as Administrator"
        Write-Host "Right-click PowerShell and select 'Run as Administrator'"
        exit 1
    }
    
    Test-Npcap
    
    # Detect network settings
    Get-NetworkInterface
    Get-LocalIP
    Get-GatewayMAC
    
    # Get server connection details
    Get-ServerInfo
    
    Write-Host ""
    Write-Info "Starting installation..."
    Write-Host ""
    
    # Install
    New-InstallDirectory
    Get-Paqet
    New-ClientConfig
    New-RunScript
    New-WindowsService
    
    # Done
    Write-CompletionMessage
}

# Run
Main
