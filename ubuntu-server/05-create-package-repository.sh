#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Configuration
# ============================================
PACKAGE_DIR="/srv/packages"
PACKAGE_OWNER="${SUDO_USER:-$USER}"

# ============================================
# Create writable package repository
# ============================================
sudo mkdir -p "$PACKAGE_DIR"
sudo chown -R "$PACKAGE_OWNER":www-data "$PACKAGE_DIR"
sudo find "$PACKAGE_DIR" -type d -exec chmod 2755 {} +
sudo find "$PACKAGE_DIR" -type f -exec chmod 644 {} +
echo "Repository created: $PACKAGE_DIR (owner: $PACKAGE_OWNER)"
