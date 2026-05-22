#!/bin/bash
# Weekly database optimization (VACUUM ANALYZE for Postgres, mariadb-check for MariaDB).
# Invoked from cron — uses the non-interactive entry point of manage_finale.sh
# via the optimize_databases function inside it.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/db_optimize_$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

# Load .env (NTFY_*) and the notify helper.
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib_notify.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "=== WEEKLY DB OPTIMIZE STARTED ==="
START_TS=$(date +%s)

cd "$SCRIPT_DIR"

# Source the manage script and call the function directly (non-interactive).
# The main script gates the menu behind 'if [ $# -gt 0 ]' so passing a flag short-circuits it.
if ./manage_finale.sh --optimize-db >> "$LOG_FILE" 2>&1; then
    log "DB optimization completed successfully"
    EXIT=0
    DURATION=$(( $(date +%s) - START_TS ))
    notify ok "Homelab — DB optimize OK" "VACUUM/mariadb-check completati in ${DURATION}s."
else
    log "ERROR: DB optimization reported failure"
    EXIT=1
    LAST_LINES=$(tail -10 "$LOG_FILE" | grep -iE "error|fail" | tail -3 | tr '\n' ' ' | head -c 500)
    notify failure "Homelab — DB optimize FAILED" "Weekly DB maintenance ha riportato errori. Ultimi messaggi: ${LAST_LINES:-(vedi log)}"
fi

log "=== WEEKLY DB OPTIMIZE FINISHED ==="

# Keep only the last 60 days of logs
find "$LOG_DIR" -name "db_optimize_*.log" -mtime +60 -delete 2>/dev/null || true

exit $EXIT
