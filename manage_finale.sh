#!/bin/bash
set -euo pipefail

# =============================================================================
# PODMAN SERVICE MANAGER - SYSTEMD QUADLET EDITION v2.7 (Jan 2026)
# - Rootless only (no sudo)
# - Guard: fixes runroot overlay becoming root-owned (prevents EPERM chown)
# - Guard: ensures shared network 'services_net' exists (quadlet service if present, else podman)
# - Bulk restart continues and reports failures
# =============================================================================

# --- CONFIGURATION ---
PODMAN_SETUP_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MAIN_DATA_DIR="$PODMAN_SETUP_DIR/data/site"
BACKUP_BASE_DIR="$PODMAN_SETUP_DIR/backups"

SHARED_NETWORK_NAME="services_net"
SHARED_NETWORK_UNIT="${SHARED_NETWORK_NAME}-network.service"

CONTINUE_ON_RESTART_ERROR=true
MAX_BACKUPS_PER_SERVICE=1
OFFSITE_BACKUP_DIR="/mnt/immich_storage/Full_VPS_Backups"
OFFSITE_LIMIT=5

declare -A PODS=(
  [homepage]="$PODMAN_SETUP_DIR/kube_yaml/homepage.pod.yaml"
  [site]="$PODMAN_SETUP_DIR/kube_yaml/site.pod.yaml"
  [immich]="$PODMAN_SETUP_DIR/kube_yaml/immich.pod.yaml"
  [firefly]="$PODMAN_SETUP_DIR/kube_yaml/firefly.pod.yaml"
  [firefly-importer]="$PODMAN_SETUP_DIR/kube_yaml/firefly-importer.pod.yaml"
  [uptime-kuma]="$PODMAN_SETUP_DIR/kube_yaml/uptime-kuma.pod.yaml"
  [portainer]="$PODMAN_SETUP_DIR/kube_yaml/portainer.pod.yaml"
  [it-tools]="$PODMAN_SETUP_DIR/kube_yaml/it-tools.pod.yaml"


  [fastfood]="$PODMAN_SETUP_DIR/kube_yaml/fastfood.pod.yaml"
)
SERVICES=(homepage site immich firefly firefly-importer uptime-kuma portainer fastfood it-tools)

# --- LOGGING UTILS ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
info()    { echo -e "${C_CYAN}[INFO] $1${C_RESET}"; }
warn()    { echo -e "${C_YELLOW}[WARN] $1${C_RESET}"; }
error()   { echo -e "${C_RED}[ERROR] $1${C_RESET}" >&2; }
success() { echo -e "${C_GREEN}[SUCCESS] $1${C_RESET}"; }
title()   { echo -e "\n${C_BLUE}=== $1 ===${C_RESET}"; }

check_dependencies() {
  for cmd in rsync podman systemctl gzip find sort stat id; do
    if ! command -v "$cmd" &>/dev/null; then
      error "'$cmd' is not installed. Please install it."
      exit 1
    fi
  done
}

ensure_not_root() {
  if [ "$(id -u)" -eq 0 ]; then
    error "Do NOT run this script as root/sudo. Run it as your rootless user."
    exit 1
  fi
}

# Prevent: /run/user/$UID/containers/overlay owned by root => podman chown fails.
ensure_runroot_ok() {
  ensure_not_root
  local uid user rr
  uid="$(id -u)"
  user="$(id -un)"
  rr="/run/user/${uid}/containers"

  mkdir -p "$rr"
  chmod 700 "$rr" || true

  if [ -d "$rr/overlay" ]; then
    local owner
    owner="$(stat -c '%U:%G' "$rr/overlay" 2>/dev/null || echo "unknown:unknown")"
    if [[ "$owner" != "${user}:"* ]]; then
      warn "runroot overlay ownership is '$owner' (expected ${user}:*). Resetting $rr ..."
      rm -rf "$rr"
      mkdir -p "$rr"
      chmod 700 "$rr"
    fi
  fi
}

# Ensure services_net exists.
# Prefer starting quadlet-generated services_net-network.service if present, else fallback to podman network create.
ensure_shared_network() {
  ensure_runroot_ok

  # If the quadlet network unit exists (generated), start it (oneshot, RemainAfterExit).
  if systemctl --user list-unit-files --no-pager 2>/dev/null | grep -q "^${SHARED_NETWORK_UNIT}"; then
    systemctl --user start "${SHARED_NETWORK_UNIT}" || true
  fi

  # Hard guarantee: the network must exist for kube units using --network=services_net.
  if podman network exists "$SHARED_NETWORK_NAME"; then
    return 0
  fi

  warn "Podman network '$SHARED_NETWORK_NAME' missing. Creating..."
  podman network create "$SHARED_NETWORK_NAME" >/dev/null
  success "Network '$SHARED_NETWORK_NAME' created."
}

