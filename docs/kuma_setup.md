# 📡 Uptime Kuma — Advanced setup

Checklist that takes Kuma from "a few basic monitors" to a complete setup
with ntfy, SSL-expiry alerts, tag-based grouping on the public status page,
and system push checks.

Everything below is done through the UI: <https://status.simonemiglio.eu>.

---

## 1. Add the missing monitors

| Name | Type | URL | Interval | Notes |
|---|---|---|---|---|
| Garage WebUI | HTTP(s) | `https://garage.simonemiglio.eu` | 60s | |
| IT Tools | HTTP(s) | `https://tools.simonemiglio.eu` | 60s | |
| ntfy | HTTP(s) | `https://notify.simonemiglio.eu/v1/health` | 60s | native health endpoint |
| FastFood | HTTP(s) | `https://fastfood.simonemiglio.eu` | 60s | |
| Cockpit | HTTP(s) | `https://panel.simonemiglio.eu` | 120s | **Tick** "Ignore TLS error" (self-signed) |

For every new monitor expand **Advanced** and set:

- ✅ **Certificate Expiry Notification** (Kuma warns 21 / 14 / 7 days before expiry)
- ✅ **Authentication: None**
- **Retries:** `2`
- **Heartbeat Retry Interval:** `60s`

> Do the same for the **6 pre-existing monitors** (Portfolio, Immich, Firefly,
> Importer, Homepage, Portainer): open each in edit mode and tick "Certificate
> Expiry Notification". No need to touch the URL.

---

## 2. Add ntfy as a notification channel

**Settings → Notifications → Setup Notification**:

| Field | Value |
|---|---|
| Notification Type | `Ntfy` |
| Friendly Name | `ntfy homelab-alerts` |
| ntfy Topic | `homelab-alerts` |
| Server URL | `https://notify.simonemiglio.eu` |
| Priority | `Default (3)` |
| Authentication Method | `Access Token` |
| Access Token | paste `NTFY_TOKEN` from `.env` (`tk_...`) |
| **Default enabled** | ✅ (so it auto-applies to new monitors) |
| **Apply on all existing monitors** | ✅ (one-time, applies to the 9 existing monitors) |

→ **Save**. Keep Telegram around as a redundant alert channel.

Quick test: in the provider row click **Test** → a notification should land on
your phone.

---

## 3. Create the tags

**Settings → Tags → New Tag** (4 tags):

| Name | Colour |
|---|---|
| `frontend` | `#10b981` (green) |
| `backend`  | `#3b82f6` (blue) |
| `infra`    | `#f59e0b` (amber) |
| `system`   | `#8b5cf6` (purple) |

Then assign tags to monitors (open each monitor → **Tags** → add):

| Tag | Monitors |
|---|---|
| `frontend` | Portfolio, FastFood, Homepage |
| `backend`  | Firefly III, Firefly Importer, Immich, json-query Immich |
| `infra`    | Portainer, Caddy (if added), Cockpit, IT Tools, Garage WebUI |
| `system`   | ntfy, Disk /, Disk /mnt/HC_*, Memory %, Load 5min (the 2 push monitors from §5) |

---

## 4. Restructure the public status page

**Status Pages → Status Services → Edit**:

- **Title:** `Homelab Status`
- **Description:** `Self-hosted services status`
- **Footer Text:** `Powered by Uptime Kuma`
- **Theme:** Dark
- ✅ **Show certificate expiry**
- ✅ **Show powered by** (optional)

**Add a Group** per tag:

1. `🌐 Frontend` → select monitors tagged `frontend`
2. `⚙️ Backend` → tag `backend`
3. `🛠️ Infrastructure` → tag `infra`
4. `📊 System` → tag `system`

**Save** → the public page at `https://status.simonemiglio.eu/status` now
shows services grouped by category.

---

## 5. Push checks: memory + load average

Create **2 Push-type monitors** in Kuma:

| Name | Type | Heartbeat Interval | Retries | Tag |
|---|---|---|---|---|
| `Memory %`  | Push | `600s` | `1` | `system` |
| `Load 5min` | Push | `600s` | `1` | `system` |

> ⚠️ **Set Heartbeat Interval to 600 s even though the cron runs every 5 min
> (300 s).** When the Kuma window equals the cron period, cron jitter (a beat
> arriving at 302 s instead of 300 s) trips false "No heartbeat in the time
> window" alarms. With a 600 s window you need **two** missed pushes in a row
> to alert — false positives disappear and a real outage is still caught in
> ~10 min. Apply the same fix to the 2 pre-existing disk push monitors.

For each monitor Kuma generates an URL like:

```
https://status.simonemiglio.eu/api/push/<TOKEN>?status=up&msg=OK&ping=
```

Copy both URLs and add them to crontab:

```bash
crontab -e
```

Add (replace `<TOKEN_MEM>` and `<TOKEN_LOAD>` with the real ones):

```cron
# Uptime Kuma — memory push (warn 80 %, crit 95 %)
*/5 * * * * /home/osvaldo/podman/scripts/kuma_system_push.sh mem 80 95 "https://status.simonemiglio.eu/api/push/<TOKEN_MEM>"

# Uptime Kuma — load 5min push (warn 200 = load 2.0, crit 400 = load 4.0 — 2 cores)
*/5 * * * * /home/osvaldo/podman/scripts/kuma_system_push.sh load 200 400 "https://status.simonemiglio.eu/api/push/<TOKEN_LOAD>"
```

`scripts/kuma_system_push.sh` emits the value in the `ping=` field so Kuma
graphs it over time. WARN thresholds keep `status=up`; CRIT thresholds send
`status=down` → triggers notifications.

Manual test before adding to cron:

```bash
./scripts/kuma_system_push.sh mem  80 95  "https://status.simonemiglio.eu/api/push/<TOKEN_MEM>"
./scripts/kuma_system_push.sh load 200 400 "https://status.simonemiglio.eu/api/push/<TOKEN_LOAD>"
```

→ After ~5 s the Kuma monitor turns green with the current value.

---

## 6. Final verification

```bash
# Total active monitors
podman exec uptime-kuma-pod-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT COUNT(*) FROM monitor WHERE active=1"
# Expected: 16 (9 pre-existing + 5 new HTTP + 2 push)

# Notifications assigned per monitor
podman exec uptime-kuma-pod-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT m.name, n.name FROM monitor m
   JOIN monitor_notification mn ON mn.monitor_id=m.id
   JOIN notification n ON n.id=mn.notification_id
   ORDER BY m.name"
# Every monitor should appear with both Telegram and ntfy.
```

---

## 7. Robust backup (already automated)

`manage.sh` takes an **atomic SQLite snapshot** (`.backup`) before rsyncing
the data dir. This prevents corrupt backups when Kuma is writing during the
nightly run. Nothing to do on the user side — it's active on the next run of
`--backup-all` or `--backup uptime-kuma`.

Verify on the first run:

```bash
./manage.sh --backup uptime-kuma
# Look for "Snapshot created." in the log
ls -la backups/uptime-kuma_backup_*/data/kuma_snapshot.db
```

The `kuma_snapshot.db` file inside the backup is the atomic copy — use it for
restore instead of `kuma.db` if the latter ends up corrupted.
