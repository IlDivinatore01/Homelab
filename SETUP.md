# 🚀 Homelab Setup Guide

This guide walks you through setting up the complete homelab infrastructure after cloning this repository.

## Prerequisites

- **OS:** Ubuntu 24.04 LTS (or similar)
- **Hardware:** 2+ vCPU, 4+ GB RAM, 40+ GB storage
- **Domain:** A domain with DNS access
- **External Services:**
  - MongoDB Atlas account (free tier works)
  - Hetzner Storage Box (optional, for backups)

---

## 📋 Step 1: Install System Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Podman (rootless container runtime)
sudo apt install -y podman podman-compose

# Install additional tools
sudo apt install -y cockpit cockpit-podman fail2ban rclone git

# Enable user linger (allows services to run after logout)
sudo loginctl enable-linger $USER
```

---

## 📁 Step 2: Clone Repositories

This setup uses **3 independent Git repositories**:

| Repo | Purpose | Required? |
|------|---------|-----------|
| **Homelab** | Infrastructure configs, scripts | ✅ Yes |
| **Website** | Portfolio source code | Only if hosting portfolio |
| **FastFood** | FastFood app source | Only if hosting FastFood |

### Clone All Repositories

```bash
cd ~

# 1. Clone infrastructure (required)
git clone https://forgejo.it/simonemiglio/Homelab.git podman
cd podman

# 2. Clone website source (if needed)
git clone https://forgejo.it/simonemiglio/Website.git site_sources

# 3. Clone FastFood source (if needed)
git clone https://forgejo.it/simonemiglio/FastFood.git FastFood
```

> **Note:** Each repo is independent. You can run FastFood standalone without Homelab by following its own README.

---

## 🔐 Step 3: Create Secrets

### 3.1 Podman secrets (for containers)

Run the interactive secrets creation script:

```bash
chmod +x scripts/create_secrets.sh
./scripts/create_secrets.sh
```

You'll need to provide:
| Secret | How to Get It |
|--------|---------------|
| `fastfood-mongo-uri` | Create cluster at [MongoDB Atlas](https://cloud.mongodb.com) |
| `fastfood-jwt-secret` | Run: `openssl rand -hex 32` |
| `immich-db-password` | Choose a strong password |
| `firefly-app-key` | Run: `openssl rand -base64 32` |
| `firefly-db-password` | Choose a strong password |

### 3.2 Host environment file (for backup scripts)

The management script reads `.env` for the Garage S3 backup credentials so they
are never committed to git:

```bash
cp .env.example .env
chmod 600 .env
nano .env   # Fill in GARAGE_S3_ACCESS_KEY and GARAGE_S3_SECRET_KEY
```

The Garage access/secret pair is generated after Step 8b.3 (`garage key create backup-key`).

---

## ⚙️ Step 4: Configure Services

### 4.1 Create Data Directories

```bash
mkdir -p data/{caddy,homepage/config,immich,firefly,metabase,actual,uptime-kuma,portainer,fastfood,it-tools,ntfy/{config,cache,data}}
mkdir -p backups
```

### 4.2 Copy Example Configs

```bash
# Caddy reverse proxy
cp config_examples/Caddyfile.example data/caddy/Caddyfile

# Homepage dashboard
cp config_examples/services.yaml.example data/homepage/config/services.yaml
```

### 4.3 Create Homepage Secrets (for Immich widget)

```bash
# Create the secret file
cat > podman_secrets/homepage_immich_key.secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: homepage-immich-key-k8s
type: Opaque
stringData:
  apikey: YOUR_IMMICH_API_KEY
EOF

# Apply the secret
podman kube play podman_secrets/homepage_immich_key.secret.yaml
```

> **Note:** Get the Immich API key from Immich → User Settings → API Keys after first run.

### 4.4 Edit Configs

Replace `yourdomain.com` with your actual domain in:

```bash
# Edit Caddyfile
nano data/caddy/Caddyfile

# Edit Homepage services
nano data/homepage/config/services.yaml
```

**Find and replace:**
```
yourdomain.com → your-actual-domain.com
```

---

## 🌐 Step 5: Configure DNS

Add these A records pointing to your server IP:

| Subdomain | Type | Value |
|-----------|------|-------|
| `@` | A | `YOUR_SERVER_IP` |
| `www` | A | `YOUR_SERVER_IP` |
| `home` | A | `YOUR_SERVER_IP` |
| `gallery` | A | `YOUR_SERVER_IP` |
| `finanza` | A | `YOUR_SERVER_IP` |
| `importer.finanza` | A | `YOUR_SERVER_IP` |
| `fastfood` | A | `YOUR_SERVER_IP` |
| `status` | A | `YOUR_SERVER_IP` |
| `tools` | A | `YOUR_SERVER_IP` |
| `panel` | A | `YOUR_SERVER_IP` |
| `portainer` | A | `YOUR_SERVER_IP` |
| `analytics` | A | `YOUR_SERVER_IP` |
| `s3` | A | `YOUR_SERVER_IP` |
| `garage` | A | `YOUR_SERVER_IP` |
| `notify` | A | `YOUR_SERVER_IP` |

---

## 🔧 Step 6: Install Quadlet Services

```bash
# Create systemd user directory
mkdir -p ~/.config/containers/systemd

# Copy Quadlet files (if you have them)
# Or they should be in ~/.config/containers/systemd/ already

# Reload systemd
systemctl --user daemon-reload

