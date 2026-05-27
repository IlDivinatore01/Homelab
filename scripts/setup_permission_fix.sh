#!/bin/bash
# Setup script for passwordless sudo for Podman permission fixes
# This allows the systemd user service to fix permissions without password prompt

echo "Creating sudoers rule for Podman storage ownership fix..."

# Create sudoers drop-in file
sudo tee /etc/sudoers.d/osvaldo-podman-fix << 'EOF'
# Allow osvaldo to fix Podman runtime-dir ownership without password
# Required for fix-podman-permissions.service.
# NOTE: the podman graphroot (/mnt/.../podman-root) is intentionally NOT here.
# 'chown -R' on the graphroot flattens rootless subuid ownership of image
# layers and breaks non-root-in-container processes (firefly php/nginx EACCES
# crash-loop). Storage ownership is managed by podman's user namespace.
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/containers
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/libpod
osvaldo ALL=(ALL) NOPASSWD: /bin/chown -R osvaldo\:osvaldo /run/user/1000/podman
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

# Create / refresh the systemd user service (idempotent).
# Only fixes the runtime dir (/run/user/1000). It must NEVER chown the podman
# graphroot: 'chown -R' there flattens rootless subuid ownership of image
# layers and breaks non-root-in-container processes (firefly php/nginx EACCES).
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
cat > "$SYSTEMD_USER_DIR/fix-podman-permissions.service" << 'UNIT'
[Unit]
Description=Fix Podman Storage Ownership for Osvaldo
# Must precede services_net-network too: the network create needs
# /run/user/1000/libpod already owned by osvaldo, else its sticky-bit chmod
# fails (EPERM) and services_net-network.service ends up 'failed'.
Before=services_net-network.service homepage.service site.service immich.service firefly.service firefly-importer.service uptime-kuma.service portainer.service fastfood.service it-tools.service caddy.service garage.service ntfy.service
PartOf=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Runtime dir only (RAM). '-' prefix: never fail if a path is absent at boot.
ExecStart=-/usr/bin/sudo /bin/chown -R osvaldo:osvaldo /run/user/1000/containers
ExecStart=-/usr/bin/sudo /bin/chown -R osvaldo:osvaldo /run/user/1000/libpod
ExecStart=-/usr/bin/sudo /bin/chown -R osvaldo:osvaldo /run/user/1000/podman
ExecStart=-/bin/true

[Install]
WantedBy=default.target
UNIT

# Enable the systemd user service
systemctl --user daemon-reload
systemctl --user enable fix-podman-permissions.service
echo "✅ fix-podman-permissions.service installed & enabled!"

# Mask the root podman timer (final prevention)
sudo systemctl mask podman-auto-update.timer
echo "✅ podman-auto-update.timer masked!"

echo ""
echo "=== Setup Complete ==="
echo "The system will now auto-fix Podman permissions on every boot."
