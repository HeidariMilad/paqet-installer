#!/bin/bash
#===============================================================================
# PAQET SERVER INSTALLER (Redirect)
# Redirects to server/install.sh for backward compatibility.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/server/install.sh" ]]; then
    exec bash "$SCRIPT_DIR/server/install.sh" "$@"
else
    echo "Downloading server installer..."
    curl -sL https://raw.githubusercontent.com/HeidariMilad/paqet-installer/main/server/install.sh | sudo bash -s -- "$@"
fi
