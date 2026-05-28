# lib/ui.sh — interactive menu + non-interactive CLI dispatch.
#
# Depends on every other lib (calls deploy_pod, restart_service, update_*,
# backup_*, optimize_databases, cleanup_all, verify_quadlets, restart_caddy,
# download_from_s3) and on the manage.sh-level vars CONTINUE_ON_RESTART_ERROR,
# PODS, SERVICES, BACKUP_BASE_DIR.
#
# Functions:
#   select_services <prompt> <out_array>   – multi-select picker used by the menu
#   main_menu                              – the interactive loop
#   run_non_interactive <flag> [args]      – flag dispatch for cron / scripts

# shellcheck shell=bash

select_services() {
  local prompt="$1"
  local -n _selected=$2
  echo "$prompt"
  local i=1
  for svc in "${SERVICES[@]}"; do echo "  $i) $svc"; ((i++)); done
  echo "  a) all"
  read -p "Enter number(s) or 'a': " choices
  if [[ "$choices" == "a" ]]; then
    _selected=("${SERVICES[@]}")
  else
    IFS=',' read -ra idxs <<< "$choices"
    for idx in "${idxs[@]}"; do
      idx="$(echo "$idx" | xargs)"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#SERVICES[@]} )); then
        _selected+=("${SERVICES[$((idx-1))]}")
      fi
    done
  fi
}

main_menu() {
  while true; do
    echo ""; title "PODMAN SERVICE MANAGER (Quadlet Edition v2.8)"; echo ""
    echo " 1) Start/Restart Services"
    echo " 2) Update Services (with Pull & Backup)"
    echo " 3) Stop Services"
    echo "----------------------------"
    echo " 4) Backup Immich"
    echo " 5) Backup Firefly III"
    echo " 7) Backup System Tools (Kuma/Portainer/ntfy)"

    echo " 8) List Backups"
    echo " 9) Restore / Download from S3"
    echo "----------------------------"
    echo " 10) Full System Cleanup"
    echo " 11) Setup & Verify Quadlet Config"
    echo " 12) Restart Caddy Proxy"
    echo " 13) Optimize Databases"
    echo " 0) Exit"
    echo ""
    read -p "Select Option: " opt

    case "$opt" in
      1)
        local selected=()
        select_services "Select services to start/restart:" selected

        if [[ " ${selected[*]} " =~ " site " ]]; then
          build_site
        fi

        if [[ " ${selected[*]} " =~ " fastfood " ]]; then
          build_fastfood
        fi

        local failed=()
        for svc in "${selected[@]}"; do
          if ! deploy_pod "${PODS[$svc]}"; then
            failed+=("$svc")
            if [ "$CONTINUE_ON_RESTART_ERROR" = false ]; then
              error "Stopping due to failure (CONTINUE_ON_RESTART_ERROR=false)."
              return 1
            fi
          fi
        done

        if [ "${#failed[@]}" -gt 0 ]; then
          warn "Some services failed: ${failed[*]}"
          warn "Check with: systemctl --user status <name>.service --no-pager -l"
        fi
        ;;
      2)
        local selected=()
        select_services "Select services to update:" selected

        local firefly_update=false
        for svc in "${selected[@]}"; do [[ "$svc" =~ firefly ]] && firefly_update=true && break; done
        if [ "$firefly_update" = true ]; then update_firefly; fi

        for svc in "${selected[@]}"; do
          case "$svc" in
            immich) update_immich ;;
            firefly|firefly-importer) continue ;;
            site) build_site; restart_service "site" ;;
            *) update_generic "$svc" ;;
          esac
        done
        ;;
      3)
        local selected=()
        select_services "Select services to stop:" selected
        for svc in "${selected[@]}"; do stop_service "$svc"; done
        ;;
      4) backup_immich ;;
      5) backup_firefly ;;
      7) backup_uptime_kuma; backup_portainer; backup_ntfy; backup_caddy ;;

      8) echo ""; ls -lht "$BACKUP_BASE_DIR"/ | head -20 ;;
      9) download_from_s3 ;;
      10) cleanup_all ;;
      11) verify_quadlets ;;
      12) restart_caddy ;;
      13) optimize_databases ;;
      0) exit 0 ;;
      *) error "Invalid option." ;;
    esac
  done
}

# Usage: ./manage.sh --backup-all
#        ./manage.sh --backup <service>
#        ./manage.sh --restart <service>
run_non_interactive() {
  local cmd="$1"
  shift || true
  case "$cmd" in
    --backup-all)
      title "AUTOMATED NIGHTLY BACKUP"
      local failed=()
      backup_immich      || failed+=("immich")
      backup_firefly     || failed+=("firefly")
      backup_uptime_kuma || failed+=("uptime-kuma")
      backup_portainer   || failed+=("portainer")
      backup_ntfy        || failed+=("ntfy")
      backup_caddy       || failed+=("caddy")
      if [ "${#failed[@]}" -gt 0 ]; then
        error "Backup failures: ${failed[*]}"
        return 1
      fi
      success "All scheduled backups completed."
      return 0
      ;;
    --backup)
      local svc="${1:-}"
      case "$svc" in
        immich)       backup_immich ;;
        firefly)      backup_firefly ;;
        uptime-kuma)  backup_uptime_kuma ;;
        portainer)    backup_portainer ;;
        ntfy)         backup_ntfy ;;
        caddy)        backup_caddy ;;
        *)            error "Unknown service for backup: '$svc'"; return 1 ;;
      esac
      ;;
    --restart)
      local svc="${1:-}"
      [ -z "$svc" ] && { error "Usage: --restart <service>"; return 1; }
      restart_service "$svc"
      ;;
    --optimize-db)
      optimize_databases
      ;;
    --help|-h)
      echo "Usage:"
      echo "  $0                         # Interactive menu"
      echo "  $0 --backup-all            # Backup all services (for cron)"
      echo "  $0 --backup <service>      # Backup a single service"
      echo "  $0 --restart <service>     # Restart a single service"
      echo "  $0 --optimize-db           # VACUUM Postgres + mariadb-check (for cron)"
      return 0
      ;;
    *)
      error "Unknown flag: '$cmd'. Use --help for usage."
      return 1
      ;;
  esac
}
