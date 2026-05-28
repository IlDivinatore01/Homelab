# Quadlets

Systemd-quadlet units that wire `kube_yaml/*.pod.yaml` into auto-starting user
services. Two file types:

- `*.network` — Podman network definitions (one quadlet unit per network).
- `*.kube` — one per service; tells systemd to `podman kube play` the matching
  YAML on boot, attached to the right network(s), at the right point in the
  boot chain.

## Source of truth, not the live copy

The active dir is `~/.config/containers/systemd/`. **This directory in the
repo is the source.** `manage.sh` → `bootstrap_quadlets()` copies any drifted
file from here into the active dir and runs `systemctl --user daemon-reload`.

Workflow when changing a unit:

1. Edit the file under `quadlets/`.
2. `./manage.sh` → menu option for "verify quadlets" (or call
   `bootstrap_quadlets` directly).
3. Restart the affected service: `systemctl --user restart <svc>.service`.

Live edits to `~/.config/containers/systemd/` are detected as drift and
**silently overwritten on the next bootstrap**. Don't.

## Conventions encoded in every `.kube`

### Boot ordering — serialized `After=` chain

At boot ~12 pods running `podman kube play` concurrently contend on Podman's
sqlite state DB; the losers get SIGKILLed at the systemd start timeout
mid-play, leaving half-created (wedged) pods and a corrupted state DB
(`pod ps`/`rm` then hang for minutes).

Mitigation: every `.kube` has `After=<previous>.service` so pods come up one
at a time. The current chain (matches the order in `SERVICES` in
`manage.sh`):

```
garage → caddy → ntfy → it-tools → portainer → uptime-kuma → homepage
       → site → fastfood → immich → firefly → firefly-importer
```

When adding a service, pick where to splice it in and update the `After=` on
its successor.

### Trust zones — `Network=` directives

- `services_net` (10.89.0.0/24) — general / less-trusted apps.
- `sensitive_net` (10.89.2.0/24) — Firefly (finances) and Immich (photos)
  only. Their DBs are NOT reachable from `services_net`.
- `caddy` is the **only** multi-homed pod
  (`Network=services_net.network` + `Network=sensitive_net.network`) — it
  bridges Caddy's reverse proxy into both zones.
- `homepage` stays on `services_net` only: its Next.js server binds a single
  interface, so multi-homing breaks Caddy's inbound proxy
  (see `[[project-network-segmentation-readonly]]` in the agent memory).

Always reference the network as `<name>.network` (the quadlet unit name), not
the bare `<name>` — the unit form makes quadlet add `Requires=`/`After=` on
the network service for robust boot ordering.

### `TimeoutStartSec=300`

Default is 90 s, which is too short for first-boot image pulls (Immich alone
is 1.4 GB) on a fresh checkout or after `podman system reset`. Five minutes
covers cold pulls without masking real hangs.

## Cheat sheet

```bash
# View / debug
systemctl --user list-unit-files '*.kube' '*.network'
journalctl --user -u <svc>.service -n 100
systemctl --user status <svc>.service

# Validate syntax without applying
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun

# Force a re-sync from the repo
./manage.sh   # menu → "verify quadlets"

# Restart after editing a *.kube
systemctl --user restart <svc>.service
```
