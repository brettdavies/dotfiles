#!/usr/bin/env bash
# Reproducible Tailscale Serve config for bigdaddy.
#
# tailscaled keeps serve config in its own state, but a binding can be dropped
# by a daemon restart or version upgrade while the node's AdvertiseServices
# pref survives — leaving a service advertised with nothing bound (the VIP
# routes nowhere and peers time out). This script is the dotfiles source of
# truth so a fresh host, or a host that lost its binding, re-establishes the
# full serve config in one idempotent run.
#
# Two bindings:
#   - node serve:    https://bigdaddy.<tailnet>/ -> 127.0.0.1:18789  (openclaw gateway)
#   - service serve: https://ollama.<tailnet>/   -> 127.0.0.1:11500  (svc:ollama VIP)
#
# svc:ollama targets the loopback Caddy proxy on :11500, not Ollama's :11434
# directly: Ollama 403s any non-localhost Host header, and serve forwards the
# tailnet Host unchanged. Caddy rewrites Host to localhost (see stow/caddy/),
# keeping Ollama bound to 127.0.0.1 only.
#
# `tailscale serve --service=...` both advertises the node as the service host
# AND binds the proxy in one call — a separate `tailscale serve advertise` is
# only for un-draining, not for initialization. Re-running re-asserts the same
# config, so the script is safe to run repeatedly.
#
# Service-host approval is a one-time per-host action in the admin console and
# cannot be scripted here: https://login.tailscale.com/admin/services/svc:ollama
#
# Usage: bash scripts/tailscale-serve-setup.sh

set -euo pipefail

# This is bigdaddy's serve topology; other tailnet hosts run different services.
EXPECTED_HOST="bigdaddy"
if [ "$(hostname -s)" != "$EXPECTED_HOST" ]; then
  echo "NOTE: tailscale-serve-setup is ${EXPECTED_HOST}'s config; this host is $(hostname -s). Skipping." >&2
  exit 0
fi

if ! tailscale status >/dev/null 2>&1; then
  echo "ERROR: tailscale is not up. Run 'tailscale up' first." >&2
  exit 1
fi

OPENCLAW_TARGET="http://127.0.0.1:18789"
OLLAMA_TARGET="http://127.0.0.1:11500"

echo "==> node serve: https://${EXPECTED_HOST}.<tailnet>/ -> ${OPENCLAW_TARGET}"
tailscale serve --bg --https=443 --yes "${OPENCLAW_TARGET}"

# svc:ollama forwards to the loopback Caddy proxy; refuse to point the tailnet
# VIP at a dead upstream (Caddy down would silently break the served path).
if ! curl -sf -o /dev/null --max-time 3 "${OLLAMA_TARGET}/api/tags"; then
  echo "ERROR: ${OLLAMA_TARGET} not responding. Start the proxy first: systemctl --user enable --now caddy.service" >&2
  exit 1
fi

echo "==> service serve: svc:ollama -> ${OLLAMA_TARGET}"
tailscale serve --service=svc:ollama --https=443 --yes "${OLLAMA_TARGET}"

echo "==> serve status:"
tailscale serve status --json
