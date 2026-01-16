#!/bin/bash
# ===========================================
# Podman Secrets Creation Script
# ===========================================
# Run this after cloning to create all required secrets

set -e

echo "=== Podman Secrets Setup ==="
echo ""
echo "This script will help you create the required Podman secrets."
echo "You will be prompted to enter each secret value."
echo ""

# Function to create a secret
create_secret() {
    local name="$1"
    local description="$2"
    
    # Check if secret already exists
    if podman secret inspect "$name" &>/dev/null; then
        echo "⚠️  Secret '$name' already exists. Skipping."
        return
    fi
    
    echo ""
    echo "📝 $description"
    echo -n "Enter value for '$name': "
    read -s value
    echo ""
    
    if [ -z "$value" ]; then
        echo "❌ Empty value. Skipping '$name'."
        return
    fi
    
    echo "$value" | podman secret create "$name" -
    echo "✅ Secret '$name' created!"
}

# ===========================================
# FastFood Secrets
# ===========================================
echo ""
echo "=== FastFood App Secrets ==="

create_secret "fastfood-mongo-uri" \
    "MongoDB connection string (mongodb+srv://user:pass@cluster.mongodb.net/fastfood)"

create_secret "fastfood-jwt-secret" \
    "JWT signing key (run: openssl rand -hex 32)"

# ===========================================
# Immich Secrets
# ===========================================
echo ""
echo "=== Immich Secrets ==="

create_secret "immich-db-password" \
    "PostgreSQL password for Immich database"

# ===========================================
# Firefly III Secrets
# ===========================================
echo ""
echo "=== Firefly III Secrets ==="

create_secret "firefly-app-key" \
    "Laravel APP_KEY (run: openssl rand -base64 32)"

create_secret "firefly-db-password" \
    "MariaDB password for Firefly database"

# ===========================================
# Summary
# ===========================================
echo ""
echo "=== Secrets Summary ==="
podman secret ls
echo ""
echo "✅ All secrets created!"
echo ""
echo "Next steps:"
echo "  1. Copy config_examples/*.example to data/*/"
echo "  2. Edit configs with your domain and settings"
echo "  3. Run: systemctl --user daemon-reload"
echo "  4. Run: ./manage_finale.sh to start services"
