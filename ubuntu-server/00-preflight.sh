#!/bin/bash
set -e

echo "=== Ubuntu Server Preflight ==="
sudo apt update
sudo apt --fix-broken install -y
sudo dpkg --configure -a
sudo apt check
echo "Preflight completed successfully."
