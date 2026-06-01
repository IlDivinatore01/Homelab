#!/bin/bash
# Restore Wizard for Podman backups.
# Locates backups (local / cloud mirror / Garage S3), validates integrity,
# and either prints the manual restore steps or performs the file-level restore.

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
LOCAL_BACKUPS="$SCRIPT_DIR/backups"
CLOUD_BACKUPS="/mnt/immich_storage/Full_VPS_Backups"

# Load .env so S3 creds are available if listing/restoring from Garage.
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
S3_ENDPOINT="${GARAGE_S3_ENDPOINT:-http://localhost:3900}"
S3_BUCKET="${GARAGE_S3_BUCKET:-backups}"
S3_REGION="${GARAGE_S3_REGION:-garage}"
S3_ACCESS_KEY="${GARAGE_S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${GARAGE_S3_SECRET_KEY:-}"

C_RESET='\033[0m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'
C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
title()   { echo -e "\n${C_BLUE}=== $1 ===${C_RESET}"; }
info()    { echo -e "${C_CYAN}[INFO] $1${C_RESET}"; }
warn()    { echo -e "${C_YELLOW}[WARN] $1${C_RESET}"; }
error()   { echo -e "${C_RED}[ERROR] $1${C_RESET}" >&2; }
success() { echo -e "${C_GREEN}[SUCCESS] $1${C_RESET}"; }

# ---------- Integrity check ----------

# verify_archive <path-to-tar.gz>
# Returns 0 on success. Does NOT modify anything.
verify_archive() {
  local archive="$1"
  if [ ! -f "$archive" ]; then
    error "Archive not found: $archive"
    return 1
  fi
  info "Validating gzip stream..."
  if ! gzip -t "$archive" 2>&1; then
    error "Gzip integrity check failed."
    return 1
  fi
  info "Listing tar contents..."
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    error "Tar listing failed (archive is corrupt)."
    return 1
  fi
  local n_entries size_human
  n_entries=$(tar -tzf "$archive" | wc -l)
  size_human=$(du -h "$archive" | cut -f1)
  success "Archive OK — $n_entries entries, $size_human compressed."
  return 0
}

# verify_dir_backup <path-to-backup-dir>
# Checks expected files based on service name.
verify_dir_backup() {
  local dir="$1"
  local service
  service=$(basename "$dir" | sed -E 's/_backup_.*//')

  if [ ! -d "$dir" ]; then
    error "Directory not found: $dir"
    return 1
  fi

  info "Service detected: $service"
  case "$service" in
    immich)
      [ -f "$dir/database.sql.gz" ] && info "  found database.sql.gz ($(du -h "$dir/database.sql.gz" | cut -f1))"
      gzip -t "$dir/database.sql.gz" 2>/dev/null && success "  DB dump gzip OK"
      ;;
    firefly)
      [ -f "$dir/firefly_database.sql.gz" ] && info "  found firefly_database.sql.gz ($(du -h "$dir/firefly_database.sql.gz" | cut -f1))"
      gzip -t "$dir/firefly_database.sql.gz" 2>/dev/null && success "  DB dump gzip OK"
      ;;
    *)
      info "  flat-file backup — $(find "$dir" -type f | wc -l) files, $(du -sh "$dir" | cut -f1)"
      ;;
  esac
}

# ---------- Source selection ----------

declare -a BACKUPS
SOURCE_KIND=""
SOURCE_DIR=""

list_local() {
  BACKUPS=()
  while IFS= read -r p; do BACKUPS+=("$p"); done < <(
    find "$LOCAL_BACKUPS" -maxdepth 1 -type d -name "*_backup_*" -printf '%P\n' | sort -r
  )
}

list_cloud_mirror() {
  BACKUPS=()
  [ -d "$CLOUD_BACKUPS" ] || { warn "Cloud mirror dir not present: $CLOUD_BACKUPS"; return; }
  while IFS= read -r p; do BACKUPS+=("$p"); done < <(
    find "$CLOUD_BACKUPS" -maxdepth 1 -type d -name "*_backup_*" -printf '%P\n' | sort -r
  )
}

