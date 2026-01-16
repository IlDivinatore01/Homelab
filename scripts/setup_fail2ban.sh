#!/bin/bash
set -e

echo "=== FAIL2BAN SECURITY SETUP ==="
echo "This script requires sudo privileges to secure your SSH."

# 1. Install/Verify (Just in case)
if ! command -v fail2ban-client &> /dev/null; then
  echo "Fail2Ban not found. Installing..."
  sudo apt-get update && sudo apt-get install -y fail2ban
fi

# 2. Configure
echo "Configuring Jail..."
if [ ! -f /etc/fail2ban/jail.local ]; then
  sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Create custom SSH hardening config
echo "Hardening SSH settings..."
sudo bash -c 'cat > /etc/fail2ban/jail.d/ssh-hardening.conf <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600
EOF'

# 3. Enable & Start
echo "Enabling Service..."
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

echo "Waiting for startup..."
sleep 5

echo "Checking Status..."
sudo fail2ban-client status sshd

echo -e "\n\033[0;32m[SUCCESS] SSH is now protected by Fail2Ban!\033[0m"
