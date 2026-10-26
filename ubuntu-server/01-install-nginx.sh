#!/bin/bash
set -e

echo "=== Installing Nginx ==="
sudo apt update
sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl --no-pager status nginx
echo "Nginx installation completed."
