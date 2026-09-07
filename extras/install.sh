#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo."
    exit 1
fi

echo "Installing Omarchy Power Manager backend..."

LIBEXEC_DIR="/usr/local/libexec/omarchy-power-manager"
POLKIT_DIR="/usr/share/polkit-1/actions"
SCRIPT_DIR="$(dirname "$(realpath "$0")")/../scripts"
POLICY_FILE="$(dirname "$(realpath "$0")")/org.omarchy.plugins.power-manager.policy"

# Create directories
mkdir -p "$LIBEXEC_DIR"
mkdir -p "$POLKIT_DIR"

# Install backend scripts
echo "Installing scripts to $LIBEXEC_DIR..."
cp "$SCRIPT_DIR/power-manager-apply" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-manager-profile-switch" "$LIBEXEC_DIR/"
cp "$SCRIPT_DIR/power-manager-limit" "$LIBEXEC_DIR/"

# Ensure strict permissions
chown -R root:root "$LIBEXEC_DIR"
chmod 755 "$LIBEXEC_DIR/power-manager-apply"
chmod 755 "$LIBEXEC_DIR/power-manager-profile-switch"
chmod 755 "$LIBEXEC_DIR/power-manager-limit"

# Install Polkit policy
echo "Installing Polkit policy to $POLKIT_DIR..."
if [ -f "$POLICY_FILE" ]; then
    cp "$POLICY_FILE" "$POLKIT_DIR/"
    chown root:root "$POLKIT_DIR/org.omarchy.plugins.power-manager.policy"
    chmod 644 "$POLKIT_DIR/org.omarchy.plugins.power-manager.policy"
else
    echo "Warning: Polkit policy file not found at $POLICY_FILE"
fi

echo "Backend installation complete!"
