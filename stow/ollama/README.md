# `ollama` stow package

Owns the ollama systemd service override drop-in. Binds ollama to loopback only (`127.0.0.1:11434`) so it is reachable
from:

- Anything running on this host's loopback (the
  [tailscale `svc:ollama` serve forwarder](https://login.tailscale.com/admin/services/svc:ollama), local CLI scripts,
  any docker-compose stack that runs a host-network socat sidecar bridging the docker bridge gateway to
  127.0.0.1:11434).

…and NOT reachable from:

- The tailnet interface directly (peers must go through the `svc:ollama` HTTPS service).
- The LAN.
- Docker containers via `host.docker.internal` unless a host-side socat forwarder bridges the docker bridge gateway to
  loopback.

## Why this lives in dotfiles

Per `~/.claude/CLAUDE.md`: machine-level systemd units live under `~/dotfiles/` and deploy via stow rather than one-off
`sudo` writes into `/etc/`. The override target is `/etc/`, not `~/`, so the stow target differs from every other
package in this repo — it's stowed manually with `sudo` rather than picked up by `scripts/stow-deploy`.

## Package layout

```text
stow/ollama/
├── .stow-local-ignore   # excludes README.md from being stowed into /etc/
├── README.md
└── systemd/system/ollama.service.d/override.conf
```

Package contents mirror `/etc/` exactly (no `etc/` prefix), so `sudo stow -t /etc` writes the symlink at
`/etc/systemd/system/ollama.service.d/override.conf`.

## Deploy

First time (replace the existing override with a stowed symlink):

```bash
# 1. Snapshot the current override in case you want to roll back.
sudo cp /etc/systemd/system/ollama.service.d/override.conf \
        /etc/systemd/system/ollama.service.d/override.conf.bak

# 2. Remove the real file so stow can symlink in its place.
sudo rm /etc/systemd/system/ollama.service.d/override.conf

# 3. Stow the package into /etc.
cd ~/dotfiles && sudo stow -t /etc -d stow ollama

# 4. Reload systemd + restart ollama, then confirm the bind.
sudo systemctl daemon-reload
sudo systemctl restart ollama
ss -tlnp | grep 11434
# Expected: only `127.0.0.1:11434` and `[::1]:11434`, no `*:11434`.
```

After deploy, edits to `override.conf` in this package take effect via:

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

## Verify reachability

```bash
# From the host itself (loopback):
curl -s http://127.0.0.1:11434/api/tags | jq -r '.models[].name'

# From the tailnet (via the svc:ollama HTTPS service):
curl -s "https://ollama.${TAILNET}.ts.net/api/tags" | jq -r '.models[].name'

# From a docker container with extra_hosts:host-gateway, only if a
# host-side socat forwarder is running on the bridge gateway:port 11434.
```

## Undo

```bash
cd ~/dotfiles && sudo stow -t /etc -d stow -D ollama
sudo cp /etc/systemd/system/ollama.service.d/override.conf.bak \
        /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama
```
