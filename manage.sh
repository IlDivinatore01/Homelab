#!/bin/bash
set -euo pipefail

# =============================================================================
# PODMAN SERVICE MANAGER — SYSTEMD QUADLET EDITION v2.8 (May 2026)
#
# Entry point. Loads .env, declares the SERVICES / PODS catalog, sources the
# per-concern libs in lib/, runs the preflight checks, then either dispatches
# to a flag-driven command (cron / scripts) or opens the interactive menu.
#
# Concerns live in:
#   lib/common.sh       – logging utils + preflight (deps, not-root, runroot)
#   lib/services.sh     – pod lifecycle + quadlet install
#   lib/backup.sh       – rotation + S3 sync + per-service backup_*
#   lib/maintenance.sh  – build_*, update_*, optimize_databases, cleanup_all
#   lib/ui.sh           – select_services, main_menu, run_non_interactive
# =============================================================================

# --- CONFIGURATION ---
PODMAN_SETUP_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MAIN_DATA_DIR="$PODMAN_SETUP_DIR/data/site"
BACKUP_BASE_DIR="$PODMAN_SETUP_DIR/backups"

# Load environment variables from .env (gitignored secrets).
if [ -f "$PODMAN_SETUP_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$PODMAN_SETUP_DIR/.env"
  set +a
fi

SHARED_NETWORK_NAME="services_net"
SHARED_NETWORK_UNIT="${SHARED_NETWORK_NAME}-network.service"

CONTINUE_ON_RESTART_ERROR=true
MAX_BACKUPS_PER_SERVICE=3
OFFSITE_BACKUP_DIR="/mnt/immich_storage/Full_VPS_Backups"
OFFSITE_LIMIT=5

# Lower CPU + IO scheduling priority for backup-heavy ops (gzip/tar/rsync) so
# the nightly backup doesn't starve foreground services. Without this the
# backup spiked the 2-core host to load ~6 and tripped Uptime Kuma's load
# alert. nice 19 = lowest CPU prio; ionice c2 n7 = best-effort lowest IO prio
# (not 'idle' c3, which could stall the backup indefinitely under IO contention).
NICE_CMD="nice -n 19 ionice -c2 -n7"

# S3 backup configuration (Garage) — credentials loaded from .env.
S3_ENDPOINT="${GARAGE_S3_ENDPOINT:-http://localhost:3900}"
S3_BUCKET="${GARAGE_S3_BUCKET:-backups}"
S3_REGION="${GARAGE_S3_REGION:-garage}"
S3_ACCESS_KEY="${GARAGE_S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${GARAGE_S3_SECRET_KEY:-}"
USE_S3_BACKUP=true  # Set to false to fall back to the old rsync method

declare -A PODS=(
  [homepage]="$PODMAN_SETUP_DIR/kube_yaml/homepage.pod.yaml"
  [site]="$PODMAN_SETUP_DIR/kube_yaml/site.pod.yaml"
  [immich]="$PODMAN_SETUP_DIR/kube_yaml/immich.pod.yaml"
  [firefly]="$PODMAN_SETUP_DIR/kube_yaml/firefly.pod.yaml"
  [firefly-importer]="$PODMAN_SETUP_DIR/kube_yaml/firefly-importer.pod.yaml"
  [uptime-kuma]="$PODMAN_SETUP_DIR/kube_yaml/uptime-kuma.pod.yaml"
  [portainer]="$PODMAN_SETUP_DIR/kube_yaml/portainer.pod.yaml"
  [it-tools]="$PODMAN_SETUP_DIR/kube_yaml/it-tools.pod.yaml"
  [garage]="$PODMAN_SETUP_DIR/kube_yaml/garage.pod.yaml"
  [ntfy]="$PODMAN_SETUP_DIR/kube_yaml/ntfy.pod.yaml"
  [fastfood]="$PODMAN_SETUP_DIR/kube_yaml/fastfood.pod.yaml"
)
SERVICES=(homepage site immich firefly firefly-importer uptime-kuma portainer fastfood it-tools garage ntfy)

# Disabled services (YAML kept in kube_yaml/disabled/, quadlet removed):
# - metabase (analytics): no longer used, data still in data/metabase/
# - actual   (budget):    no longer used, data still in data/actual/
# To re-enable: move the .yaml back into kube_yaml/, add an entry to PODS
# and SERVICES above, create a quadlets/<svc>.kube, then run verify_quadlets.
# When PERMANENTLY removing a service: also wipe its backups, since
# rotate_backups() only touches services still in SERVICES.
#   rm -rf "$BACKUP_BASE_DIR/<svc>_backup_"*

# --- LIBS ---
# Sourced in dependency order. Function lookup is lazy in bash, so cross-lib
# calls (e.g. update_immich -> backup_immich, ui.sh -> deploy_pod) resolve
# correctly regardless — but keeping this order matches the layering.
LIB_DIR="$PODMAN_SETUP_DIR/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=lib/maintenance.sh
source "$LIB_DIR/maintenance.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

# --- ENTRY POINT ---
check_dependencies
ensure_not_root
ensure_runroot_ok
ensure_shared_network

if [ $# -gt 0 ]; then
  run_non_interactive "$@"
  exit $?
fi

main_menu
