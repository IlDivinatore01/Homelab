# 📘 SERVER ARCHITECTURE WIKI
**Data di aggiornamento:** Maggio 2026
**Autore:** Osvaldo & Gemini

Questo documento spiega l'architettura **"Self-Healing"** (auto-riparante) del server.
Il sistema è progettato per avviarsi automaticamente, riavviare i servizi in caso di crash e gestire gli aggiornamenti in sicurezza.

---

## 1. Come funziona: I "Quadlets"
Il cuore del sistema non sono più semplici comandi manuali, ma i **Quadlets**.

I Quadlets sono file di configurazione che agiscono da "ponte" tra **Podman** (i container) e **Systemd** (il gestore dei servizi di Linux).

### Il Flusso di Avvio:
1.  **Boot:** Il server si accende.
2.  **Systemd Generator:** Linux legge la cartella "magica":
    `~/.config/containers/systemd/*.kube`
3.  **Service Creation:** Per ogni file `.kube` trovato, crea dinamicamente un servizio (es. `immich.service`).
4.  **Auto-Start:** Il servizio esegue il comando `podman kube play`, leggendo i tuoi file YAML originali in `~/podman/kube_yaml/`.

> **Perché è importante?**
> Se un'app crasha (es. Immich si blocca), Systemd se ne accorge e la **riavvia immediatamente**. Se riavvii il server, tutto riparte in automatico senza bisogno di login SSH.

---

## 2. Ruoli: Script vs Systemd
Abbiamo separato la gestione quotidiana dalla manutenzione straordinaria.

| Componente | Nome | Ruolo (Analogia) | Funzione |
| :--- | :--- | :--- | :--- |
| **Systemd** | `*.service` | **Il Pilota Automatico** | Mantiene i siti online 24/7. Gestisce l'avvio e il riavvio automatico (es. Caddy). |
| **Script** | `manage_finale.sh` | **Il Meccanico** | Si usa solo quando serve: per fare Backup, Aggiornamenti software o Pulizia del disco. |

**Nota su Caddy:**
Caddy (il Reverse Proxy) è gestito **esclusivamente** da Systemd per garantire che sia sempre attivo. Non viene toccato dallo script di aggiornamento per evitare conflitti di rete.

---

## 3. Comandi Utili (Cheat Sheet)

Poiché ora i container sono gestiti come servizi di sistema, il comando principale non è più `podman`, ma `systemctl` (nella modalità utente).

### 🟢 Controllare lo stato generale
Vedere la lista di tutti i servizi attivi e se stanno girando correttamente:
```bash
systemctl --user status
```

### 🔍 Controllare un servizio specifico
Vedere i dettagli di una singola applicazione (es. Caddy o Immich):
```bash
systemctl --user status caddy
```
*(Sostituisci `caddy` con il nome del servizio che ti interessa, es. `immich`, `firefly`, `metabase`, etc.)*

### 📜 Leggere i LOG in tempo reale
Se un sito non carica o dà errore, questo comando mostra i log in diretta (come un tail):
```bash
journalctl --user -f -u caddy
```
*(Premi `Ctrl+C` per uscire)*

### 🔄 Riavviare manualmente un servizio
Se vuoi forzare il riavvio di un container senza usare lo script di gestione:
```bash
systemctl --user restart immich
```

### 🛑 Disattivare un servizio per sempre
Procedura per rimuovere un'applicazione dall'avvio automatico (come fatto per AppFlowy):

1. **Fermare il servizio attivo:**
   ```bash
   systemctl --user stop nome_servizio
   ```
2. **Disabilitare l'avvio automatico:**
   ```bash
   systemctl --user disable nome_servizio
   ```
