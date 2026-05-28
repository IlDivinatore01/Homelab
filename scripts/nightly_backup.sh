#!/bin/bash
# Nightly Backup Script
# Runs via cron at 03:00. Uses the non-interactive --backup-all mode.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/nightly_backup_$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

# Load .env (NTFY_* and GARAGE_S3_*) and the notify helper.
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib_notify.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== NIGHTLY BACKUP STARTED ==="
START_TS=$(date +%s)

cd "$SCRIPT_DIR"

if ./manage.sh --backup-all >> "$LOG_FILE" 2>&1; then
    log "Nightly backup completed successfully"
    EXIT=0
    DURATION=$(( $(date +%s) - START_TS ))
    notify ok "Homelab — backup OK" "Nightly backup completato in ${DURATION}s. Log: $(basename "$LOG_FILE")"
else
    log "ERROR: Nightly backup reported failures (see log above)"
    EXIT=1
    # Grab the last failing service names from the log for the alert body.
    LAST_LINES=$(tail -20 "$LOG_FILE" | grep -iE "error|fail" | tail -5 | tr '\n' ' ' | head -c 500)
    notify failure "Homelab — backup FAILED" "Nightly backup ha riportato errori. Ultimi messaggi: ${LAST_LINES:-(vedi log)}"
fi

log "=== NIGHTLY BACKUP FINISHED ==="

# Cleanup old logs (keep last 7 days)
find "$LOG_DIR" -name "nightly_backup_*.log" -mtime +7 -delete 2>/dev/null || true

exit $EXIT
