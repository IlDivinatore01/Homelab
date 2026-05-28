# 📡 Uptime Kuma — Setup avanzato

Checklist per portare Kuma da "qualche monitor base" a un sistema completo con
ntfy, SSL expiry, tag, status page raggruppata e push checks di sistema.

Tutto quello che segue si fa dalla UI: <https://status.simonemiglio.eu>.

---

## 1. Aggiungere i monitor mancanti

| Nome | Type | URL | Interval | Note |
|---|---|---|---|---|
| Garage WebUI | HTTP(s) | `https://garage.simonemiglio.eu` | 60s | |
| IT Tools | HTTP(s) | `https://tools.simonemiglio.eu` | 60s | |
| ntfy | HTTP(s) | `https://notify.simonemiglio.eu/v1/health` | 60s | endpoint health nativo |
| FastFood | HTTP(s) | `https://fastfood.simonemiglio.eu` | 60s | |
| Cockpit | HTTP(s) | `https://panel.simonemiglio.eu` | 120s | **Spuntare** "Ignore TLS error" (self-signed) |

Per ogni nuovo monitor, espandi **Advanced** e:

- ✅ **Certificate Expiry Notification** (Kuma avvisa 21 / 14 / 7 giorni prima della scadenza)
- ✅ **Authentication: None**
- **Retries**: `2`
- **Heartbeat Retry Interval**: `60s`

> Stessa cosa va fatta **anche sui 6 monitor esistenti** (Portfolio, Immich, Firefly, Importer, Homepage, Portainer): aprili in modifica e spunta "Certificate Expiry Notification". Non serve toccare l'URL.

---

## 2. Aggiungere ntfy come notifica

**Settings → Notifications → Setup Notification**:

| Campo | Valore |
|---|---|
| Notification Type | `Ntfy` |
| Friendly Name | `ntfy homelab-alerts` |
| ntfy Topic | `homelab-alerts` |
| Server URL | `https://notify.simonemiglio.eu` |
| Priority | `Default (3)` |
| Authentication Method | `Access Token` |
| Access Token | (incolla `NTFY_TOKEN` dal `.env` — `tk_...`) |
| **Default enabled** | ✅ (spunta — così si applica ai monitor nuovi automaticamente) |
| **Apply on all existing monitors** | ✅ (spunta una volta — applica anche ai 9 monitor già presenti) |

→ **Save**. Tieni anche Telegram come canale di backup, ridondanza nelle alert.

Test rapido: dalla riga del provider clicca **Test** → arriva una notifica sul tuo telefono.

---

## 3. Creare i tag

**Settings → Tags → New Tag** (4 tag):

| Nome | Colore |
|---|---|
| `frontend` | `#10b981` (verde) |
| `backend` | `#3b82f6` (blu) |
| `infra` | `#f59e0b` (ambra) |
| `sistema` | `#8b5cf6` (viola) |

Poi assegna ai monitor (apri ogni monitor → **Tags** → aggiungi):

| Tag | Monitor |
|---|---|
| `frontend` | Portfolio, FastFood, Homepage |
| `backend` | Firefly III, Firefly Importer, Immich, json-query Immich |
| `infra` | Portainer, Caddy (se aggiunto), Cockpit, IT Tools, Garage WebUI |
| `sistema` | ntfy, Disk /, Disk /mnt/HC_*, Memory %, Load 5min (i 2 push li crei al §5) |

---

## 4. Ristrutturare la status page

**Status Pages → Status Services → Edit**:

- **Title**: `Homelab Status`
- **Description**: `Stato dei servizi self-hosted`
- **Footer Text**: `Powered by Uptime Kuma`
- **Theme**: Dark
- ✅ **Show certificate expiry**
- ✅ **Show powered by** (a piacere)

**Add a Group** per ogni tag:

1. `🌐 Frontend` → seleziona monitor con tag `frontend`
2. `⚙️ Backend` → tag `backend`
3. `🛠️ Infrastruttura` → tag `infra`
4. `📊 Sistema` → tag `sistema`