list_s3() {
  BACKUPS=()
  if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    error "S3 credentials missing (set GARAGE_S3_ACCESS_KEY / GARAGE_S3_SECRET_KEY in .env)"
    return 1
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && BACKUPS+=("$p")
  done < <(
    podman run --rm --net=host \
      -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
      -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
      docker.io/amazon/aws-cli:latest \
      --region "$S3_REGION" --endpoint-url "$S3_ENDPOINT" \
      s3 ls "s3://$S3_BUCKET/" 2>/dev/null | awk '{print $4}' | sort -r
  )
}

select_source() {
  echo "Where to restore from?"
  echo "  1) Local backups       ($LOCAL_BACKUPS)"
  echo "  2) On-VPS cloud mirror ($CLOUD_BACKUPS)"
  echo "  3) Garage S3           ($S3_ENDPOINT)"
  read -rp "Select source: " src_opt
  case "$src_opt" in
    1) SOURCE_KIND=local; SOURCE_DIR="$LOCAL_BACKUPS"; list_local ;;
    2) SOURCE_KIND=cloud; SOURCE_DIR="$CLOUD_BACKUPS"; list_cloud_mirror ;;
    3) SOURCE_KIND=s3;    SOURCE_DIR="s3://$S3_BUCKET"; list_s3 ;;
    *) error "Invalid option"; exit 1 ;;
  esac
}

select_backup() {
  title "Available backups in $SOURCE_DIR"
  if [ ${#BACKUPS[@]} -eq 0 ]; then
    error "No backups found."
    exit 1
  fi
  local i=1
  for bk in "${BACKUPS[@]}"; do
    printf "  %2d) %s\n" "$i" "$bk"
    ((i++))
  done
  read -rp "Select backup index: " idx
  if [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt ${#BACKUPS[@]} ]; then
    error "Invalid selection"
    exit 1
  fi
  SELECTED_BACKUP="${BACKUPS[$((idx-1))]}"
  info "Selected: $SELECTED_BACKUP"
}

# ---------- Fetch + verify ----------

prepare_backup() {
  case "$SOURCE_KIND" in
    local)
      FULL_PATH="$LOCAL_BACKUPS/$SELECTED_BACKUP"
      verify_dir_backup "$FULL_PATH"
      ;;
    cloud)
      FULL_PATH="$CLOUD_BACKUPS/$SELECTED_BACKUP"
      verify_dir_backup "$FULL_PATH"
      ;;
    s3)
      local download_dir="$LOCAL_BACKUPS"
      mkdir -p "$download_dir"
      FULL_PATH="$download_dir/$SELECTED_BACKUP"
      if [ ! -f "$FULL_PATH" ]; then
        info "Downloading from S3 to $FULL_PATH ..."
        podman run --rm --net=host \
          -v "$download_dir":/downloads \
          -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
          -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
          docker.io/amazon/aws-cli:latest \
          --region "$S3_REGION" --endpoint-url "$S3_ENDPOINT" \
          s3 cp "s3://$S3_BUCKET/$SELECTED_BACKUP" "/downloads/$SELECTED_BACKUP"
      else
        info "Archive already present locally: $FULL_PATH"
      fi
      verify_archive "$FULL_PATH"
      ;;
  esac
}

# ---------- Restore instructions ----------

print_restore_instructions() {
  local service
  if [[ "$SELECTED_BACKUP" =~ \.tar\.gz$ ]]; then
    service=$(echo "$SELECTED_BACKUP" | sed -E 's/_backup_.*//')
  else
    service=$(basename "$FULL_PATH" | sed -E 's/_backup_.*//')
  fi

  title "Restore instructions for $service"
  echo "Backup: $FULL_PATH"
  echo ""
  case "$service" in
    immich)
      cat <<EOF
1. Stop Immich:
     systemctl --user stop immich.service
2. Restore database (Postgres):
     gunzip < "$FULL_PATH/database.sql.gz" | \\
       podman exec -i immich-server-immich-postgres psql -U postgres -d immich
3. Restore ML cache (if present):
     rsync -av "$FULL_PATH/ml_cache/" "$SCRIPT_DIR/data/immich/immich_model_cache/"
   Note: photos live on /mnt/immich_storage and are NOT in this backup.
4. Start Immich:
     systemctl --user start immich.service
EOF
      ;;
    firefly)
      cat <<EOF
