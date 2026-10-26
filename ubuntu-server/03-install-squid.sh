#!/bin/bash
set -e

echo "=== Installing Squid ==="
sudo apt update
sudo apt install -y squid
sudo systemctl enable squid
sudo systemctl start squid
sudo systemctl --no-pager status squid
