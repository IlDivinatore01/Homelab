#!/bin/bash
# Nightly Backup Script for Immich and Firefly
# Runs via cron at 3:00 AM
# Logs to /home/osvaldo/podman/logs/nightly_backup.log

set -e

SCRIPT_DIR="/home/osvaldo/podman"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/nightly_backup_$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== NIGHTLY BACKUP STARTED ==="

# Source the manage script functions
cd "$SCRIPT_DIR"

# Backup Immich
log "Starting Immich backup..."
if ./manage_finale.sh <<< "4" >> "$LOG_FILE" 2>&1; then
    log "Immich backup completed successfully"
else
    log "ERROR: Immich backup failed"
fi

# Small delay between backups
sleep 5

# Backup Firefly
log "Starting Firefly backup..."
if ./manage_finale.sh <<< "5" >> "$LOG_FILE" 2>&1; then
    log "Firefly backup completed successfully"
else
    log "ERROR: Firefly backup failed"
fi

log "=== NIGHTLY BACKUP FINISHED ==="

# Cleanup old logs (keep last 7 days)
find "$LOG_DIR" -name "nightly_backup_*.log" -mtime +7 -delete 2>/dev/null || true

log "Old logs cleaned up"
