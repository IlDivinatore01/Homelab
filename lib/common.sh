# lib/common.sh — colour codes, logging helpers, and rootless-environment preflight.
#
# Sourced by manage.sh after configuration. Defines:
#   - C_* colour escape codes
#   - info / warn / error / success / title
#   - check_dependencies, ensure_not_root, ensure_runroot_ok
#
# Nothing in here depends on PODS / SERVICES — these are the utilities every
# other lib uses, so this is sourced first.

# shellcheck shell=bash

# --- LOGGING UTILS ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
info()    { echo -e "${C_CYAN}[INFO] $1${C_RESET}"; }
warn()    { echo -e "${C_YELLOW}[WARN] $1${C_RESET}"; }
error()   { echo -e "${C_RED}[ERROR] $1${C_RESET}" >&2; }
success() { echo -e "${C_GREEN}[SUCCESS] $1${C_RESET}"; }
title()   { echo -e "\n${C_BLUE}=== $1 ===${C_RESET}"; }

check_dependencies() {
  for cmd in rsync podman systemctl gzip find sort stat id nice ionice; do
    if ! command -v "$cmd" &>/dev/null; then
      error "'$cmd' is not installed. Please install it."
      exit 1
    fi
  done
}

ensure_not_root() {
  if [ "$(id -u)" -eq 0 ]; then
    error "Do NOT run this script as root/sudo. Run it as your rootless user."
    exit 1
  fi
}

# Prevent: /run/user/$UID/containers/overlay owned by root => podman chown fails.
ensure_runroot_ok() {
  ensure_not_root
  local uid user rr
  uid="$(id -u)"
  user="$(id -un)"
  rr="/run/user/${uid}/containers"

  mkdir -p "$rr"
  chmod 700 "$rr" || true

  if [ -d "$rr/overlay" ]; then
    local owner
    owner="$(stat -c '%U:%G' "$rr/overlay" 2>/dev/null || echo "unknown:unknown")"
    if [[ "$owner" != "${user}:"* ]]; then
      warn "runroot overlay ownership is '$owner' (expected ${user}:*). Resetting $rr ..."
      rm -rf "$rr"
      mkdir -p "$rr"
      chmod 700 "$rr"
    fi
  fi
}
