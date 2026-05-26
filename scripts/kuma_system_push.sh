#!/usr/bin/env bash
# Push system metrics to Uptime Kuma (push-type monitors).
#
# Usage:
#   kuma_system_push.sh mem  <warn%> <crit%>           <push_url>
#   kuma_system_push.sh load <warn>  <crit>            <push_url>
#   kuma_system_push.sh disk <mount> <warn%> <crit%>   <push_url>
#
# warn/crit thresholds are inclusive. The status sent to Kuma is "up" unless
# usage reaches the crit threshold (then "down"); messages tag WARN/CRIT.
# The numeric value (used%/load) is sent as ping= so Kuma graphs it.
#
# Pair with the matching push monitor in Kuma; copy its push URL into cron.

set -Eeuo pipefail

push() {
  local status="$1" msg="$2" value="$3" url="$4"
  # Strip any pre-existing query string (Kuma's UI shows the push URL with
  # sample params '?status=up&msg=OK&ping=' baked in; copy-pasting that and
  # appending more params produces a malformed URL with two '?').
  url="${url%%\?*}"
  curl -fsS -m 10 -o /dev/null \
    "${url}?status=${status}&msg=$(printf %s "$msg" | sed 's/ /%20/g')&ping=${value}"
}

metric="${1:?Usage: $0 <mem|load|disk> ...}"
shift

case "$metric" in
  mem)
    WARN="${1:-80}"; CRIT="${2:-95}"; URL="${3:?push_url required}"
    used=$(free | awk '/^Mem:/ {printf "%d", ($3/$2)*100}')
    status="up"; msg="mem=${used}% warn=${WARN}% crit=${CRIT}%"
    if [ "$used" -ge "$CRIT" ]; then status="down"; msg="CRIT $msg"
    elif [ "$used" -ge "$WARN" ]; then msg="WARN $msg"; fi
    push "$status" "$msg" "$used" "$URL"
    ;;

  load)
    # 5-min load average, multiplied by 100 so Kuma graphs at integer resolution
    # (e.g. load 1.47 → ping=147). Warn/crit thresholds use the same scale.
    # On a 2-core host, sensible defaults: warn=200 (load 2.0), crit=400 (load 4.0).
    WARN="${1:-200}"; CRIT="${2:-400}"; URL="${3:?push_url required}"
    load_x100=$(awk '{printf "%d", $2*100}' /proc/loadavg)
    status="up"; msg="load5=$(awk '{print $2}' /proc/loadavg) warn=${WARN} crit=${CRIT}"
    if [ "$load_x100" -ge "$CRIT" ]; then status="down"; msg="CRIT $msg"
    elif [ "$load_x100" -ge "$WARN" ]; then msg="WARN $msg"; fi
    push "$status" "$msg" "$load_x100" "$URL"
    ;;

  disk)
    MOUNT="${1:?mount required}"; WARN="${2:-80}"; CRIT="${3:-90}"; URL="${4:?push_url required}"
    used=$(df -P "$MOUNT" | awk 'END{gsub("%","",$5); print $5+0}')
    status="up"; msg="fs=$MOUNT used=${used}% warn=${WARN}% crit=${CRIT}%"
    if [ "$used" -ge "$CRIT" ]; then status="down"; msg="CRIT $msg"
    elif [ "$used" -ge "$WARN" ]; then msg="WARN $msg"; fi
    push "$status" "$msg" "$used" "$URL"
    ;;

  *)
    echo "Unknown metric: $metric" >&2
    echo "Usage: $0 <mem|load|disk> ..." >&2
    exit 1
    ;;
esac
