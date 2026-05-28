# Server architecture

How this homelab actually runs at boot and at steady state. For first-time
install see [SETUP.md](../SETUP.md); for the day-to-day cheat sheet skip to
section 4.

---

## 1. Quadlets — Podman ↔ systemd glue

Each pod is auto-started by a **Quadlet** unit (`*.kube`) that systemd reads
from `~/.config/containers/systemd/`. At boot, the systemd-quadlet generator
turns each `.kube` into a dynamic `<svc>.service` whose `ExecStart=` runs
`podman kube play` on the matching YAML under `kube_yaml/`.

The active dir is **not** the source of truth — it's populated from
[`quadlets/`](../quadlets/) by `bootstrap_quadlets()` in `manage.sh`. Edit
the repo copy, run `./manage.sh` → *Setup & Verify Quadlet Config*, and the
script installs any drifted file and runs `daemon-reload`.

If a pod crashes (e.g. Immich segfaults), systemd restarts the service
automatically. After a reboot every service starts in the right order with no
SSH login required.

### Boot ordering

`podman kube play` writes to a single sqlite state DB (`~/.local/share/
containers/storage/db.sql`). 12 pods racing into it at boot triggered
SIGKILLs at the systemd start timeout, leaving half-created pods and a
corrupted state DB (`pod ps`/`rm` then hang for minutes). Fix: every
`.kube` carries `After=<previous>.service`, serializing startup. Current
chain:

```
garage → caddy → ntfy → it-tools → portainer → uptime-kuma
       → homepage → site → fastfood → immich → firefly → firefly-importer
```

Each unit also has `TimeoutStartSec=300` to survive cold image pulls. See
[`quadlets/README.md`](../quadlets/README.md) for the conventions encoded
in every `.kube`.

### Trust zones

Two networks, joined only by Caddy:

| Network         | Subnet         | Pods                                                                 |
|-----------------|----------------|----------------------------------------------------------------------|
| `services_net`  | 10.89.0.0/24   | everything except the crown jewels (homepage, site, kuma, ntfy, …)   |
| `sensitive_net` | 10.89.2.0/24   | `firefly`, `firefly-importer`, `immich` only                         |

Pods on `services_net` cannot reach Firefly's MariaDB or Immich's Postgres.
`caddy` is the **only** multi-homed pod; it lives on both networks and
reverse-proxies into each. `homepage` stays on `services_net` only (its
Next.js server binds a single interface, so multi-homing would break Caddy's
inbound proxy) and reaches Immich via `host.containers.internal:2283`.

---

## 2. Roles: scripts vs systemd

| Layer       | Name           | Role                  | Use it for                                      |
|-------------|----------------|-----------------------|--------------------------------------------------|
| **systemd** | `*.service`    | autopilot             | keeping pods online 24/7, auto-restart on crash  |
| **script**  | `manage.sh`    | manual maintenance    | backup, update, cleanup, restore from S3         |

