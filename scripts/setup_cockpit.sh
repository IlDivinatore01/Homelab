#!/bin/bash
set -e

echo "=== COCKPIT INSTALLATION ==="
echo "Installing Cockpit and Podman plugin..."

sudo apt-get update
sudo apt-get install -y cockpit cockpit-podman

echo "Enabling Cockpit..."
sudo systemctl enable --now cockpit.socket

echo -e "\n\033[0;32m[SUCCESS] Cockpit is running on port 9090!\033[0m"
