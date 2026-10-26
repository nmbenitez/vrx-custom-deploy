#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Configuration
# ============================================
SQUID_CONFIG="/etc/squid/squid.conf"
BACKUP="/etc/squid/squid.conf.vrx-backup"
ALLOWED_SUBNET="192.168.1.0/24"   # Set to your actual Windows client LAN.

# ============================================
# Configure Squid (Internet proxy only)
# ============================================
if [ ! -f "$BACKUP" ]; then
    sudo cp "$SQUID_CONFIG" "$BACKUP"
fi
sudo tee "$SQUID_CONFIG" >/dev/null <<SQUID
http_port 3128
acl localnet src $ALLOWED_SUBNET
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access deny all
access_log /var/log/squid/access.log
SQUID
sudo squid -k parse
sudo systemctl restart squid
IP=$(hostname -I | awk '{print $1}')
echo "Proxy: $IP:3128 (allowed subnet: $ALLOWED_SUBNET)"
