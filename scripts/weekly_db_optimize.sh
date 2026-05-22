#!/bin/bash
# Weekly database optimization (VACUUM ANALYZE for Postgres, mariadb-check for MariaDB).
# Invoked from cron — uses the non-interactive entry point of manage_finale.sh
# via the optimize_databases function inside it.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/db_optimize_$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "=== WEEKLY DB OPTIMIZE STARTED ==="

cd "$SCRIPT_DIR"

# Source the manage script and call the function directly (non-interactive).
# We avoid running the menu by sourcing without invoking main_menu.
# The script gates the menu behind 'if [ $# -gt 0 ]' so passing a flag short-circuits it.
if ./manage_finale.sh --optimize-db >> "$LOG_FILE" 2>&1; then
    log "DB optimization completed successfully"
    EXIT=0
else
    log "ERROR: DB optimization reported failure"
    EXIT=1
fi

log "=== WEEKLY DB OPTIMIZE FINISHED ==="

# Keep only the last 8 weeks of logs
find "$LOG_DIR" -name "db_optimize_*.log" -mtime +60 -delete 2>/dev/null || true

exit $EXIT
