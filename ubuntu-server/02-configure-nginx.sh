#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Configuration
# ============================================
PACKAGE_DIR="/srv/packages"
NGINX_CONFIG="/etc/nginx/sites-available/packages"

# ============================================
# Publish packages using Nginx
# ============================================
echo "=== Configuring Nginx package repository ==="
sudo mkdir -p "$PACKAGE_DIR"
# Package ownership is managed by 05-create-package-repository.sh.
sudo tee "$NGINX_CONFIG" >/dev/null <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    location /packages/ {
        alias /srv/packages/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
    }

    access_log /var/log/nginx/packages_access.log;
    error_log /var/log/nginx/packages_error.log;
}
NGINX

# Keep a backup before replacing the default enabled site.
if [ -e /etc/nginx/sites-enabled/default ] || [ -L /etc/nginx/sites-enabled/default ]; then
    sudo mv /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default.vrx-backup
fi
sudo ln -sfn "$NGINX_CONFIG" /etc/nginx/sites-enabled/packages
sudo nginx -t
sudo systemctl reload nginx
IP=$(hostname -I | awk '{print $1}')
echo "Repository URL: http://$IP/packages/"
echo "Directory listing disabled; package downloads use manifest.txt."
