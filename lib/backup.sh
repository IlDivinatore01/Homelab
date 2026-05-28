# lib/backup.sh — backup rotation, off-site sync, and per-service backup ops.
#
# Depends on lib/common.sh (logging, check_dependencies),
# lib/services.sh (ensure_shared_network) and the manage.sh-level vars:
#   PODMAN_SETUP_DIR, BACKUP_BASE_DIR, MAX_BACKUPS_PER_SERVICE,
#   OFFSITE_BACKUP_DIR, OFFSITE_LIMIT, NICE_CMD,
#   USE_S3_BACKUP, S3_* (endpoint/bucket/region/access/secret keys).
#
# Functions:
#   rotate_backups <svc>           – keep the N most recent local dumps
#   sync_to_cloud  <svc> <path>    – background tar.gz + S3 upload (or rsync)
#   backup_immich / _firefly / _uptime_kuma / _portainer / _ntfy / _caddy / _metabase
#   download_from_s3               – interactive picker (option 9 in the menu)

# shellcheck shell=bash

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
  local log_file="/tmp/cloud_sync_${service_name}_$(date +%Y%m%d_%H%M%S).log"

  if [ "$USE_S3_BACKUP" = true ]; then
    # Validate S3 credentials are loaded (from .env)
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
      error "S3 credentials missing. Set GARAGE_S3_ACCESS_KEY/GARAGE_S3_SECRET_KEY in $PODMAN_SETUP_DIR/.env"
      return 1
    fi

    # Use S3 (Garage) for backup
    info "Starting S3 upload to s3://$S3_BUCKET/..."
    info "Progress log: $log_file"

    # Create tar.gz of backup directory for efficient upload
    local backup_name=$(basename "$backup_path")
    local tar_file="/tmp/${backup_name}.tar.gz"

    nohup bash -c "
      echo 'Creating compressed archive...' >> '$log_file'
      $NICE_CMD tar -czf '$tar_file' -C '$(dirname "$backup_path")' '$backup_name' 2>> '$log_file'

      echo 'Uploading to S3...' >> '$log_file'

      # Use ephemeral container for AWS CLI
      podman run --rm --net=host \
        -v '$tar_file':'/backup.tar.gz':ro \
        -e AWS_ACCESS_KEY_ID='$S3_ACCESS_KEY' \
        -e AWS_SECRET_ACCESS_KEY='$S3_SECRET_KEY' \
        docker.io/amazon/aws-cli:latest \
        --region '$S3_REGION' \
        --endpoint-url '$S3_ENDPOINT' s3 cp /backup.tar.gz 's3://$S3_BUCKET/${backup_name}.tar.gz' >> '$log_file' 2>&1

      # Cleanup temp file
      rm -f '$tar_file'

      # List and rotate old backups (keep last $OFFSITE_LIMIT)
      echo 'Checking for old backups to rotate...' >> '$log_file'

      # Get list of old backups
      podman run --rm --net=host \
        -e AWS_ACCESS_KEY_ID='$S3_ACCESS_KEY' \
        -e AWS_SECRET_ACCESS_KEY='$S3_SECRET_KEY' \
        docker.io/amazon/aws-cli:latest \
        --region '$S3_REGION' \
        --endpoint-url '$S3_ENDPOINT' s3 ls 's3://$S3_BUCKET/${service_name}_backup_' 2>/dev/null | \
        sort | head -n -$OFFSITE_LIMIT | awk '{print \$4}' | while read old_backup; do
          echo \"Deleting old backup: \$old_backup\" >> '$log_file'

          podman run --rm --net=host \
            -e AWS_ACCESS_KEY_ID='$S3_ACCESS_KEY' \
            -e AWS_SECRET_ACCESS_KEY='$S3_SECRET_KEY' \
            docker.io/amazon/aws-cli:latest \
            --region '$S3_REGION' \
            --endpoint-url '$S3_ENDPOINT' s3 rm \"s3://$S3_BUCKET/\$old_backup\" >> '$log_file' 2>&1
        done

      echo 'S3 upload complete!' >> '$log_file'
    " &>/dev/null &

    success "S3 upload started in background (PID: $!)"
  else
    # Use old rsync method
    if [ ! -d "$OFFSITE_BACKUP_DIR" ]; then
      mkdir -p "$OFFSITE_BACKUP_DIR" || { warn "Could not create offsite dir $OFFSITE_BACKUP_DIR"; return; }
    fi

    info "Starting background rsync to $OFFSITE_BACKUP_DIR..."
    info "Progress log: $log_file"

    nohup bash -c "
      $NICE_CMD rsync -a --info=progress2 '$backup_path' '$OFFSITE_BACKUP_DIR/' >> '$log_file' 2>&1

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

    success "Rsync started in background (PID: $!)"
  fi
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
  if podman exec -i "$POSTGRES_CONTAINER" pg_dumpall -U "$db_user" | $NICE_CMD gzip > "$backup_dir/database.sql.gz"; then
    success "Database dumped successfully."
  else
    error "Database dump failed."
    return 1
  fi

  # Backup ML cache if it exists (photos are on external storage, not backed up here)
  local IMMICH_ML_CACHE="$PODMAN_SETUP_DIR/data/immich/immich_model_cache"
  if [ -d "$IMMICH_ML_CACHE" ]; then
    info "Backing up ML Model Cache..."
    $NICE_CMD rsync -a --info=progress2 "$IMMICH_ML_CACHE/" "$backup_dir/ml_cache/" && \
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
  if podman exec -i "$DB_CONTAINER" sh -c "mariadb-dump -h 127.0.0.1 -u $db_user -p\$MYSQL_PASSWORD $db_name" | $NICE_CMD gzip > "$backup_dir/firefly_database.sql.gz"; then
    success "Database dumped successfully."
  else
    error "Database dump failed."
    return 1
  fi

  info "Backing up Data Files (excluding db - already dumped via SQL)..."
  $NICE_CMD rsync -a --info=progress2 --exclude='db/' --exclude='storage/oauth-*.key' "$FIREFLY_DATA_DIR/" "$backup_dir/data/" && \
    success "Firefly III backup complete!"

  sync_to_cloud "firefly" "$backup_dir"
}

