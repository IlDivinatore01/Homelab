#!/bin/bash
# Runs every few minutes from cron. Looks for containers reported as
# 'unhealthy' by Podman's healthcheck, restarts the corresponding systemd
# service, and pings ntfy. Silent on success.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/healthcheck.log"
# Flap-protection state — not a log; kept under state/ so 'rm logs/*' is safe.
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/healthcheck-last-state"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# One-shot migration: move the file from its previous logs/ location.
if [ -f "$LOG_DIR/.healthcheck-last-state" ] && [ ! -f "$STATE_FILE" ]; then
  mv "$LOG_DIR/.healthcheck-last-state" "$STATE_FILE"
fi

# Size-based rotation: this script runs every 5 min, so a daily filename would
# create 288 tiny files/day. Instead append to a single file and rotate when
# it crosses ~512 KB (~6k events at ~85 B avg), keeping one .1 backup
# (~1 MB max footprint per service).
LOG_MAX_BYTES=524288
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib_notify.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# Map container name → systemd service. Containers we want to auto-recover.
declare -A SVC_MAP=(
  [immich-server-immich-app-server]="immich"
  [immich-server-immich-machine-learning]="immich"
  [immich-server-immich-postgres]="immich"
  [firefly-pod-firefly-app]="firefly"
  [firefly-pod-firefly-db]="firefly"
  [firefly-importer-pod-firefly-importer]="firefly-importer"
)

# Build the current 'unhealthy' set
unhealthy_now=$(podman ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null || true)

# Track which services we already attempted to restart this period, to avoid
# flapping (keep state for 30 min, cron runs every 5 min).
declare -A restarted_recently
if [ -f "$STATE_FILE" ]; then
  while IFS='|' read -r svc when; do
    age=$(( $(date +%s) - when ))
    if [ "$age" -lt 1800 ]; then
      restarted_recently["$svc"]=1
    fi
  done < "$STATE_FILE"
fi

> "$STATE_FILE.new"

if [ -z "$unhealthy_now" ]; then
  # Preserve still-fresh entries (don't lose flap protection)
  for svc in "${!restarted_recently[@]}"; do
    echo "$svc|$(date +%s)" >> "$STATE_FILE.new"
  done
  mv "$STATE_FILE.new" "$STATE_FILE"
  exit 0
fi

restarted_this_run=()
for container in $unhealthy_now; do
  svc="${SVC_MAP[$container]:-}"
  if [ -z "$svc" ]; then
    log "Unhealthy container '$container' is not in SVC_MAP — skipping restart"
    continue
  fi

  if [ -n "${restarted_recently[$svc]:-}" ]; then
    log "Service '$svc' already restarted in the last 30 min — flap protection, skipping"
    notify warning "Homelab — container persistente unhealthy" "$container ($svc) ancora unhealthy dopo restart. Intervento manuale necessario."
    continue
  fi

  log "Container '$container' unhealthy → restarting service '$svc'"
  notify warning "Homelab — container unhealthy" "$container è unhealthy. Tentativo di restart automatico del servizio $svc."
  if systemctl --user restart "$svc.service"; then
    log "Service '$svc' restart issued"
    restarted_this_run+=("$svc")
  else
    log "ERROR: failed to restart '$svc.service'"
    notify failure "Homelab — restart automatico fallito" "Tentativo di riavvio di $svc è fallito. Intervento manuale necessario."
  fi
done

# Persist the new state
{
  for svc in "${!restarted_recently[@]}"; do
    echo "$svc|$(date +%s)"
  done
  for svc in "${restarted_this_run[@]}"; do
    echo "$svc|$(date +%s)"
  done
} | sort -u > "$STATE_FILE.new"
mv "$STATE_FILE.new" "$STATE_FILE"