Caddy is managed exclusively by systemd to keep the reverse proxy always up
(the management script doesn't touch it during service updates).

---

## 3. Cheat sheet

Since pods are systemd user units, the everyday command is `systemctl --user`,
not `podman`.

```bash
# Status of all units
systemctl --user status

# One service (replace 'caddy' with immich, firefly, …)
systemctl --user status caddy

# Tail the live log
journalctl --user -fu caddy

# Restart a single service
systemctl --user restart immich

# Disable a service permanently
systemctl --user stop <svc>
systemctl --user disable <svc>
rm ~/.config/containers/systemd/<svc>.kube
systemctl --user daemon-reload
# Also: move kube_yaml/<svc>.pod.yaml to kube_yaml/disabled/ and
# remove the entry from SERVICES + PODS in manage.sh.
```

---

## 4. On-disk layout

| Path                                | Holds                                                                              |
|-------------------------------------|------------------------------------------------------------------------------------|
| `~/podman/kube_yaml/`               | pod definitions — *what* each pod looks like (images, ports, volumes)              |
| `~/podman/kube_yaml/disabled/`      | pods kept on disk but not started — see the README in there                        |
| `~/podman/quadlets/`                | source-of-truth `*.kube` and `*.network` files (versioned in git)                  |
| `~/.config/containers/systemd/`     | live copies installed by `bootstrap_quadlets()` — **do not edit here, edit `quadlets/`** |
| `~/podman/manage.sh`                | management script — backup, update, cleanup, restore. Interactive menu + `--flag` mode |
| `~/podman/.env`                     | host secrets (Garage S3 creds, ntfy token). chmod 600. gitignored                  |
| `~/podman/data/`                    | persistent application data — databases, photos, configs                           |
| `~/podman/backups/`                 | local backup dumps (rotated by `rotate_backups()`)                                 |
| `~/podman/state/`                   | runtime state (e.g. healthcheck flap-protection). Gitignored                       |
| `~/podman/logs/`                    | log files from cron scripts — size or time rotated per script                      |
| `~/podman/podman_secrets/`          | Kubernetes-format Secret YAMLs sourced by `create_secrets.sh`. Gitignored          |

---

## 5. Automated backups

`scripts/nightly_backup.sh` runs at **03:00** via cron (see [SETUP.md §8.3](../SETUP.md))
and wraps `./manage.sh --backup-all`. In order:

1. **Immich** — `pg_dumpall` + ML cache → `tar.gz` → upload to Garage S3
2. **Firefly III** — `mariadb-dump` + `storage/` → `tar.gz` → S3
3. **Uptime Kuma** — atomic SQLite snapshot (`.backup`) + rsync of data dir → `tar.gz` → S3. The snapshot avoids corrupt backups if Kuma is writing during the rsync; on restore prefer `kuma_snapshot.db` over `kuma.db`
4. **Portainer**, **ntfy**, **Caddy** — direct volume copy → `tar.gz` → S3

Disabled services (Metabase, Actual Budget) are out of the cycle; their data
under `data/<svc>/` is preserved but the pod is not started.

All heavy backup ops (`tar`, `gzip`, `rsync`) run under `nice -n 19 ionice -c2 -n7`
(variable `NICE_CMD`). On 2 cores the unniced nightly used to push load to ~6
and trip the Kuma load alert; low priority yields CPU/IO to foreground services.

### Weekly DB maintenance

Sundays at **04:30** `scripts/weekly_db_optimize.sh` invokes `./manage.sh --optimize-db`:

- Immich Postgres: `VACUUM ANALYZE` (reclaims space, refreshes planner stats)
- Firefly MariaDB: `mariadb-check --optimize` (InnoDB table defrag)

Log under `logs/db_optimize_<date>.log` (60-day retention).

### ntfy notifications

All cron scripts (`nightly_backup`, `weekly_db_optimize`, `healthcheck_monitor`)
push to topic `homelab-alerts` via `scripts/lib_notify.sh`:

- ✅ `white_check_mark` — completed
- ⚠️ `warning` — automatic recovery attempted (e.g. unhealthy container)
- 🚨 `rotating_light` — failure, manual intervention needed

Credentials in `.env` (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`). If missing the
scripts are silent no-ops.

### Healthcheck & auto-recovery

Critical pods (`firefly-app`, `firefly-importer`, `immich-app-server`) define
a `livenessProbe` in their pod YAML. `scripts/healthcheck_monitor.sh` runs
every **5 min** from cron:

1. Finds containers Podman marks `unhealthy`
2. Restarts the matching systemd service
3. Sends an ntfy alert
4. Flap protection (30 min): if the service is still unhealthy after a
   restart, emits the "manual intervention" alert and stops retrying

State for flap protection is in `state/healthcheck-last-state` (NOT in `logs/`).

### Restore wizard

`scripts/restore_wizard.sh`:

- `--verify <path>` — integrity-check a backup (tar.gz or directory) without restoring
- interactive — list local / on-VPS / Garage S3 backups, download if remote, show restore steps, and optionally extract files (the SQL restore step stays manual for safety)

### Inspecting backups

```bash
# Last night's log
cat ~/podman/logs/nightly_backup_$(date +%Y-%m-%d).log

# Remote backups on Garage S3
./manage.sh   # option 9 — Restore / Download from S3
```

---

## 6. Related repositories

Three independent Forgejo repos:

| Repo        | URL                                              | Holds                                  |
|-------------|--------------------------------------------------|----------------------------------------|
| **Homelab** | `forgejo.it/simonemiglio/Homelab`                | Infrastructure (this repo)             |
| **Website** | `forgejo.it/simonemiglio/Website`                | Portfolio source                       |
| **FastFood**| `forgejo.it/simonemiglio/FastFood`               | FastFood app source                    |

Website and FastFood are checked out as **subfolders** of `~/podman/`
(`site_sources/` and `FastFood/`) because `manage.sh` references their build
context as `./site_sources` / `./FastFood`. Both subfolders are gitignored by
the Homelab repo. See [SETUP.md Step 2](../SETUP.md) for the clone recipe.

Secrets are not in any of the three repos — after cloning, run
`scripts/create_secrets.sh` and follow [SETUP.md](../SETUP.md).
