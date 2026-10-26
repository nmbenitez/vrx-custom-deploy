#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for SCRIPT in 00-preflight.sh 01-install-nginx.sh 02-configure-nginx.sh 03-install-squid.sh 04-configure-squid.sh 05-create-package-repository.sh 06-generate-manifest.sh; do
    echo "=== Running $SCRIPT ==="
    bash "$SCRIPT_DIR/$SCRIPT"
done
IP=$(hostname -I | awk '{print $1}')
echo "Setup completed"
echo "Proxy: $IP:3128"
echo "Repository: http://$IP/packages/"
