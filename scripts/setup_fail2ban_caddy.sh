#!/bin/bash
# Installs the fail2ban filter+jail that protects Caddy from brute-force
# login attempts (Firefly, Immich, Portainer, etc.). Idempotent: re-running is safe.
#
# Prereqs:
#   1. fail2ban already installed   (run setup_fail2ban.sh first)
#   2. data/caddy/Caddyfile contains the access-log block writing to
#      /var/log/caddy/access.log (see config_examples/Caddyfile.example)
#   3. caddy.pod.yaml mounts data/caddy/log/ → /var/log/caddy in the container
#      (already done in this repo as of the round-2 hardening)
#
# Usage: sudo ./scripts/setup_fail2ban_caddy.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script needs root (it writes to /etc/fail2ban). Re-run with: sudo $0"
  exit 1
fi

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
SRC_DIR="$SCRIPT_DIR/scripts/fail2ban"
ACCESS_LOG="$SCRIPT_DIR/data/caddy/log/access.log"

C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
ok()   { echo -e "${C_GREEN}[OK]${C_RESET}   $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[ERR]${C_RESET}  $*" >&2; }

# 1) Sanity checks
if ! command -v fail2ban-client >/dev/null; then
  err "fail2ban not installed. Run scripts/setup_fail2ban.sh first."
  exit 1
fi

if [ ! -d "$SCRIPT_DIR/data/caddy/log" ]; then
  warn "Log dir $SCRIPT_DIR/data/caddy/log not present yet — will be created by Caddy on next restart."
  mkdir -p "$SCRIPT_DIR/data/caddy/log"
  chown osvaldo:osvaldo "$SCRIPT_DIR/data/caddy/log"
fi

# 2) Install filter and jail
install -m 644 "$SRC_DIR/caddy-auth.filter" /etc/fail2ban/filter.d/caddy-auth.conf
ok "Installed filter: /etc/fail2ban/filter.d/caddy-auth.conf"

install -m 644 "$SRC_DIR/caddy-auth.jail"   /etc/fail2ban/jail.d/caddy-auth.conf
ok "Installed jail:   /etc/fail2ban/jail.d/caddy-auth.conf"

# 3) Reload + sanity
systemctl restart fail2ban
sleep 1
if fail2ban-client status caddy-auth >/dev/null 2>&1; then
  ok "Jail 'caddy-auth' is active:"
  fail2ban-client status caddy-auth
else
  err "Jail 'caddy-auth' failed to start. Check: journalctl -u fail2ban -n 50"
  exit 1
fi

# 4) Reminder: caddy must be restarted to start writing to the log file
if [ ! -f "$ACCESS_LOG" ]; then
  warn "Caddy access log file does not exist yet: $ACCESS_LOG"
  warn "Restart Caddy to begin logging: systemctl --user restart caddy.service"
fi
