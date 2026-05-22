#!/bin/bash
# ===========================================
# Podman Secrets Creation Script
# ===========================================
# Idempotent: existing secrets are NOT overwritten.
# Creates two kinds of secrets:
#   1) Podman file-based secrets    (used directly by --secret in some pods)
#   2) Kubernetes Secret YAMLs      (used by secretKeyRef in *.pod.yaml)
#
# Run after `git clone` to provision all required secrets.

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
K8S_SECRETS_DIR="$SCRIPT_DIR/podman_secrets"
mkdir -p "$K8S_SECRETS_DIR"

echo "=== Podman Secrets Setup ==="
echo ""
echo "Existing secrets:"
podman secret ls --format "  - {{.Name}}" 2>/dev/null || true
echo ""

# --- Helpers ---

# Create a Podman file-based secret if it does not already exist.
create_podman_secret() {
    local name="$1"
    local description="$2"
    local default_value="${3:-}"   # if non-empty, will be used as the value (no prompt)

    if podman secret inspect "$name" &>/dev/null; then
        echo "[skip] '$name' already exists."
        return
    fi

    local value
    if [ -n "$default_value" ]; then
        value="$default_value"
        echo "[auto] Generated value for '$name'"
    else
        echo ""
        echo "[prompt] $description"
        read -rsp "Enter value for '$name': " value
        echo ""
        if [ -z "$value" ]; then
            echo "[skip] empty value — '$name' not created."
            return
        fi
    fi

    printf '%s' "$value" | podman secret create "$name" -
    echo "[ok]   '$name' created."
}

# Create a Kubernetes Secret YAML + apply it via 'podman kube play'.
# Args: <secret-name> <yaml-filename> <key> <value> [description]
create_k8s_secret() {
    local name="$1"
    local file="$K8S_SECRETS_DIR/$2"
    local key="$3"
    local value="$4"

    if podman secret inspect "$name" &>/dev/null; then
        echo "[skip] '$name' already exists."
        return
    fi

    cat > "$file" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $name
type: Opaque
stringData:
  $key: "$value"
EOF
    chmod 600 "$file"
    podman kube play "$file" >/dev/null
    echo "[ok]   '$name' created (key: $key)."
}

# Prompt for a value, returning the entered string (or default if blank).
prompt_value() {
    local description="$1"
    local default="${2:-}"
    local value
    echo ""
    echo "[prompt] $description"
    if [ -n "$default" ]; then
        read -rp "  (press Enter for default: $default): " value
        echo "${value:-$default}"
    else
        read -rsp "  Value: " value
        echo ""
        echo "$value"
    fi
}

# --- 1. Immich (Postgres) ---
echo ""
echo "=== Immich ==="
create_k8s_secret immich-db-user-k8s     db_user.secret.yaml      username "postgres"
create_k8s_secret immich-db-name-k8s     db_name.secret.yaml      dbname   "immich"
if ! podman secret inspect immich-db-password-k8s &>/dev/null; then
    pw="$(prompt_value 'Immich DB password (Postgres)')"
    [ -n "$pw" ] && create_k8s_secret immich-db-password-k8s db_password.secret.yaml password "$pw"
else
    echo "[skip] 'immich-db-password-k8s' already exists."
fi

# --- 2. Firefly III (MariaDB) ---
echo ""
echo "=== Firefly III ==="
create_k8s_secret firefly-db-user-k8s    firefly_db_user.secret.yaml     username "firefly"
create_k8s_secret firefly-db-name-k8s    firefly_db_name.secret.yaml     dbname   "firefly"

if ! podman secret inspect firefly-db-password-k8s &>/dev/null; then
    pw_auto="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    echo "[auto] Generated Firefly DB password"
    create_k8s_secret firefly-db-password-k8s firefly_db_password.secret.yaml password "$pw_auto"
else
    echo "[skip] 'firefly-db-password-k8s' already exists."
fi

if ! podman secret inspect firefly-app-key-k8s &>/dev/null; then
    appkey="base64:$(openssl rand -base64 32)"
    echo "[auto] Generated Firefly APP_KEY"
    create_k8s_secret firefly-app-key-k8s firefly_app_key.secret.yaml appkey "$appkey"
else
    echo "[skip] 'firefly-app-key-k8s' already exists."
fi

if ! podman secret inspect firefly-cron-token-k8s &>/dev/null; then
    tok="$(openssl rand -hex 16)"
    echo "[auto] Generated Firefly cron token"
    create_k8s_secret firefly-cron-token-k8s firefly_cron_token.secret.yaml crontoken "$tok"
else
    echo "[skip] 'firefly-cron-token-k8s' already exists."
fi

if ! podman secret inspect firefly-importer-token-k8s &>/dev/null; then
    tok="$(openssl rand -hex 20)"
    echo "[auto] Generated Firefly importer access token (set this in Firefly UI later)"
    create_k8s_secret firefly-importer-token-k8s firefly_importer_token.secret.yaml accesstoken "$tok"
else
    echo "[skip] 'firefly-importer-token-k8s' already exists."
fi

# --- 3. FastFood ---
echo ""
echo "=== FastFood ==="
if ! podman secret inspect fastfood-mongo-uri &>/dev/null; then
    uri="$(prompt_value 'MongoDB connection string (mongodb+srv://user:pass@cluster/fastfood)')"
    [ -n "$uri" ] && create_k8s_secret fastfood-mongo-uri fastfood_mongo_uri.secret.yaml uri "$uri"
else
    echo "[skip] 'fastfood-mongo-uri' already exists."
fi

if ! podman secret inspect fastfood-jwt-secret &>/dev/null; then
    jwt="$(openssl rand -base64 32)"
    echo "[auto] Generated FastFood JWT secret"
    create_k8s_secret fastfood-jwt-secret fastfood_jwt_secret.secret.yaml secret "$jwt"
else
    echo "[skip] 'fastfood-jwt-secret' already exists."
fi

# --- 4. Homepage (Immich widget API key) ---
echo ""
echo "=== Homepage ==="
echo "(skip if you don't have an Immich API key yet — create it later)"
if ! podman secret inspect homepage-immich-key-k8s &>/dev/null; then
    apikey="$(prompt_value 'Immich API key (from Immich UI > User Settings > API Keys)')"
    if [ -n "$apikey" ]; then
        create_k8s_secret homepage-immich-key-k8s homepage_immich_key.secret.yaml apikey "$apikey"
    fi
else
    echo "[skip] 'homepage-immich-key-k8s' already exists."
fi

# --- Summary ---
echo ""
echo "=== Final secret inventory ==="
podman secret ls
echo ""
echo "Done. Next steps:"
echo "  1) cp .env.example .env && chmod 600 .env  (fill Garage S3 creds — see SETUP.md §3.2)"
echo "  2) cp config_examples/Caddyfile.example data/caddy/Caddyfile"
echo "  3) ./manage_finale.sh  (option 11 to verify quadlets, then option 1 to start)"
