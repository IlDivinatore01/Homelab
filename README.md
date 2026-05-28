# 🏠 Homelab Infrastructure

Self-hosted infrastructure running on Podman with Systemd Quadlet integration.

[![Podman](https://img.shields.io/badge/Podman-4.9-892CA0?logo=podman)](https://podman.io/)
[![Caddy](https://img.shields.io/badge/Caddy-2-1F88C0?logo=caddy)](https://caddyserver.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu)](https://ubuntu.com/)

**Dashboard:** [home.simonemiglio.eu](https://home.simonemiglio.eu)

> 📌 **Primary Repository:** [Forgejo](https://forgejo.it/simonemiglio/Homelab)  
> 🪞 **Mirrors:** [GitHub](https://github.com/IlDivinatore01/Homelab) • [GitLab](https://gitlab.com/simonemiglio/Homelab) • [Codeberg](https://codeberg.org/simonemiglio/Homelab)

---

## 📋 Table of Contents

- [Services](#-services)
- [Quick Start](#-quick-start)
- [Architecture](#-architecture)
- [Project Structure](#-project-structure)
- [Management](#-management)
- [Troubleshooting](#-troubleshooting)

---

## 🌐 Services

| Service | Domain | Description |
|---------|--------|-------------|
| **Homepage** | home.simonemiglio.eu | Dashboard |
| **Portfolio** | simonemiglio.eu | Personal website |
| **Immich** | gallery.simonemiglio.eu | Photo management |
| **Firefly III** | finanza.simonemiglio.eu | Finance tracker |
| **Firefly Importer** | importer.finanza.simonemiglio.eu | Bank data import |
| **FastFood** | fastfood.simonemiglio.eu | Demo app |
| **Uptime Kuma** | status.simonemiglio.eu | Monitoring |
| **IT-Tools** | tools.simonemiglio.eu | Developer utilities |
| **Portainer** | portainer.simonemiglio.eu | Container UI |
| **Cockpit** | panel.simonemiglio.eu | System admin |
| **Garage S3** | s3.simonemiglio.eu | S3-compatible storage |
| **Garage WebUI** | garage.simonemiglio.eu | S3 admin interface |
| **ntfy** | notify.simonemiglio.eu | Push notifications |

### Disabled (kept on disk, not auto-started)

| Service | Reason |
|---------|--------|
| **Metabase** | No longer used. Pod YAML in `kube_yaml/disabled/`. Data preserved in `data/metabase/`. See [kube_yaml/disabled/README.md](kube_yaml/disabled/README.md) for the re-enable recipe. |
| **Actual Budget** | No longer used. Pod YAML in `kube_yaml/disabled/`. Data preserved in `data/actual/`. |
| **Immich Machine Learning** | Sub-container commented out in `kube_yaml/immich.pod.yaml` to free ~170MB RAM (Smart Search / Faces / OCR unused). Image + model cache kept on disk. Re-enable: uncomment the block + restart + flip the ML toggles in Immich admin UI. |

---

## 🚀 Quick Start

First-time install: follow [SETUP.md](SETUP.md) end-to-end. The short
version:

```bash
git clone https://forgejo.it/simonemiglio/Homelab.git ~/podman
cd ~/podman
./scripts/create_secrets.sh        # podman secrets
cp .env.example .env && chmod 600 .env  # host env (S3, ntfy)
cp config_examples/Caddyfile.example data/caddy/Caddyfile
./manage.sh                        # option 11 (verify quadlets) → 1 (start)
```

Website and FastFood live in sibling subfolders (`site_sources/` and
`FastFood/`) — see [SETUP.md Step 2](SETUP.md).

---

## 🏗️ Architecture

```
                       Internet (HTTPS)
                              │
                              ▼
                ┌──────────────────────────┐
                │   Caddy  (80 / 443)      │  reverse proxy + auto-HTTPS
                └────────┬───────────┬─────┘    (only pod multi-homed)
                         │           │
              services_net│           │sensitive_net
              10.89.0.0/24│           │10.89.2.0/24
                         ▼           ▼
        ┌────────────────────┐  ┌────────────────────┐
        │ homepage, site,    │  │ firefly,           │
        │ uptime-kuma, ntfy, │  │ firefly-importer,  │
        │ portainer, garage, │  │ immich             │
        │ it-tools, fastfood │  │ (data crown jewels)│
        └────────────────────┘  └────────────────────┘
```

Pods on `services_net` cannot reach the DBs on `sensitive_net` — Caddy is the
only bridge. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the boot
chain, Quadlets and conventions.

### Key concepts

| Component         | Purpose                                                                  |
|-------------------|--------------------------------------------------------------------------|
| Rootless Podman   | Containers run as the `osvaldo` user, never root                         |
| Quadlets          | systemd integration — every pod is a `<svc>.service` (auto-restart, boot ordering) |
| Caddy             | Single reverse proxy, automatic Let's Encrypt certs, bridges trust zones |
| Two-zone network  | `services_net` (general) + `sensitive_net` (Firefly + Immich)            |

---

## 📁 Project Structure

```
podman/
├── kube_yaml/               # Pod definitions (one *.pod.yaml per service)
│   └── disabled/            # Pods kept on disk but not started
├── quadlets/                # Source-of-truth *.kube / *.network units
│                            #   (installed into ~/.config/containers/systemd/
│                            #    by manage.sh → bootstrap_quadlets)
├── config_examples/         # Caddyfile + homepage services.yaml templates
├── podman_secrets/          # K8s Secret YAMLs for create_secrets.sh (gitignored)
├── scripts/                 # cron-driven ops (see Management section below)
├── data/                    # persistent app data (gitignored)
├── backups/                 # local backup dumps, rotated per service (gitignored)
├── logs/                    # cron script logs, rotated per script (gitignored)
├── state/                   # runtime state (e.g. healthcheck flap protection) (gitignored)
├── docs/
│   ├── ARCHITECTURE.md      # How it runs at boot and runtime
│   ├── kuma_setup.md        # Uptime Kuma monitor / push / ntfy setup
│   └── metabase_queries.md  # SQL for Metabase dashboards (service disabled)
├── manage.sh                # Main management script (menu + --flag mode)
├── README.md                # This file
└── SETUP.md                 # First-install guide
```

### Related Repositories

| Repository | Content |
|------------|---------|
| [Website](https://forgejo.it/simonemiglio/Website) | Portfolio source code |
| [FastFood](https://forgejo.it/simonemiglio/FastFood) | FastFood app source |

---

## 🔧 Management

### Interactive Menu

```bash
./manage.sh
```

Options:
1. Start/Restart Services
2. Update Services (with Pull & Backup)
3. Stop Services
4. Backup Immich (DB dump → cloud sync)
5. Backup Firefly (DB + data → cloud sync)
7. Backup System Tools (Kuma/Portainer/ntfy/Caddy)
8. List Backups
9. Restore / Download from S3
10. Full System Cleanup
11. Setup & Verify Quadlet Config
12. Restart Caddy Proxy
13. Optimize Databases

### Non-Interactive Mode (cron / scripts)

```bash
./manage.sh --backup-all            # Backup every tracked service
./manage.sh --backup immich         # Backup a single service
./manage.sh --restart firefly       # Restart a service
./manage.sh --optimize-db           # VACUUM Postgres + mariadb-check
./manage.sh --help                  # Show usage
```

`scripts/nightly_backup.sh` runs `--backup-all` daily at 03:00.
`scripts/weekly_db_optimize.sh` runs `--optimize-db` every Sunday at 04:30.

### Automated Schedule

| When | What | Script |
|------|------|--------|
| Every 5 min | Disk/memory/load heartbeats to Uptime Kuma (see [docs/kuma_setup.md](docs/kuma_setup.md)) | `scripts/kuma_system_push.sh` + legacy `kuma_disk_push.sh` |
| Every 5 min | Restart any container whose livenessProbe is failing, push an ntfy alert | `scripts/healthcheck_monitor.sh` |
| Daily 03:00 | Backup of Immich, Firefly, ntfy, Portainer, Uptime-Kuma, Caddy → Garage S3 | `scripts/nightly_backup.sh` |
| Sunday 04:30 | `VACUUM ANALYZE` on Immich Postgres + `mariadb-check --optimize` on Firefly | `scripts/weekly_db_optimize.sh` |

All cron scripts emit an ntfy notification (success or failure) on the
`homelab-alerts` topic when `NTFY_TOKEN` is set in `.env`.

```bash
# Check nightly backup logs
cat ~/podman/logs/nightly_backup_$(date +%Y-%m-%d).log

# View cron jobs
crontab -l
```

### Direct Commands

```bash
# Check all pods
podman pod ps

# Check all containers
podman ps

# Restart a service
systemctl --user restart immich.service

# View logs
journalctl --user -u caddy.service -f
```

### Common Tasks

| Task | Command |
|------|---------|
| Restart Caddy | `systemctl --user restart caddy.service` |
| Check status | `podman pod ps` |
| View logs | `podman logs <container-name>` |
| Clean up | `podman system prune -a` |

---

## 🔒 Security

| Feature | Implementation |
|---------|----------------|
| **HTTPS** | Caddy + Let's Encrypt (auto) |
| **Rootless** | All containers run as user |
| **Fail2Ban (SSH)** | scripts/setup_fail2ban.sh |
| **Fail2Ban (Caddy)** | scripts/setup_fail2ban_caddy.sh — bans IPs producing 401/403 on the public sites |
| **Headers** | HSTS, CSP, X-Frame-Options |
| **livenessProbe** | Firefly, Immich, Importer auto-restarted on hang via cron monitor |
| **Pre-commit hook** | `.githooks/pre-commit` blocks `.env`/`*.key` and runs shellcheck |

---

## 🆘 Troubleshooting

Full troubleshooting recipes (permissions, 502, won't-start) live in
[SETUP.md → Troubleshooting](SETUP.md#-troubleshooting). Quick pointers:

```bash
# Pod / container state
podman pod ps && podman ps

# Service logs
journalctl --user -u <svc>.service -n 50
podman logs <container>

# Permission fix after a reboot
./scripts/setup_permission_fix.sh
```

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [SETUP.md](SETUP.md) | First-install guide (deps, DNS, secrets, backups, security) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the system runs at boot and runtime (Quadlets, networks, backups) |
| [docs/kuma_setup.md](docs/kuma_setup.md) | Uptime Kuma advanced setup — monitors, push checks, ntfy notifications |
| [quadlets/README.md](quadlets/README.md) | Conventions encoded in every `.kube` (boot chain, trust zones, timeouts) |
| [kube_yaml/disabled/README.md](kube_yaml/disabled/README.md) | Re-enable recipe for shelved services |

---

## 📄 License

MIT License

---

**Created by [Simone Miglio](https://simonemiglio.eu)** 🇮🇹
