# lib/services.sh — pod/service lifecycle and quadlet installation.
#
# Depends on lib/common.sh (info, warn, error, success, ensure_runroot_ok)
# and the manage.sh-level vars: SHARED_NETWORK_NAME, SHARED_NETWORK_UNIT,
# PODMAN_SETUP_DIR.
#
# Functions:
#   ensure_shared_network   – brings up both quadlet networks (or creates them)
#   restart_service / stop_service / deploy_pod
#   restart_caddy           – convenience wrapper
#   bootstrap_quadlets      – installs quadlets/ -> ~/.config/containers/systemd/
#   verify_quadlets         – bootstrap + podman-system-generator dry-run

# shellcheck shell=bash

# Ensure services_net (and sensitive_net) exist.
# Prefer starting quadlet-generated *-network.service units if present, else
# fall back to `podman network create`.
ensure_shared_network() {
  ensure_runroot_ok

  # If the quadlet network unit exists (generated), start it (oneshot, RemainAfterExit).
  if systemctl --user list-unit-files --no-pager 2>/dev/null | grep -q "^${SHARED_NETWORK_UNIT}"; then
    systemctl --user start "${SHARED_NETWORK_UNIT}" || true
  fi

  # Start the isolated sensitive_net unit too (firefly/immich/caddy need it).
  if systemctl --user list-unit-files --no-pager 2>/dev/null | grep -q "^sensitive_net-network.service"; then
    systemctl --user start "sensitive_net-network.service" || true
  fi

  # Hard guarantee: both networks must exist for kube units that reference them.
  local n
  for n in "$SHARED_NETWORK_NAME" "sensitive_net"; do
    if ! podman network exists "$n"; then
      warn "Podman network '$n' missing. Creating..."
      podman network create "$n" >/dev/null
      success "Network '$n' created."
    fi
  done
}

restart_service() {
  ensure_shared_network
  local service_name="$1"
  info "Restarting Systemd Service: $service_name..."
  systemctl --user daemon-reload
  if systemctl --user restart "$service_name.service"; then
    success "Service '$service_name' restarted successfully."
  else
    error "Failed to restart '$service_name'."
    error "Hint: systemctl --user status $service_name.service --no-pager -l"
    error "Hint: journalctl --user -u $service_name.service -b --no-pager -n 200"
    return 1
  fi
}

stop_service() {
  ensure_runroot_ok
  local service_name="$1"
  info "Stopping Systemd Service: $service_name..."
  if systemctl --user stop "$service_name.service"; then
    success "Service '$service_name' stopped."
  else
    error "Failed to stop '$service_name'."
    return 1
  fi
}

deploy_pod() {
  ensure_shared_network
  local pod_yaml_file="$1"
  local service_name
  service_name="$(basename "$pod_yaml_file" .pod.yaml)"

  if [ ! -f "$pod_yaml_file" ]; then
    error "YAML file not found: $pod_yaml_file"
    return 1
  fi

  restart_service "$service_name"
}

restart_caddy() {
  title "RESTART CADDY"
  restart_service "caddy"
}

bootstrap_quadlets() {
  # Source-of-truth for *.kube and *.network units is $PODMAN_SETUP_DIR/quadlets/
  # (under git). This function installs anything that has drifted into the
  # active dir ~/.config/containers/systemd/ where systemd-quadlet looks for
  # them. Always edit the SOURCE, never the live copy — live edits will be
  # silently overwritten on the next bootstrap.
  #
  # Encoded statically in those files (see quadlets/README.md):
  #   - boot order: After= chain that serializes 'podman kube play' at boot
  #     so concurrent pods don't corrupt podman's sqlite state DB
  #   - trust zones: Network=services_net.network (general) vs
  #     Network=sensitive_net.network (firefly/immich); caddy is multi-homed
  #   - TimeoutStartSec=300 to survive slow initial image pulls
  local systemd_dir="$HOME/.config/containers/systemd"
  local src_dir="$PODMAN_SETUP_DIR/quadlets"

  mkdir -p "$systemd_dir"

  if [ ! -d "$src_dir" ]; then
    error "Quadlet source dir missing: $src_dir"
    return 1
  fi

  local changed=0
  shopt -s nullglob
  for f in "$src_dir"/*.kube "$src_dir"/*.network; do
    local dst="$systemd_dir/$(basename "$f")"
    if ! cmp -s "$f" "$dst"; then
      install -m 644 "$f" "$dst"
      info "Installed $(basename "$f")"
      changed=1
    fi
  done
  shopt -u nullglob

  if [ "$changed" -eq 1 ]; then
    info "Reloading systemd user units..."
    systemctl --user daemon-reload
  else
    info "Quadlets already in sync with $src_dir."
  fi
}

verify_quadlets() {
  title "VERIFYING & BOOTSTRAPPING QUADLET FILES"
  bootstrap_quadlets
  ensure_shared_network
  if /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun; then
    success "Quadlet files are valid syntax."
  else
    error "Quadlet syntax error detected!"
    return 1
  fi
}