1. Stop Firefly:
     systemctl --user stop firefly.service
2. Restore database (MariaDB):
     DB_PW=\$(podman secret inspect --showsecret firefly-db-password-k8s --format '{{.SecretData}}')
     gunzip < "$FULL_PATH/firefly_database.sql.gz" | \\
       podman exec -i firefly-pod-firefly-db sh -c "mariadb -u firefly -p\$MYSQL_PASSWORD firefly"
3. Restore data files (excluding db/ which is restored via SQL):
     rsync -av --exclude='db/' "$FULL_PATH/data/" "$SCRIPT_DIR/data/firefly/"
4. Start Firefly:
     systemctl --user start firefly.service
EOF
      ;;
    uptime-kuma|portainer|ntfy)
      cat <<EOF
1. Stop the service:
     systemctl --user stop $service.service
2. Restore data files:
     rsync -av --delete "$FULL_PATH/data/" "$SCRIPT_DIR/data/$service/"
3. Start the service:
     systemctl --user start $service.service
EOF
      ;;
    caddy)
      cat <<EOF
Caddy backup holds the Caddyfile + ACME state (certs/keys/accounts).
1. Stop Caddy:
     systemctl --user stop caddy.service
2. Restore Caddyfile + ACME data:
     rsync -av --delete "$FULL_PATH/data/" "$SCRIPT_DIR/data/caddy/"
3. Start Caddy:
     systemctl --user start caddy.service
   Restoring the ACME state avoids re-requesting certs (Let's Encrypt
   rate limits). If the certs are stale, Caddy will renew them on start.
EOF
      ;;
    *)
      warn "Unknown service '$service'. Inspect the backup manually:"
      ls -lh "$FULL_PATH" || true
      ;;
  esac
  echo ""
}

# ---------- Entry point ----------

case "${1:-}" in
  --verify)
    archive="${2:-}"
    [ -z "$archive" ] && { echo "Usage: $0 --verify <path-to-archive-or-dir>"; exit 1; }
    if [[ "$archive" =~ \.tar\.gz$ ]] || [ -f "$archive" ]; then
      verify_archive "$archive"
    else
      verify_dir_backup "$archive"
    fi
    exit $?
    ;;
  --help|-h)
    cat <<EOF
Usage:
  $0                       Interactive restore wizard
  $0 --verify <path>       Validate a backup archive or directory without restoring
EOF
    exit 0
    ;;
esac

select_source
select_backup
prepare_backup
print_restore_instructions

read -rp "Do you want to start the SERVICE STOP + FILE RESTORE now? (y/N) " do_restore
if [[ "$do_restore" =~ ^[Yy]$ ]]; then
  warn "This will overwrite files under data/. DB restore must be run manually (see above)."
  read -rp "Type the service name to confirm: " confirm_service
  service=$(basename "$FULL_PATH" | sed -E 's/_backup_.*//; s/\.tar\.gz$//')
  if [ "$confirm_service" != "$service" ]; then
    error "Confirmation mismatch ($confirm_service != $service). Aborted."
    exit 1
  fi
  systemctl --user stop "$service.service" || true
  rsync -av "$FULL_PATH/data/" "$SCRIPT_DIR/data/$service/"
  success "Files restored. Remember to run the DB restore step if applicable."
  read -rp "Start the service now? (y/N) " start_now
  if [[ "$start_now" =~ ^[Yy]$ ]]; then
    systemctl --user start "$service.service"
  fi
fi
