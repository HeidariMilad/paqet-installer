#!/bin/bash
set -e

echo "========================================="
echo "  Paqet Client Container Starting..."
echo "========================================="

# Setup iptables rules for raw socket operation
PAQET_PORT="${PAQET_SERVER_PORT:-9999}"

echo "[INFO] Setting up iptables rules for port $PAQET_PORT..."

# Remove existing rules (ignore errors)
iptables -t raw -D PREROUTING -p tcp --dport "$PAQET_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -D OUTPUT -p tcp --sport "$PAQET_PORT" -j NOTRACK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --sport "$PAQET_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || true

# Add rules
iptables -t raw -A PREROUTING -p tcp --dport "$PAQET_PORT" -j NOTRACK 2>/dev/null || echo "[WARN] Could not set PREROUTING rule (may need privileged mode)"
iptables -t raw -A OUTPUT -p tcp --sport "$PAQET_PORT" -j NOTRACK 2>/dev/null || echo "[WARN] Could not set OUTPUT raw rule"
iptables -t mangle -A OUTPUT -p tcp --sport "$PAQET_PORT" --tcp-flags RST RST -j DROP 2>/dev/null || echo "[WARN] Could not set mangle rule"

echo "[INFO] iptables rules configured"
echo "[INFO] Starting paqet client..."
echo "[INFO] SOCKS5 proxy: 127.0.0.1:1080"
echo ""

# Start paqet
exec /app/paqet run -c /app/config.yaml
