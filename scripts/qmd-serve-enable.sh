#!/usr/bin/env bash
# One-shot enable script for the qmd-serve low-vram daemon.
#
# Stops any orphan listener on :7832, reloads the user systemd manager,
# enables --now the service unit, and smoke-tests /health. Idempotent and
# safe to re-run.
#
# The unit ExecStart's %h/.local/bin/qmd, the stowed dispatcher that execs the
# fork for the running OS, so the daemon is invariant to PATH ordering and can
# never resolve the upstream qmd package.
#
# Usage: bash scripts/qmd-serve-enable.sh

set -euo pipefail

# --- Linux gate ---
if [ "$(uname -s)" != "Linux" ]; then
  echo "NOTE: qmd-serve is Linux-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

PORT=7832
SERVICE_UNIT="qmd-serve.service"

# --- Detect + stop any orphan listener on :PORT ---
port_listening() {
  ss -Htnl "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}\b"
}

if port_listening; then
  echo "==> Existing listener detected on :${PORT} — stopping before enable"

  # Preferred: stop via systemd if the service unit already owns it.
  systemctl --user stop "${SERVICE_UNIT}" 2>/dev/null || true

  # Fallback: SIGTERM any remaining ad-hoc qmd bun process.
  pkill -TERM -f 'bun .*qmd' 2>/dev/null || true
  pkill -TERM -f 'qmd serve' 2>/dev/null || true

  # Wait up to 5 s for the port to clear.
  for _ in $(seq 1 10); do
    if ! port_listening; then
      break
    fi
    sleep 0.5
  done

  if port_listening; then
    echo "ERROR: port :${PORT} still in use after 5 s — cannot enable" >&2
    echo "       Inspect:  ss -tnlp 'sport = :${PORT}'" >&2
    exit 1
  fi
fi

# --- Reload systemd user manager + enable the service unit ---
echo "==> systemctl --user daemon-reload"
systemctl --user daemon-reload

echo "==> systemctl --user enable --now ${SERVICE_UNIT}"
systemctl --user enable --now "${SERVICE_UNIT}"

# --- Smoke: /health ---
SMOKE_OUT=$(mktemp --suffix=.json)
trap 'rm -f "${SMOKE_OUT}"' EXIT

echo "==> Smoke: curl http://127.0.0.1:${PORT}/health"
if ! curl --silent --fail --max-time 30 \
  "http://127.0.0.1:${PORT}/health" -o "${SMOKE_OUT}"; then
  echo "ERROR: /health smoke failed within 30 s" >&2
  echo "       Likely causes:" >&2
  echo "         - ~/.local/bin/qmd missing (ExecStart path); deploy the stow package" >&2
  echo "             scripts/stow-deploy qmd" >&2
  echo "         - fork launcher ~/dev/qmd/qmd missing (clone brettdavies/qmd)" >&2
  echo "         - qmd-serve crashed during startup" >&2
  echo "" >&2
  echo "       Last service logs:" >&2
  journalctl --user -u "${SERVICE_UNIT}" --no-pager -n 20 >&2 || true
  exit 1
fi
echo "    $(cat "${SMOKE_OUT}")"

# --- Log tail for confirmation ---
echo ""
echo "==> Last 10 log lines for ${SERVICE_UNIT}:"
journalctl --user -u "${SERVICE_UNIT}" --no-pager -n 10 || true

echo ""
echo "NOTE: qmd-serve stays always-on (no idle-exit). Sequential mode keeps"
echo "      peak VRAM near 2.6 GB by loading one heavy model at a time."
