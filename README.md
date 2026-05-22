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
| **Metabase** | No longer used. Data preserved in `data/metabase/`. To re-enable: rename `kube_yaml/metabase.pod.yaml.disabilitato` and re-add to `manage_finale.sh`. |
| **Actual Budget** | No longer used. Data preserved in `data/actual/`. Same re-enable procedure. |

---

## 🚀 Quick Start

> **Full setup guide:** See [SETUP.md](SETUP.md) for complete instructions.

### Prerequisites

- Ubuntu 24.04 LTS (or similar)
- 2+ vCPU, 4+ GB RAM
- Domain with DNS access

### Step 1: Clone Repositories

This setup uses **3 independent repositories**:

```bash
cd ~

# Infrastructure (required)
git clone https://forgejo.it/simonemiglio/Homelab.git podman
cd podman

# Portfolio source (if needed)
git clone https://forgejo.it/simonemiglio/Website.git site_sources

# FastFood source (if needed)
git clone https://forgejo.it/simonemiglio/FastFood.git FastFood
```

### Step 2: Create Secrets

```bash
./scripts/create_secrets.sh
```

### Step 3: Configure environment file

```bash
cp .env.example .env
chmod 600 .env
# Fill in GARAGE_S3_ACCESS_KEY / GARAGE_S3_SECRET_KEY (see SETUP.md §3.2)
```

### Step 4: Configure Caddy

```bash
cp config_examples/Caddyfile.example data/caddy/Caddyfile
# Edit with your domain
```

### Step 5: Start Services

```bash
./manage_finale.sh
# Select option 1, then 'a' for all
```

---

## 🏗️ Architecture

```
Internet (HTTPS)
       │
       ▼
┌─────────────────────────────────────────────┐
│  Caddy (Port 80/443)                        │
│  Reverse Proxy + Auto HTTPS                 │
└─────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│  services_net (Podman Network)              │
│                                             │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │Homepage │ │ Immich  │ │Firefly  │       │
│  │   Pod   │ │   Pod   │ │   Pod   │       │
│  └─────────┘ └─────────┘ └─────────┘       │
│                                             │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │Metabase │ │FastFood │ │ Uptime  │       │
│  │   Pod   │ │   Pod   │ │  Kuma   │       │
│  └─────────┘ └─────────┘ └─────────┘       │
│                                             │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │IT-Tools │ │ Garage  │ │  ntfy   │       │
│  │   Pod   │ │   Pod   │ │   Pod   │       │
│  └─────────┘ └─────────┘ └─────────┘       │
└─────────────────────────────────────────────┘
```

### Key Concepts

| Component | Purpose |
|-----------|---------|
| **Rootless Podman** | Containers run as user, not root |
| **Quadlets** | Systemd integration for auto-start |
| **Caddy** | Automatic HTTPS with Let's Encrypt |
| **services_net** | Internal DNS between pods |

---

## 📁 Project Structure

```
podman/
├── kube_yaml/               # Pod definitions
│   ├── caddy.pod.yaml
│   ├── homepage.pod.yaml
│   ├── site.pod.yaml        # Portfolio website
│   ├── immich.pod.yaml
│   ├── firefly.pod.yaml
│   ├── firefly-importer.pod.yaml  # Bank data importer
│   ├── metabase.pod.yaml    # Financial analytics dashboard
│   ├── actual.pod.yaml      # Actual Budget
│   ├── fastfood.pod.yaml
│   ├── uptime-kuma.pod.yaml
│   ├── portainer.pod.yaml
│   ├── garage.pod.yaml      # Gitignored (contains auth hash)
│   ├── ntfy.pod.yaml          # Push notification server
│   └── it-tools.pod.yaml
│
├── config_examples/         # Configuration templates
│   ├── Caddyfile.example
│   ├── garage.pod.yaml.example
│   └── services.yaml.example
│
├── scripts/                 # Utility scripts
│   ├── create_secrets.sh    # Idempotent Podman + k8s secrets setup
│   ├── nightly_backup.sh    # Automated nightly backups (cron 03:00)
│   ├── weekly_db_optimize.sh    # VACUUM + mariadb-check (cron Sun 04:30)
│   ├── healthcheck_monitor.sh   # Watches livenessProbe state (cron */5)
│   ├── lib_notify.sh        # Tiny ntfy helper sourced by the cron scripts
│   ├── restore_wizard.sh    # Restore from local/S3 + --verify dry-run
│   ├── setup_permission_fix.sh  # Fix volume permissions after reboot
│   ├── setup_fail2ban.sh    # SSH brute-force protection (one-shot)
│   ├── setup_fail2ban_caddy.sh  # fail2ban jail for Caddy logins (one-shot, sudo)
│   ├── fail2ban/            # filter+jail files installed by the script above
│   └── setup_cockpit.sh     # Install Cockpit web UI
│
├── logs/                    # Backup logs (auto-created)
│
├── docs/                    # Additional documentation
│   ├── ARCHITETTURA.md      # Architecture (Italian)
│   └── metabase_queries.md  # SQL queries for Metabase dashboards
│
├── manage_finale.sh         # Main management script
├── .env                     # Gitignored - host secrets (S3 creds, etc.)
├── .env.example             # Template for .env
├── README.md                # This file
└── SETUP.md                 # Full setup guide
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
./manage_finale.sh
```

Options:
1. Start/Restart Services
2. Update Services (with Pull & Backup)
3. Stop Services
4. Backup Immich (DB dump → cloud sync)
5. Backup Firefly (DB + data → cloud sync)
6. Backup Metabase (H2 DB → cloud sync)
7. Backup System Tools (Kuma/Portainer)
8. List Backups
9. Restore / Download from S3
10. Full System Cleanup
11. Setup & Verify Quadlet Config
12. Restart Caddy Proxy
13. Optimize Databases

### Non-Interactive Mode (cron / scripts)

```bash
./manage_finale.sh --backup-all            # Backup every tracked service
./manage_finale.sh --backup immich         # Backup a single service
./manage_finale.sh --restart firefly       # Restart a service
./manage_finale.sh --optimize-db           # VACUUM Postgres + mariadb-check
./manage_finale.sh --help                  # Show usage
```

`scripts/nightly_backup.sh` runs `--backup-all` daily at 03:00.
`scripts/weekly_db_optimize.sh` runs `--optimize-db` every Sunday at 04:30.

### Automated Schedule

| When | What | Script |
|------|------|--------|
| Every 5 min | Disk-usage heartbeats to Uptime Kuma | `/usr/local/bin/kuma_disk_push.sh` |
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

### Permission Errors

```bash
# Run the permission fix
./scripts/setup_permission_fix.sh

# Or manually:
sudo chown -R $USER:$USER /mnt/HC_Volume_*/podman-root
```

### 502 Bad Gateway

```bash
# Check if pod is running
podman pod ps

# Restart Caddy
systemctl --user restart caddy.service

# Check network DNS
podman exec caddy-pod-caddy getent hosts <pod-name>
```

### Service Won't Start

```bash
# Check systemd logs
journalctl --user -u <service>.service -n 50

# Check container logs
podman logs <container-name>
```

### After Reboot Issues

The `fix-podman-permissions.service` runs automatically. If issues persist:

```bash
./scripts/setup_permission_fix.sh
```

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [SETUP.md](SETUP.md) | Complete setup guide |
| [docs/ARCHITETTURA.md](docs/ARCHITETTURA.md) | Architecture details (Italian) |

---

## 📄 License

MIT License

---

**Created by [Simone Miglio](https://simonemiglio.eu)** 🇮🇹
