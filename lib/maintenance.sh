# lib/maintenance.sh — image builds, software updates, DB tuning, disk cleanup.
#
# Depends on lib/common.sh, lib/services.sh, lib/backup.sh, and the
# manage.sh-level vars: PODMAN_SETUP_DIR, MAIN_DATA_DIR.
#
# Functions:
#   build_site / build_fastfood        – local-image builds for the two web apps
#   update_immich / update_firefly     – release-notes confirmation + backup + pull
#   update_generic <svc>               – pull-and-restart for the simpler images
#   optimize_databases                 – VACUUM ANALYZE + mariadb-check
#   cleanup_all                        – journal / apt / tmp / podman prune

# shellcheck shell=bash

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
    "ntfy")
      backup_ntfy
      pull_img="docker.io/binwiederhier/ntfy:latest"
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
  # Dangling layers > 10 days (orphans from image re-pulls).
  podman image prune -f --filter "until=240h"
  # Tagged-but-unused images > 30 days (e.g. images of disabled services,
  # old aws-cli copies pulled by backups, stale build artifacts).
  podman image prune -a -f --filter "until=720h"
  podman pod prune -f
  podman builder prune -f
  podman system df
  success "Cleanup Finished."
}
