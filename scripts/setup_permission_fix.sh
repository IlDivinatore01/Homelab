#!/bin/bash
# Setup script for passwordless sudo for Podman permission fixes
# This allows the systemd user service to fix permissions without password prompt

echo "Creating sudoers rule for Podman storage ownership fix..."

# Create sudoers drop-in file
sudo tee /etc/sudoers.d/osvaldo-podman-fix << 'EOF'
# Allow osvaldo to fix Podman storage ownership without password
# Required for fix-podman-permissions.service
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/containers
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/libpod
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/podman
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /mnt/HC_Volume_103834258/podman-root
EOF

# Set correct permissions (required for sudoers files)
sudo chmod 440 /etc/sudoers.d/osvaldo-podman-fix

# Validate sudoers syntax
sudo visudo -cf /etc/sudoers.d/osvaldo-podman-fix
if [ $? -eq 0 ]; then
    echo "✅ Sudoers rule created successfully!"
else
    echo "❌ Sudoers syntax error! Removing file..."
    sudo rm /etc/sudoers.d/osvaldo-podman-fix
    exit 1
fi

# Enable the systemd user service
systemctl --user daemon-reload
systemctl --user enable fix-podman-permissions.service
echo "✅ fix-podman-permissions.service enabled!"

# Mask the root podman timer (final prevention)
sudo systemctl mask podman-auto-update.timer
echo "✅ podman-auto-update.timer masked!"

echo ""
echo "=== Setup Complete ==="
echo "The system will now auto-fix Podman permissions on every boot."