3. **Cancellare il file Quadlet (l'interruttore):**
   ```bash
   rm ~/.config/containers/systemd/nome_servizio.kube
   ```
4. **Aggiornare Systemd per applicare le modifiche:**
   ```bash
   systemctl --user daemon-reload
   ```

---

## 4. Struttura delle Cartelle e File

Ecco dove si trovano i pezzi fondamentali del tuo server:

* **`~/podman/kube_yaml/`**
  📂 **Le Ricette (YAML)**
  Qui risiedono i file che definiscono *COME* sono fatti i pod (immagini, porte, volumi). È qui che modifichi la configurazione dei container.

* **`~/.config/containers/systemd/`**
  ⚙️ **Gli Interruttori (Quadlets)**
  Qui risiedono i file `.kube`. Questi file dicono a Linux di avviare automaticamente le ricette YAML al boot.

* **`~/podman/manage_finale.sh`**
  🛠️ **Il Pannello di Controllo**
  Lo script principale per eseguire backup, aggiornamenti, pulizia e manutenzione ordinaria.
  Supporta sia il menu interattivo (avvio senza argomenti) sia una modalità non-interattiva
  pensata per cron/script: `--backup-all`, `--backup <servizio>`, `--restart <servizio>`, `--help`.

* **`~/podman/.env`**
  🔑 **Variabili d'ambiente segrete (gitignored)**
  Contiene le credenziali Garage S3 usate dagli script di backup. Permessi `600`.
  Esiste come template in `.env.example` — copiare e compilare al primo setup.

* **`~/podman/data/`**
  💾 **I Dati Persistenti**
  Dove risiedono fisicamente i file dei tuoi siti, i database e le foto.
  Include anche i dati di Metabase (database H2 per dashboard e query salvate).

* **`~/podman/backups/`**
  📦 **I Backup**
  Dove vengono salvati i dump dei database e i file compressi generati dallo script `manage_finale.sh`.
  Rotazione locale: 3 backup per servizio. Rotazione remota su Garage S3: 5 backup per servizio.

---

## 5. Backup Automatici

I backup notturni partono via cron alle **03:00**, eseguendo lo script
`scripts/nightly_backup.sh`, che a sua volta invoca:

```bash
./manage_finale.sh --backup-all
```

La modalità `--backup-all` (non-interattiva) esegue in sequenza:

1. **Immich** — `pg_dumpall` di Postgres + ML cache → `tar.gz` → upload su Garage S3.
2. **Firefly III** — `mariadb-dump` + cartella `storage/` → `tar.gz` → S3.
3. **Uptime Kuma** — snapshot atomico SQLite (`.backup`) + rsync del data dir → `tar.gz` → S3. Lo snapshot evita backup corrotti se Kuma sta scrivendo durante il rsync; al restore preferire `kuma_snapshot.db` a `kuma.db`.
4. **Portainer**, **ntfy** — copia diretta dei volumi dati → `tar.gz` → S3.

> Servizi dismessi (Metabase, Actual Budget) non sono nel ciclo; i loro dati
> restano in `data/<servizio>/` ma il container non viene avviato.

### Manutenzione DB settimanale

Ogni **domenica alle 04:30** parte `scripts/weekly_db_optimize.sh` (cron) che
invoca `./manage_finale.sh --optimize-db`:

- **Immich Postgres**: `VACUUM ANALYZE` (libera spazio, ricalcola le statistiche del planner)
- **Firefly MariaDB**: `mariadb-check --optimize` (defrag tabelle InnoDB)

Il log finisce in `logs/db_optimize_<data>.log` (rotazione: ultimi 60 giorni).

### Notifiche ntfy

Tutti gli script di cron (`nightly_backup`, `weekly_db_optimize`, `healthcheck_monitor`)
emettono una notifica push sul topic `homelab-alerts` via `scripts/lib_notify.sh`:

- ✅ tag `white_check_mark` → operazione completata
- ⚠️ tag `warning` → recovery automatico tentato (es. container unhealthy)
- 🚨 tag `rotating_light` → fallimento, intervento manuale richiesto

Le credenziali sono in `.env` (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`). Se mancano,
gli script restano silenti (no-op).

### Healthcheck e auto-recovery

I pod critici (`firefly-app`, `firefly-importer`, `immich-app-server`) hanno
un `livenessProbe` nei rispettivi `*.pod.yaml`. Lo script
`scripts/healthcheck_monitor.sh` gira **ogni 5 minuti** da cron:

1. cerca container marcati `unhealthy`
2. riavvia il servizio systemd corrispondente
3. invia un alert ntfy
4. ha **flap protection** (30 min): se lo stesso servizio è ancora unhealthy
   dopo un restart, manda l'alert "intervento manuale" senza retry continui

### Restore wizard

`scripts/restore_wizard.sh` può:

- **`--verify <path>`**: verifica integrity di un backup (tar.gz o directory) senza ripristinare nulla
- **interactive mode**: lista i backup locali / on-VPS / Garage S3, scarica se da S3, mostra le istruzioni di restore, ed eventualmente esegue il restore file (lo step SQL resta manuale per sicurezza)

> ⚠️ **Nota storica**
> Fino a maggio 2026 il nightly invocava il menu interattivo via heredoc
> (`./manage_finale.sh <<< "4"`), causando un falso fallimento perché `set -e`
> nello script principale terminava male alla chiusura di stdin. Il fix è la
> modalità `--backup-all` introdotta in questa revisione.

### Controllare i backup

```bash
# Log dell'ultima notte
cat ~/podman/logs/nightly_backup_$(date +%Y-%m-%d).log

# Backup remoti su Garage S3
./manage_finale.sh   # opzione 9 — Restore / Download from S3
```

---

## 6. Repository Git

Il progetto è diviso in **3 repository indipendenti** su Forgejo:

| Repository | URL | Contenuto |
| :--- | :--- | :--- |
| **Homelab** | `forgejo.it/simonemiglio/Homelab` | Configurazioni infrastruttura, script, Quadlets |
| **Website** | `forgejo.it/simonemiglio/Website` | Codice sorgente del portfolio personale |
| **FastFood** | `forgejo.it/simonemiglio/FastFood` | Codice sorgente dell'app FastFood |

### Clonare tutto da zero:
```bash
git clone https://forgejo.it/simonemiglio/Homelab.git ~/podman
cd ~/podman
git clone https://forgejo.it/simonemiglio/Website.git site_sources
git clone https://forgejo.it/simonemiglio/FastFood.git FastFood
```

> **Nota:** I segreti (password, chiavi API) non sono nei repository. Dopo il clone, esegui `scripts/create_secrets.sh` e segui `SETUP.md`.