backup_uptime_kuma() {
  ensure_shared_network
  check_dependencies
  local KUMA_DATA_DIR="$PODMAN_SETUP_DIR/data/uptime-kuma"
  local KUMA_CONTAINER="uptime-kuma-pod-uptime-kuma"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/uptime-kuma_backup_$timestamp"

  title "BACKUP UPTIME KUMA"
  rotate_backups "uptime-kuma"
  mkdir -p "$backup_dir"

  # Atomic SQLite snapshot first (covers WAL too) — safer than copying a
  # live kuma.db, which may be mid-write when rsync hits it.
  if podman container exists "$KUMA_CONTAINER" && \
     [ "$(podman inspect -f '{{.State.Running}}' "$KUMA_CONTAINER")" = "true" ]; then
    info "Taking atomic SQLite snapshot of kuma.db..."
    if podman exec "$KUMA_CONTAINER" sqlite3 /app/data/kuma.db ".backup /app/data/kuma_snapshot.db" 2>/dev/null; then
      success "Snapshot created."
    else
      warn "sqlite3 .backup failed (will rely on raw rsync)."
    fi
  else
    warn "Uptime Kuma container not running — backup will be raw file copy only."
  fi

  info "Backing up Data Files..."
  $NICE_CMD rsync -a --info=progress2 "$KUMA_DATA_DIR/" "$backup_dir/data/" && \
    success "Uptime Kuma backup complete!"

  # Cleanup the in-container snapshot after rsync has copied it out.
  if podman container exists "$KUMA_CONTAINER" && \
     [ "$(podman inspect -f '{{.State.Running}}' "$KUMA_CONTAINER")" = "true" ]; then
    podman exec "$KUMA_CONTAINER" rm -f /app/data/kuma_snapshot.db 2>/dev/null || true
  fi

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
  $NICE_CMD rsync -a --info=progress2 "$PORTAINER_DATA_DIR/" "$backup_dir/data/" && \
    success "Portainer backup complete!"

  sync_to_cloud "portainer" "$backup_dir"
}