# Enable permission fix service
./setup_permission_fix.sh
```

---

## 🚀 Step 7: Start Services

```bash
# Start all services
./manage_finale.sh
# Select option 1, then 'a' for all
```

Or start individually:

```bash
systemctl --user start caddy.service
systemctl --user start homepage.service
systemctl --user start immich.service
# ... etc
```

---

## ☁️ Step 8: Configure Backups (Optional)

### 8.1 Setup Rclone for Hetzner Storage Box

```bash
# Configure rclone
rclone config

# Create new remote:
# - Name: hetzner
# - Type: sftp
# - Host: uXXXXXX.your-storagebox.de
# - User: uXXXXXX
# - Password: your-password
```

### 8.2 Test Backup

```bash
# Interactive (manual run, picks one service)
./manage_finale.sh
# Select option 4 (Backup Immich) to test

# Or non-interactive (single service)
./manage_finale.sh --backup immich

# Or non-interactive (all services, what cron uses)
./manage_finale.sh --backup-all
```

### 8.3 Setup Cron Jobs

```bash
crontab -e
```

Add:

```cron
# Container healthcheck monitor: restart unhealthy pods + ntfy alert
*/5 * * * * /home/osvaldo/podman/scripts/healthcheck_monitor.sh

# Daily backup at 03:00 — covers all live services
0 3 * * * /home/osvaldo/podman/scripts/nightly_backup.sh

# Weekly DB maintenance Sunday 04:30
30 4 * * 0 /home/osvaldo/podman/scripts/weekly_db_optimize.sh
```

The `nightly_backup.sh` and `weekly_db_optimize.sh` wrappers use the
non-interactive `--backup-all` / `--optimize-db` modes of `manage_finale.sh`
(an older version piped `"4\n"` into the interactive menu, which caused cron
to always report failure even when the backup actually succeeded).

---

## 🗄️ Step 8b: Configure Garage S3 (Optional)

Garage provides S3-compatible storage using your Hetzner Storage Box.

### 8b.1 Setup Garage

```bash
# Copy example config
cp config_examples/garage.pod.yaml.example kube_yaml/garage.pod.yaml

# Generate WebUI authentication hash
sudo apt install -y apache2-utils
htpasswd -nbBC 10 "admin" "YOUR_PASSWORD"

# Edit garage.pod.yaml and replace AUTH_USER_PASS value with the generated hash
nano kube_yaml/garage.pod.yaml
```

### 8b.2 Start Garage

```bash
systemctl --user daemon-reload
systemctl --user start garage.service
```

### 8b.3 Initialize Cluster

```bash
# Get node ID
podman exec garage-pod-garage /garage status

# Assign layout (replace NODE_ID)
podman exec garage-pod-garage /garage layout assign -z dc1 -c 1T NODE_ID
podman exec garage-pod-garage /garage layout apply --version 1

# Create buckets
podman exec garage-pod-garage /garage bucket create backups
podman exec garage-pod-garage /garage key create backup-key
podman exec garage-pod-garage /garage bucket allow --read --write --owner backups --key backup-key
```

### 8b.4 Access

- **S3 API**: https://s3.yourdomain.com
- **WebUI**: https://garage.yourdomain.com

---

## ✅ Step 9: Verify Installation

### Check Services

```bash
# All pods should be "Running"
podman pod ps

# All containers should be "Up"
podman ps
```

### Check Websites

Open in browser:
- https://home.yourdomain.com (Dashboard)
- https://gallery.yourdomain.com (Immich)
- https://finanza.yourdomain.com (Firefly)
- https://status.yourdomain.com (Uptime Kuma)

---

## 🔒 Step 10: Security Hardening

### Enable Fail2Ban (SSH)

```bash
sudo ./scripts/setup_fail2ban.sh
# or manually:
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

### Enable Fail2Ban (Caddy)

After Caddy is running and writing to `data/caddy/log/access.log`:

```bash
sudo ./scripts/setup_fail2ban_caddy.sh
sudo fail2ban-client status caddy-auth
```

This jail bans IPs that get more than 5 HTTP 401/403 responses in 10 minutes
(typical brute-force pattern against Firefly/Immich/Portainer login pages).

### Pre-commit hook

The repo ships with a hook that blocks `.env`/`*.key` commits and runs
`shellcheck` on staged shell scripts. Activate it once after cloning:

```bash
git config core.hooksPath .githooks
# Install shellcheck for full linting (optional):
sudo apt install shellcheck
```

### Configure Firewall (Optional)

```bash
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw enable
```

---

## 📊 Post-Setup Tasks

1. **Get Immich API Key:**
   - Go to https://gallery.yourdomain.com
   - Create admin account
   - Settings → API Keys → Create
   - Update `data/homepage/config/services.yaml`

2. **Configure Uptime Kuma:**
   - Go to https://status.yourdomain.com
   - Create admin account
   - Add monitors for all services

3. **Setup Portainer:**
   - Go to https://portainer.yourdomain.com
   - Create admin account
   - Add local Podman socket endpoint

---

## 🆘 Troubleshooting

### Permission Errors
```bash
sudo chown -R $USER:$USER /mnt/HC_Volume_*/podman-root
sudo chown -R $USER:$USER /run/user/$(id -u)/containers
```

### 502 Bad Gateway
```bash
# Check if pod is running
podman pod ps

# Restart Caddy
systemctl --user restart caddy.service

# Check DNS resolution
podman exec caddy-pod-caddy getent hosts <pod-name>
```

### Service Won't Start
```bash
# Check logs
journalctl --user -u <service>.service -n 50
podman logs <container-name>
```

---

## 📚 Additional Resources

- [Podman Documentation](https://docs.podman.io)
- [Caddy Documentation](https://caddyserver.com/docs)
- [Immich Documentation](https://immich.app/docs)
- [Firefly III Documentation](https://docs.firefly-iii.org)

---

*Happy self-hosting! 🏠*
