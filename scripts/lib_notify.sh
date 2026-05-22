#!/bin/bash
# Tiny helper: send a notification to ntfy if NTFY_URL/NTFY_TOPIC/NTFY_TOKEN
# are set in the environment. Sourced by other scripts.
#
# Usage:
#   source scripts/lib_notify.sh
#   notify ok       "Title" "Body line"
#   notify warning  "Title" "Body line"
#   notify failure  "Title" "Body line"

notify() {
  local level="$1"; shift
  local title="$1"; shift
  local body="$*"

  if [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_TOPIC:-}" ] || [ -z "${NTFY_TOKEN:-}" ]; then
    # No notification config — be silent, this is normal in dev.
    return 0
  fi

  local priority tags
  case "$level" in
    ok)       priority="default"; tags="white_check_mark" ;;
    warning)  priority="high";    tags="warning" ;;
    failure)  priority="high";    tags="rotating_light" ;;
    *)        priority="default"; tags="information_source" ;;
  esac

  # Fire-and-forget: don't let a network hiccup break the calling script.
  curl -sS --max-time 10 \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" \
    "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}