backup_ntfy() {
  ensure_shared_network
  check_dependencies
  local NTFY_DATA_DIR="$PODMAN_SETUP_DIR/data/ntfy"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/ntfy_backup_$timestamp"

  title "BACKUP NTFY"
  rotate_backups "ntfy"
  mkdir -p "$backup_dir"
  info "Backing up Data Files..."
  $NICE_CMD rsync -a --info=progress2 "$NTFY_DATA_DIR/" "$backup_dir/data/" && \
    success "ntfy backup complete!"

  sync_to_cloud "ntfy" "$backup_dir"
}

# Backs up Caddy's ACME state (certificates + private keys + accounts) and the
# Caddyfile itself. Small (a few hundred KB) but essential to avoid hitting
# Let's Encrypt rate limits on a full disaster recovery.
backup_caddy() {
  ensure_shared_network
  check_dependencies
  local CADDY_DATA_DIR="$PODMAN_SETUP_DIR/data/caddy"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/caddy_backup_$timestamp"

  title "BACKUP CADDY (ACME certs + Caddyfile)"
  rotate_backups "caddy"
  mkdir -p "$backup_dir"
  info "Backing up Caddyfile and ACME state..."
  $NICE_CMD rsync -a --info=progress2 "$CADDY_DATA_DIR/" "$backup_dir/data/" && \
    success "Caddy backup complete!"

  sync_to_cloud "caddy" "$backup_dir"
}

backup_metabase() {
  ensure_shared_network
  check_dependencies
  local METABASE_DATA_DIR="$PODMAN_SETUP_DIR/data/metabase"
  local timestamp backup_dir
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  backup_dir="$BACKUP_BASE_DIR/metabase_backup_$timestamp"

  title "BACKUP METABASE"
  rotate_backups "metabase"
  mkdir -p "$backup_dir"
  info "Backing up Metabase H2 Database and config..."
  # Metabase uses H2 embedded DB - just copy the data files
  $NICE_CMD rsync -a --info=progress2 "$METABASE_DATA_DIR/" "$backup_dir/data/" && \
    success "Metabase backup complete!"

  sync_to_cloud "metabase" "$backup_dir"
}

download_from_s3() {
  if [ "$USE_S3_BACKUP" != true ]; then
    warn "S3 Backup is not enabled in configuration."
    read -p "Press Enter to continue..."
    return
  fi

  title "DOWNLOAD FROM S3"

  info "Fetching backup list from S3..."

  # Fetch list using podman
  available_backups=$(podman run --rm --net=host \
    -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    docker.io/amazon/aws-cli:latest \
    --region "$S3_REGION" \
    --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/" 2>/dev/null | awk '{print $4}' | sort -r)

  if [ -z "$available_backups" ]; then
    warn "No backups found in S3 bucket."
    read -p "Press Enter to continue..."
    return
  fi

  echo "Available Backups:"
  echo "------------------"
  local i=1
  declare -A backup_map
  while read -r line; do
    if [ -n "$line" ]; then
      echo " $i) $line"
      backup_map[$i]="$line"
      ((i++))
    fi
  done <<< "$available_backups"
  echo " 0) Cancel"
  echo "------------------"

  read -p "Select backup to download: " -r selection

  if [ "$selection" == "0" ] || [ -z "${backup_map[$selection]}" ]; then
    info "Operation cancelled."
    return
  fi

  local target_file="${backup_map[$selection]}"
  local download_path="$BACKUP_BASE_DIR/$target_file"

  info "Downloading $target_file..."

  podman run --rm --net=host \
    -v "$BACKUP_BASE_DIR":/downloads \
    -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    docker.io/amazon/aws-cli:latest \
    --region "$S3_REGION" \
    --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$S3_BUCKET/$target_file" "/downloads/$target_file"

  if [ $? -eq 0 ]; then
    success "Download complete: $download_path"

    read -p "Do you want to extract it now? (y/N): " -r extract_reply
    if [[ "$extract_reply" =~ ^[Yy]$ ]]; then
      info "Extracting..."
      tar -xzf "$download_path" -C "$BACKUP_BASE_DIR"
      success "Extracted to $BACKUP_BASE_DIR"

      # Optional: remove tar.gz after extraction
      read -p "Remove archive file? (y/N): " -r remove_reply
      if [[ "$remove_reply" =~ ^[Yy]$ ]]; then
        rm -f "$download_path"
        success "Archive removed."
      fi
    fi
  else
    error "Download failed."
  fi

  read -p "Press Enter to continue..."
}
