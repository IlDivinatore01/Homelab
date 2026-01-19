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
| **Immich** | gallery.simonemiglio.eu | Photo management |
| **Firefly III** | finanza.simonemiglio.eu | Finance tracker |
| **FastFood** | fastfood.simonemiglio.eu | Demo app |
| **Uptime Kuma** | status.simonemiglio.eu | Monitoring |
| **IT-Tools** | tools.simonemiglio.eu | Developer utilities |
| **Portainer** | portainer.simonemiglio.eu | Container UI |
| **Cockpit** | panel.simonemiglio.eu | System admin |

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

### Step 3: Configure

```bash
cp config_examples/Caddyfile.example data/caddy/Caddyfile
# Edit with your domain
```

### Step 4: Start Services

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
│  │FastFood │ │ Uptime  │ │IT-Tools │       │
│  │   Pod   │ │  Kuma   │ │   Pod   │       │
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
│   ├── immich.pod.yaml
│   ├── firefly.pod.yaml
│   ├── fastfood.pod.yaml
│   ├── uptime-kuma.pod.yaml
│   ├── portainer.pod.yaml
│   └── it-tools.pod.yaml
│
├── config_examples/         # Configuration templates
│   ├── Caddyfile.example
│   └── services.yaml.example
│
├── scripts/                 # Utility scripts
│   ├── create_secrets.sh    # Interactive secrets setup
│   ├── nightly_backup.sh    # Automated nightly backups (cron)
│   ├── setup_permission_fix.sh
│   ├── setup_fail2ban.sh
│   └── setup_cockpit.sh
│
├── logs/                    # Backup logs (auto-created)
│
├── docs/                    # Additional documentation
│   └── ARCHITETTURA.md      # Architecture (Italian)
│
├── manage_finale.sh         # Main management script
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
6. Backup System Tools (Kuma/Portainer)
7. List Backups
8. Full System Cleanup
9. Setup & Verify Quadlet Config
10. Restart Caddy Proxy
11. Optimize Databases

### Automated Backups

Nightly backups run automatically at **3:00 AM** via cron:

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
| **Fail2Ban** | SSH brute-force protection |
| **Headers** | HSTS, CSP, X-Frame-Options |

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