restart_service() {
  ensure_shared_network
  local service_name="$1"
  info "Restarting Systemd Service: $service_name..."
  systemctl --user daemon-reload
  if systemctl --user restart "$service_name.service"; then
    success "Service '$service_name' restarted successfully."
  else
    error "Failed to restart '$service_name'."
    error "Hint: systemctl --user status $service_name.service --no-pager -l"
    error "Hint: journalctl --user -u $service_name.service -b --no-pager -n 200"
    return 1
  fi
}

stop_service() {
  ensure_runroot_ok
  local service_name="$1"
  info "Stopping Systemd Service: $service_name..."
  if systemctl --user stop "$service_name.service"; then
    success "Service '$service_name' stopped."
  else
    error "Failed to stop '$service_name'."
    return 1
  fi
}

deploy_pod() {
  ensure_shared_network
  local pod_yaml_file="$1"
  local service_name
  service_name="$(basename "$pod_yaml_file" .pod.yaml)"

  if [ ! -f "$pod_yaml_file" ]; then
    error "YAML file not found: $pod_yaml_file"
    return 1
  fi

  restart_service "$service_name"
}

restart_caddy() {
  title "RESTART CADDY"
  restart_service "caddy"
}

bootstrap_quadlets() {
  local systemd_dir="$HOME/.config/containers/systemd"
  mkdir -p "$systemd_dir"

  # Create Network Quadlet if missing
  if [ ! -f "$systemd_dir/services_net.network" ]; then
    info "Bootstrapping services_net.network..."
    cat > "$systemd_dir/services_net.network" <<EOF
[Network]
NetworkName=services_net
EOF
  fi

  # Create Service Quadlets
  for svc in "${!PODS[@]}"; do
    local kube_file="$systemd_dir/$svc.kube"
    local yaml_path="${PODS[$svc]}"
    
    if [ ! -f "$kube_file" ]; then
      info "Bootstrapping $svc.kube..."
      cat > "$kube_file" <<EOF
[Unit]
Description=Auto-start for ${svc^} Pod
Wants=network-online.target
After=network-online.target

[Kube]
Yaml=$yaml_path
Network=services_net

[Install]
WantedBy=default.target
EOF
    fi
  done
  
  # Reload systemd to pick up new files
  systemctl --user daemon-reload
}

verify_quadlets() {
  title "VERIFYING & BOOTSTRAPPING QUADLET FILES"
  bootstrap_quadlets
  ensure_shared_network
  if /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun; then
    success "Quadlet files are valid syntax."
  else
    error "Quadlet syntax error detected!"
    return 1
  fi
}

# --- BACKUP SYSTEM ---
rotate_backups() {
  local service_name="$1"
  local backup_pattern="${service_name}_backup_"

  local backup_count
  backup_count="$(find "$BACKUP_BASE_DIR" -maxdepth 1 -name "${backup_pattern}*" -type d | wc -l)"

  if [ "$backup_count" -ge "$MAX_BACKUPS_PER_SERVICE" ]; then
    info "Rotating backups for $service_name (Found: $backup_count, Keep: $MAX_BACKUPS_PER_SERVICE)..."
    find "$BACKUP_BASE_DIR" -maxdepth 1 -name "${backup_pattern}*" -type d -printf '%T@ %p\n' | \
      sort -n | \
      head -n -"$MAX_BACKUPS_PER_SERVICE" | \
      cut -d' ' -f2- | \
      xargs -r rm -rf
    success "Old backups removed."
  fi
}



