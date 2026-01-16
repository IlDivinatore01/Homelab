#!/bin/bash
set -euo pipefail

# RESTORE WIZARD v1.0
# Helps locate and restore backups for Podman services

PODMAN_SETUP_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LOCAL_BACKUPS="$PODMAN_SETUP_DIR/backups"
CLOUD_BACKUPS="/mnt/immich_storage/Full_VPS_Backups"

title() { echo -e "\n\033[0;34m=== $1 ===\033[0m"; }
info()  { echo -e "\033[0;36m[INFO] $1\033[0m"; }
warn()  { echo -e "\033[0;33m[WARN] $1\033[0m"; }
error() { echo -e "\033[0;31m[ERROR] $1\033[0m"; }

select_source() {
  echo "Where to restore from?"
  echo " 1) Local Backups ($LOCAL_BACKUPS)"
  echo " 2) Cloud Storage ($CLOUD_BACKUPS)"
  read -p "Select Source: " src_opt
  case "$src_opt" in
    1) SOURCE_DIR="$LOCAL_BACKUPS" ;;
    2) SOURCE_DIR="$CLOUD_BACKUPS" ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
}

select_backup() {
  title "Available Backups in $SOURCE_DIR"
  # List directories, sorted by date
  backups=($(find "$SOURCE_DIR" -maxdepth 1 -type d -name "*_backup_*" -printf '%P\n' | sort -r))
  
  if [ ${#backups[@]} -eq 0 ]; then
    error "No backups found in $SOURCE_DIR"
    exit 1
  fi

  local i=1
  for bk in "${backups[@]}"; do
    echo " $i) $bk"
    ((i++))
  done

  read -p "Select Backup to Restore: " bk_idx
  if [[ ! "$bk_idx" =~ ^[0-9]+$ ]] || [ "$bk_idx" -lt 1 ] || [ "$bk_idx" -gt ${#backups[@]} ]; then
    error "Invalid selection"
    exit 1
  fi

  SELECTED_BACKUP="${backups[$((bk_idx-1))]}"
  FULL_PATH="$SOURCE_DIR/$SELECTED_BACKUP"
  info "Selected: $SELECTED_BACKUP"
}

analyze_backup() {
  SERVICE_NAME=$(echo "$SELECTED_BACKUP" | sed -E 's/_backup_.*//')
  
  title "Restore Instructions for $SERVICE_NAME"
  echo "Backup Path: $FULL_PATH"
  echo ""
  
  case "$SERVICE_NAME" in
    immich)
      echo "Type: PostgreSQL Database + Files"
      echo "--- INSTRUCTIONS ---"
      echo "1. Stop Immich:  systemctl --user stop immich.service"
      echo "2. Restore DB:"
      echo "   gunzip < \"$FULL_PATH/database.sql.gz\" | podman exec -i immich-server-immich-postgres psql -U postgres -d immich"
      echo "3. Restore Files:"
      echo "   rsync -av \"$FULL_PATH/data/\" \"$PODMAN_SETUP_DIR/data/immich/\""
      echo "4. Start Immich: systemctl --user start immich.service"
      ;;
    firefly)
      echo "Type: MariaDB Database + Files"
      echo "--- INSTRUCTIONS ---"
      echo "1. Stop Firefly: systemctl --user stop firefly.service"
      echo "2. Restore DB:"
      echo "   gunzip < \"$FULL_PATH/firefly_database.sql.gz\" | podman exec -i firefly-pod-firefly-db mariadb -u firefly -p(PASSWORD) firefly"
      echo "3. Restore Files:"
      echo "   rsync -av \"$FULL_PATH/data/\" \"$PODMAN_SETUP_DIR/data/firefly/\""
      echo "4. Start Firefly: systemctl --user start firefly.service"
      ;;
    uptime-kuma|portainer|actual)
      echo "Type: Flat Files (Data Directory)"
      echo "--- INSTRUCTIONS ---"
      echo "1. Stop Service: systemctl --user stop $SERVICE_NAME.service"
      echo "2. Restore Files:"
      echo "   rsync -av --delete \"$FULL_PATH/data/\" \"$PODMAN_SETUP_DIR/data/$SERVICE_NAME/\""
      echo "3. Start Service: systemctl --user start $SERVICE_NAME.service"
      ;;
    *)
      warn "Unknown service type. Check the backup folder content and restore manually."
      ls -lh "$FULL_PATH"
      ;;
  esac
  echo ""
  read -p "Do you want to run the File Restore (Step 2/3) automatically? (y/N) " auto_restore
  if [[ "$auto_restore" =~ ^[Yy]$ ]]; then
    perform_file_restore
  fi
}

perform_file_restore() {
  warn "Starting File Restore for $SERVICE_NAME..."
  
  # Confirm Target
  TARGET_DIR="$PODMAN_SETUP_DIR/data/$SERVICE_NAME"
  if [ ! -d "$TARGET_DIR" ]; then
    error "Target directory $TARGET_DIR does not exist!"
    return
  fi

  systemctl --user stop "$SERVICE_NAME.service" || true
  
  rsync -av "$FULL_PATH/data/" "$TARGET_DIR/"
  success "Files restored."

  if [[ "$SERVICE_NAME" == "immich" || "$SERVICE_NAME" == "firefly" ]]; then
     warn "Database restore was NOT performed automatically. Please copy/paste the command above to restore the DB."
  fi
  
  read -p "Start service now? (y/N) " start_now
  if [[ "$start_now" =~ ^[Yy]$ ]]; then
    systemctl --user start "$SERVICE_NAME.service"
  fi
}

# MAIN
select_source
select_backup
analyze_backup
