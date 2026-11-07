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
# Bindings:
#   - service serve: https://ollama.<tailnet>/       -> 127.0.0.1:11500  (svc:ollama VIP)
#   - service serve: https://codex-proxy.<tailnet>/  -> 127.0.0.1:8080   (svc:codex-proxy VIP)
#   - service serve: https://openseo.<tailnet>/      -> 127.0.0.1:8946   (svc:openseo VIP, only while this host runs OpenSEO)
#
# svc:ollama targets the loopback Caddy proxy on :11500, not Ollama's :11434
# directly: Ollama 403s any non-localhost Host header, and serve forwards the
# tailnet Host unchanged. Caddy rewrites Host to localhost (see stow/caddy/),
# keeping Ollama bound to 127.0.0.1 only.
#
# svc:codex-proxy targets the codex-proxy OpenAI-compat endpoint on :8080
# directly — no Caddy shim. Unlike Ollama, codex-proxy accepts any Host header,
# so serve forwards the tailnet Host unchanged. The endpoint stays bound to
# 127.0.0.1 (docker maps 127.0.0.1:8080); inbound is gated by the tailnet ACL
# plus the LITELLM_API_KEY bearer the proxy requires on completions.
#
# `tailscale serve --service=...` both advertises the node as the service host
# AND binds the proxy in one call — a separate `tailscale serve advertise` is
# only for un-draining, not for initialization. Re-running re-asserts the same
# config, so the script is safe to run repeatedly.
#
# Service-host approval is a one-time per-host action in the admin console and
# cannot be scripted here (one per service):
#   https://login.tailscale.com/admin/services/svc:ollama
#   https://login.tailscale.com/admin/services/svc:codex-proxy
#   https://login.tailscale.com/admin/services/svc:openseo
#
# scripts/tailscale-serve-deploy.sh installs a unit that runs this on every
# tailscaled start.
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

OLLAMA_TARGET="http://127.0.0.1:11500"
CODEX_TARGET="http://127.0.0.1:8080"

# svc:ollama forwards to the loopback Caddy proxy; refuse to point the tailnet
# VIP at a dead upstream (Caddy down would silently break the served path).
if ! curl -sf -o /dev/null --max-time 3 "${OLLAMA_TARGET}/api/tags"; then
  echo "ERROR: ${OLLAMA_TARGET} not responding. Start the proxy first: systemctl --user enable --now caddy.service" >&2
  exit 1
fi

echo "==> service serve: svc:ollama -> ${OLLAMA_TARGET}"
tailscale serve --service=svc:ollama --https=443 --yes "${OLLAMA_TARGET}"

# svc:codex-proxy forwards straight to the loopback codex-proxy endpoint; refuse
# to point the tailnet VIP at a dead upstream (/health needs no bearer).
if ! curl -sf -o /dev/null --max-time 3 "${CODEX_TARGET}/health"; then
  echo "ERROR: ${CODEX_TARGET} not responding. Start it first: systemctl --user start codex-proxy.service" >&2
  exit 1
fi

echo "==> service serve: svc:codex-proxy -> ${CODEX_TARGET}"
tailscale serve --service=svc:codex-proxy --https=443 --yes "${CODEX_TARGET}"

# svc:openseo binds only on the host that runs OpenSEO (its env file exists), through the bind gate in
# scripts/openseo/lib/gate.sh. This block runs last, so an unhealthy OpenSEO fails the unit after the other bindings are in
# place. jq lives under Homebrew, which the unit's PATH lacks.
OPENSEO_BREW_BIN="${OPENSEO_BREW_BIN:-/home/linuxbrew/.linuxbrew/bin}"
PATH="$OPENSEO_BREW_BIN:$PATH"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/openseo/lib/gate.sh"
# shellcheck disable=SC2034 # gate.sh reads it
OS_CURL_MAX=3
OPENSEO_DEPLOY="$HOME/dotfiles/scripts/openseo-deploy.sh"

if [ ! -f "$OS_LOCAL_ENV" ]; then
  echo "NOTE: $OS_ENV_SHOWN is absent, so this host does not run OpenSEO. Skipping $OS_SERVICE." >&2
else
  os_gate || true
  case "$OS_GATE" in
    ok)
      echo "==> service serve: $OS_SERVICE -> $OS_LOOPBACK"
      os_publish || {
        echo "ERROR: $OS_SERVICE did not bind, or the control plane does not list this host for it. Run: $OPENSEO_DEPLOY serve" >&2
        exit 1
      }
      ;;
    first-account-open)
      echo "NOTE: OpenSEO has no account yet, so $OS_SERVICE stays unbound. Run: $OPENSEO_DEPLOY create-admin" >&2
      ;;
    unbind-failed)
      echo "ERROR: OpenSEO has no account yet and turning off the $OS_SERVICE binding failed. Run: tailscale serve --service=$OS_SERVICE --https=443 off" >&2
      exit 1
      ;;
    *)
      echo "ERROR: $OS_LOOPBACK/api/health is not ok. Start OpenSEO first: $OPENSEO_DEPLOY up" >&2
      exit 1
      ;;
  esac
fi

echo "==> serve status:"
tailscale serve status --json