**Save** → la pagina pubblica `https://status.simonemiglio.eu/status` ora mostra i servizi raggruppati per categoria.

---

## 5. Push checks: memoria + load average

In Kuma crea **2 monitor di tipo Push**:

| Nome | Type | Heartbeat Interval | Retries | Tag |
|---|---|---|---|---|
| `Memory %` | Push | `600s` | `1` | `sistema` |
| `Load 5min` | Push | `600s` | `1` | `sistema` |

> ⚠️ **Heartbeat Interval va impostato a 600s anche se il cron gira ogni 5 min (300s).**
> Se la finestra Kuma = periodo del cron, il jitter del cron (un beat che arriva
> a 302s invece di 300s) fa scattare falsi "No heartbeat in the time window".
> Con finestra 600s servono **due** push saltati di fila per un vero allarme —
> i falsi spariscono e una vera interruzione viene comunque rilevata in ~10 min.
> Stessa cosa vale per i 2 push disk esistenti (portali a 600s).

Per ognuno, Kuma genera un URL del tipo:

```
https://status.simonemiglio.eu/api/push/<TOKEN>?status=up&msg=OK&ping=
```

Copia i due URL e aggiungili al crontab:

```bash
crontab -e
```

Aggiungi (sostituendo i `<TOKEN>` con quelli reali):

```cron
# Uptime Kuma — push memoria (warn 80%, crit 95%)
*/5 * * * * /home/osvaldo/podman/scripts/kuma_system_push.sh mem 80 95 "https://status.simonemiglio.eu/api/push/<TOKEN_MEM>"

# Uptime Kuma — push load 5min (warn 200 = load 2.0, crit 400 = load 4.0 — 2 core)
*/5 * * * * /home/osvaldo/podman/scripts/kuma_system_push.sh load 200 400 "https://status.simonemiglio.eu/api/push/<TOKEN_LOAD>"
```

Lo script `scripts/kuma_system_push.sh` (già nel repo) emette il valore nel campo `ping=` così Kuma lo grafica nel tempo. Soglie WARN passano il messaggio ma lasciano `status=up`; soglie CRIT mandano `status=down` → trigger notifiche.

Test manuale prima di aggiungere a cron:

```bash
./scripts/kuma_system_push.sh mem  80 95 "https://status.simonemiglio.eu/api/push/<TOKEN_MEM>"
./scripts/kuma_system_push.sh load 200 400 "https://status.simonemiglio.eu/api/push/<TOKEN_LOAD>"
```

→ Dopo 5 secondi il monitor in Kuma deve diventare verde con il valore corrente.

---

## 6. Verifica finale

```bash
# Quanti monitor attivi totali
podman exec uptime-kuma-pod-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT COUNT(*) FROM monitor WHERE active=1"
# Atteso: 16 (9 esistenti + 5 HTTP nuovi + 2 push)

# Verifica notifiche assegnate
podman exec uptime-kuma-pod-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT m.name, n.name FROM monitor m
   JOIN monitor_notification mn ON mn.monitor_id=m.id
   JOIN notification n ON n.id=mn.notification_id
   ORDER BY m.name"
# Ogni monitor deve comparire con Telegram + ntfy.
```

---

## 7. Backup robusto (già automatico)

`manage.sh` ora prende un **snapshot atomico SQLite** (`.backup`) prima
del rsync del data dir. Questo evita backup corrotti se Kuma sta scrivendo
mentre parte il backup notturno. Niente da fare lato utente — è già attivo dal
prossimo run di `--backup-all` o `--backup uptime-kuma`.

Verifica al primo run:

```bash
./manage.sh --backup uptime-kuma
# Cerca "Snapshot created." nel log
ls -la backups/uptime-kuma_backup_*/data/kuma_snapshot.db
```

Il file `kuma_snapshot.db` dentro il backup è la copia atomica — usala per il
restore al posto di `kuma.db` se quest'ultima dovesse essere corrotta.