sync_to_cloud() {
  local service_name="$1"
  local backup_path="$2"

  if [ ! -d "$OFFSITE_BACKUP_DIR" ]; then
    mkdir -p "$OFFSITE_BACKUP_DIR" || { warn "Could not create offsite dir $OFFSITE_BACKUP_DIR"; return; }
  fi

  local log_file="/tmp/cloud_sync_${service_name}_$(date +%Y%m%d_%H%M%S).log"
  info "Starting background cloud sync to $OFFSITE_BACKUP_DIR..."
  info "Progress log: $log_file"
  
  # Run rsync in background with nohup
  nohup bash -c "
    rsync -a --info=progress2 '$backup_path' '$OFFSITE_BACKUP_DIR/' >> '$log_file' 2>&1
    
    # Rotate old offsite backups after sync completes
    backup_pattern='${service_name}_backup_'
    count=\$(find '$OFFSITE_BACKUP_DIR' -maxdepth 1 -name \"\${backup_pattern}*\" -type d | wc -l)
    if [ \"\$count\" -gt $OFFSITE_LIMIT ]; then
      echo 'Rotating old offsite backups...' >> '$log_file'
      find '$OFFSITE_BACKUP_DIR' -maxdepth 1 -name \"\${backup_pattern}*\" -type d -printf '%T@ %p\n' | \
        sort -n | head -n -$OFFSITE_LIMIT | cut -d' ' -f2- | xargs -r rm -rf
    fi
    echo 'Cloud sync complete!' >> '$log_file'
  " &>/dev/null &
  
  success "Cloud sync started in background (PID: $!)"
}

backup_immich() {
  ensure_shared_network
  check_dependencies
  local IMMICH_DATA_DIR="$PODMAN_SETUP_DIR/data/immich"
  local POSTGRES_CONTAINER="immich-server-immich-postgres"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/immich_backup_$timestamp"

  title "BACKUP IMMICH"
  rotate_backups "immich"
  mkdir -p "$backup_dir"

  if ! podman container exists "$POSTGRES_CONTAINER"; then
    error "Immich Postgres container '$POSTGRES_CONTAINER' does NOT exist."
    return 1
  fi

  local running
  running="$(podman inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "false")"
  if [[ "$running" != "true" ]]; then
    warn "Immich Postgres is not running. Starting immich.service..."
    systemctl --user start immich.service || true
    sleep 2
  fi

  running="$(podman inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "false")"
  if [[ "$running" != "true" ]]; then
    error "Immich Postgres container exists but is not running."
    return 1
  fi

  local db_user
  db_user="$(podman exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER 2>/dev/null | tr -d '\r' || true)"
  db_user="${db_user:-postgres}"

  local retry=0 db_ready=false
  while [ $retry -lt 15 ]; do
    if podman exec "$POSTGRES_CONTAINER" pg_isready -U "$db_user" &>/dev/null; then
      db_ready=true
      break
    fi
    sleep 2
    retry=$((retry + 1))
  done

  if [ "$db_ready" = false ]; then
    error "Database is running but not accepting connections yet (pg_isready failed)."
    return 1
  fi

  info "Dumping Database (Compressed)..."
  if podman exec -i "$POSTGRES_CONTAINER" pg_dumpall -U "$db_user" | gzip > "$backup_dir/database.sql.gz"; then
    success "Database dumped successfully."
  else
    error "Database dump failed."
    return 1
  fi

  # Backup ML cache if it exists (photos are on external storage, not backed up here)
  local IMMICH_ML_CACHE="$PODMAN_SETUP_DIR/data/immich/immich_model_cache"
  if [ -d "$IMMICH_ML_CACHE" ]; then
    info "Backing up ML Model Cache..."
    rsync -a --info=progress2 "$IMMICH_ML_CACHE/" "$backup_dir/ml_cache/" && \
      success "ML cache backed up."
  else
    info "Skipping ML cache backup (directory doesn't exist)."
  fi
  
  success "Immich backup complete! (DB dump saved, photos on external storage)"
    
  sync_to_cloud "immich" "$backup_dir"
}

backup_firefly() {
  ensure_shared_network
  check_dependencies
  local FIREFLY_DATA_DIR="$PODMAN_SETUP_DIR/data/firefly"
  local DB_CONTAINER="firefly-pod-firefly-db"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/firefly_backup_$timestamp"

  title "BACKUP FIREFLY III"
  rotate_backups "firefly"
  mkdir -p "$backup_dir"

  info "Checking Database readiness..."
  local retry=0 db_ready=false
  while [ $retry -lt 10 ]; do
    if podman exec "$DB_CONTAINER" sh -c 'mariadb -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1"' &>/dev/null; then
      db_ready=true
      break
    fi
    sleep 2; retry=$((retry + 1))
  done

  if [ "$db_ready" = false ]; then
    error "Firefly Database is not responding. Is the pod running?"
    return 1
  fi

  local db_user db_name
  db_user="$(podman exec "$DB_CONTAINER" printenv MYSQL_USER | tr -d '\r')"
  db_name="$(podman exec "$DB_CONTAINER" printenv MYSQL_DATABASE | tr -d '\r')"

  info "Dumping Database (Compressed)..."
  if podman exec -i "$DB_CONTAINER" sh -c "mariadb-dump -h 127.0.0.1 -u $db_user -p\$MYSQL_PASSWORD $db_name" | gzip > "$backup_dir/firefly_database.sql.gz"; then
    success "Database dumped successfully."
  else
    error "Database dump failed."
    return 1
  fi

  info "Backing up Data Files (excluding db - already dumped via SQL)..."
  rsync -a --info=progress2 --exclude='db/' --exclude='storage/oauth-*.key' "$FIREFLY_DATA_DIR/" "$backup_dir/data/" && \
    success "Firefly III backup complete!"
    
  sync_to_cloud "firefly" "$backup_dir"
}

backup_uptime_kuma() {
  ensure_shared_network
  check_dependencies
  local KUMA_DATA_DIR="$PODMAN_SETUP_DIR/data/uptime-kuma"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/uptime-kuma_backup_$timestamp"

  title "BACKUP UPTIME KUMA"
  rotate_backups "uptime-kuma"
  mkdir -p "$backup_dir"
  info "Backing up Data Files..."
  rsync -a --info=progress2 "$KUMA_DATA_DIR/" "$backup_dir/data/" && \
    success "Uptime Kuma backup complete!"
    
  sync_to_cloud "uptime-kuma" "$backup_dir"
}

backup_portainer() {
  ensure_shared_network
  check_dependencies
  local PORTAINER_DATA_DIR="$PODMAN_SETUP_DIR/data/portainer"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/portainer_backup_$timestamp"

  title "BACKUP PORTAINER"
  rotate_backups "portainer"
  mkdir -p "$backup_dir"
  info "Backing up Data Files..."
  rsync -a --info=progress2 "$PORTAINER_DATA_DIR/" "$backup_dir/data/" && \
    success "Portainer backup complete!"
    
  sync_to_cloud "portainer" "$backup_dir"
}

# --- BUILD & UPDATES ---
build_site() {
  ensure_shared_network
  local SIMO_WEBSITE_DIR="$PODMAN_SETUP_DIR/site_sources"
  title "BUILDING WEBSITE"
  if [ ! -d "$SIMO_WEBSITE_DIR" ]; then
    error "Source directory missing: $SIMO_WEBSITE_DIR"
    return 1
  fi

  pushd "$SIMO_WEBSITE_DIR" >/dev/null
  info "Building Backend & Frontend Containers..."
  podman build -t localhost/main-backend:1.0.0 -f backend/Containerfile ./backend
  podman build -t localhost/main-frontend:1.0.0 -f frontend/Containerfile ./frontend

  info "Extracting Frontend Artifacts..."
  rm -rf "$MAIN_DATA_DIR/frontend_dist/"*
  mkdir -p "$MAIN_DATA_DIR/frontend_dist/"
  podman run --rm -v "$MAIN_DATA_DIR/frontend_dist:/output:Z" localhost/main-frontend:1.0.0 sh -c "cp -a /app/dist/. /output/"
  success "Build complete!"
  popd >/dev/null
}

build_fastfood() {
  ensure_shared_network
  local FASTFOOD_DIR="$PODMAN_SETUP_DIR/FastFood"
  local FASTFOOD_DATA_DIR="$PODMAN_SETUP_DIR/data/fastfood"
  title "BUILDING FASTFOOD"
  if [ ! -d "$FASTFOOD_DIR" ]; then
    error "FastFood source directory missing: $FASTFOOD_DIR"
    return 1
  fi

  pushd "$FASTFOOD_DIR" >/dev/null
  info "Building FastFood Backend Container..."
  podman build -t localhost/fastfood-backend:1.0.0 -f backend/Containerfile .

  info "Copying Frontend Assets..."
  mkdir -p "$FASTFOOD_DATA_DIR/frontend_dist" "$FASTFOOD_DATA_DIR/caddy_config" "$FASTFOOD_DATA_DIR/mongo_data"
  rm -rf "$FASTFOOD_DATA_DIR/frontend_dist/"*
  cp -r frontend/public/* "$FASTFOOD_DATA_DIR/frontend_dist/"
  cp -r frontend/css "$FASTFOOD_DATA_DIR/frontend_dist/"
  cp -r frontend/js "$FASTFOOD_DATA_DIR/frontend_dist/"
  cp -r frontend/html/* "$FASTFOOD_DATA_DIR/frontend_dist/" 2>/dev/null || true

  # Create Caddyfile if it doesn't exist
  if [ ! -f "$FASTFOOD_DATA_DIR/caddy_config/Caddyfile" ]; then
    info "Creating Caddyfile for Caddy sidecar..."
    cat > "$FASTFOOD_DATA_DIR/caddy_config/Caddyfile" <<'EOF'
:5000 {
    root * /usr/share/caddy
    encode zstd gzip
    handle /css/* { file_server }
    handle /js/* { file_server }
    handle /images/* { file_server }
    handle /bootstrap/* { file_server }
    handle { reverse_proxy localhost:3000 }
    log { output stdout; format console }
}
EOF
  fi

  success "FastFood build complete!"
  popd >/dev/null
}

update_immich() {
  ensure_shared_network
  warn "Starting Immich Update Process..."
  read -p "Have you read the release notes? (y/N): " -r
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then return 0; fi
  if ! backup_immich; then error "Backup failed. Aborting update."; return 1; fi

  info "Pulling new images..."
  if podman pull ghcr.io/immich-app/immich-server:release && \
     podman pull ghcr.io/immich-app/immich-machine-learning:release; then
    restart_service "immich"
  else
    error "Image pull failed. Skipping restart."
    return 1
  fi
}

update_firefly() {
  ensure_shared_network
  warn "Starting Firefly III Update Process..."
  read -p "Have you read the release notes? (y/N): " -r
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then return 0; fi
  if ! backup_firefly; then error "Backup failed. Aborting update."; return 1; fi

  info "Pulling new images..."
  if podman pull docker.io/fireflyiii/core:latest && \
     podman pull docker.io/fireflyiii/data-importer:latest; then
    restart_service "firefly"
    restart_service "firefly-importer"
  else
    error "Image pull failed. Skipping restart."
    return 1
  fi
}

update_generic() {
  ensure_shared_network
  local service="$1"
  info "Updating $service..."
  local pull_img=""

  case "$service" in
    "homepage")    pull_img="ghcr.io/gethomepage/homepage:latest" ;;
    "portainer")
      backup_portainer
      pull_img="docker.io/portainer/portainer-ce:lts"
      ;;
    "it-tools") pull_img="docker.io/corentinth/it-tools:latest" ;;
    "uptime-kuma")
      backup_uptime_kuma
      pull_img="docker.io/louislam/uptime-kuma:beta"
      ;;

    *)
      warn "No automatic pull defined for '$service'. Just restarting."
      restart_service "$service"
      return 0
      ;;
  esac

  if podman pull "$pull_img"; then
    restart_service "$service"
  else
    error "Failed to pull image for $service. Service was NOT restarted."
    return 1
  fi
}

# --- CLEANUP ---
optimize_databases() {
  ensure_shared_network
  title "DATABASE MAINTENANCE"

  # IMMICH (Postgres)
  local IMMICH_CONT="immich-server-immich-postgres"
  if podman container exists "$IMMICH_CONT" && [ "$(podman container inspect -f '{{.State.Running}}' "$IMMICH_CONT")" == "true" ]; then
    info "Optimizing Immich Database (VACUUM ANALYZE)..."
    local db_user
    db_user="$(podman exec "$IMMICH_CONT" printenv POSTGRES_USER | tr -d '\r')"
    podman exec "$IMMICH_CONT" psql -U "$db_user" -c "VACUUM ANALYZE;" immich
    success "Immich Done."
  else
    warn "Immich Database not running, skipping."
  fi

  # FIREFLY (MariaDB)
  local FIREFLY_CONT="firefly-pod-firefly-db"
  if podman container exists "$FIREFLY_CONT" && [ "$(podman container inspect -f '{{.State.Running}}' "$FIREFLY_CONT")" == "true" ]; then
    info "Optimizing Firefly Database (mariadb-check)..."
    local db_user db_pass
    db_user="$(podman exec "$FIREFLY_CONT" printenv MYSQL_USER | tr -d '\r')"
    podman exec "$FIREFLY_CONT" sh -c 'mariadb-check -h 127.0.0.1 -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --optimize --databases "$MYSQL_DATABASE"'
    success "Firefly Done."
  else
    warn "Firefly Database not running, skipping."
  fi
}

cleanup_all() {
  ensure_shared_network
  title "SYSTEM CLEANUP"
  info "Cleaning Journal Logs..."
  sudo journalctl --vacuum-size=200M --vacuum-time=7d
  info "Cleaning APT Cache..."
  sudo apt-get clean && sudo apt-get autoremove -y
  info "Cleaning Temp Files..."
  sudo find /tmp -type f -mtime +1 -delete
  info "Cleaning Podman (Containers, Images, Pods, Build Cache)..."
  podman system df
  podman container prune -f --filter "until=24h"
  podman image prune -f --filter "until=240h"
  podman pod prune -f
  podman builder prune -f
  success "Cleanup Finished."
}

# --- MENUS ---
select_services() {
  local prompt="$1"
  local -n _selected=$2
  echo "$prompt"
  local i=1
  for svc in "${SERVICES[@]}"; do echo "  $i) $svc"; ((i++)); done
  echo "  a) all"
  read -p "Enter number(s) or 'a': " choices
  if [[ "$choices" == "a" ]]; then
    _selected=("${SERVICES[@]}")
  else
    IFS=',' read -ra idxs <<< "$choices"
    for idx in "${idxs[@]}"; do
      idx="$(echo "$idx" | xargs)"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#SERVICES[@]} )); then
        _selected+=("${SERVICES[$((idx-1))]}")
      fi
    done
  fi
}

main_menu() {
  while true; do
    echo ""; title "PODMAN SERVICE MANAGER (Quadlet Edition v2.7)"; echo ""
    echo " 1) Start/Restart Services"
    echo " 2) Update Services (with Pull & Backup)"
    echo " 3) Stop Services"
    echo "----------------------------"
    echo " 4) Backup Immich"
    echo " 5) Backup Firefly III"
    echo " 6) Backup System Tools (Kuma/Portainer)"

    echo " 7) List Backups"
    echo "----------------------------"
    echo " 8) Full System Cleanup"
    echo " 9) Setup & Verify Quadlet Config"
    echo " 10) Restart Caddy Proxy"
    echo " 11) Optimize Databases"
    echo " 0) Exit"
    echo ""
    read -p "Select Option: " opt

    case "$opt" in
      1)
        local selected=()
        select_services "Select services to start/restart:" selected

        if [[ " ${selected[*]} " =~ " site " ]]; then
          build_site
        fi

        if [[ " ${selected[*]} " =~ " fastfood " ]]; then
          build_fastfood
        fi

        local failed=()
        for svc in "${selected[@]}"; do
          if ! deploy_pod "${PODS[$svc]}"; then
            failed+=("$svc")
            if [ "$CONTINUE_ON_RESTART_ERROR" = false ]; then
              error "Stopping due to failure (CONTINUE_ON_RESTART_ERROR=false)."
              return 1
            fi
          fi
        done

        if [ "${#failed[@]}" -gt 0 ]; then
          warn "Some services failed: ${failed[*]}"
          warn "Check with: systemctl --user status <name>.service --no-pager -l"
        fi
        ;;
      2)
        local selected=()
        select_services "Select services to update:" selected

        local firefly_update=false
        for svc in "${selected[@]}"; do [[ "$svc" =~ firefly ]] && firefly_update=true && break; done
        if [ "$firefly_update" = true ]; then update_firefly; fi

        for svc in "${selected[@]}"; do
          case "$svc" in
            immich) update_immich ;;
            firefly|firefly-importer) continue ;;
            site) build_site; restart_service "site" ;;
            *) update_generic "$svc" ;;
          esac
        done
        ;;
      3)
        local selected=()
        select_services "Select services to stop:" selected
        for svc in "${selected[@]}"; do stop_service "$svc"; done
        ;;
      4) backup_immich ;;
      5) backup_firefly ;;
      6) backup_uptime_kuma; backup_portainer ;;

      7) echo ""; ls -lht "$BACKUP_BASE_DIR"/ | head -20 ;;
      8) cleanup_all ;;
      9) verify_quadlets ;;
      10) restart_caddy ;;
      11) optimize_databases ;;
      0) exit 0 ;;
      *) error "Invalid option." ;;
    esac
  done
}

# --- ENTRY POINT ---
check_dependencies
ensure_not_root
ensure_runroot_ok
ensure_shared_network
main_menu
