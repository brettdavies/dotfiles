#!/usr/bin/env bash
# One-shot enable + migration script for the opendataloader-pdf socket unit.
#
# Stops any orphan ad-hoc hybrid server on :5002, reloads the user systemd
# manager, enables --now the socket unit, and smoke-tests /health via the
# first socket-activated start. Idempotent and safe to re-run.
#
# Usage: bash scripts/opendataloader-pdf-enable.sh

set -euo pipefail

# --- Linux gate ---
if [ "$(uname -s)" != "Linux" ]; then
  echo "NOTE: opendataloader-pdf is Linux-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

PORT=5002
SOCKET_UNIT="opendataloader-pdf.socket"
SERVICE_UNIT="opendataloader-pdf.service"

# --- Detect + stop any orphan listener on :PORT ---
port_listening() {
  ss -Htnl "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}\b"
}

if port_listening; then
  echo "==> Existing listener detected on :${PORT} — stopping before enable"

  # Preferred: stop via systemd if the service unit already owns it.
  systemctl --user stop "${SERVICE_UNIT}" 2>/dev/null || true

  # Fallback: SIGTERM any remaining opendataloader-pdf-hybrid process.
  pkill -TERM -f 'opendataloader-pdf-hybrid' 2>/dev/null || true

  # Wait up to 5 s for the port to clear.
  for _ in $(seq 1 10); do
    if ! port_listening; then
      break
    fi
    sleep 0.5
  done

  if port_listening; then
    echo "ERROR: port :${PORT} still in use after 5 s — cannot enable socket" >&2
    echo "       Inspect:  ss -tnlp 'sport = :${PORT}'" >&2
    exit 1
  fi
fi

# --- Reload systemd user manager + enable the socket unit ---
echo "==> systemctl --user daemon-reload"
systemctl --user daemon-reload

echo "==> systemctl --user enable --now ${SOCKET_UNIT}"
systemctl --user enable --now "${SOCKET_UNIT}"

# --- Smoke: first connect triggers cold start ---
SMOKE_OUT=$(mktemp --suffix=.json)
trap 'rm -f "${SMOKE_OUT}"' EXIT

echo "==> Smoke: curl http://127.0.0.1:${PORT}/health (cold start ~3–5 s)"
if ! curl --silent --fail --max-time 30 \
     "http://127.0.0.1:${PORT}/health" -o "${SMOKE_OUT}"; then
  echo "ERROR: /health smoke failed within 30 s" >&2
  echo "       Most likely cause: the uv-tool install is missing." >&2
  echo "       Run the setup helper first:" >&2
  echo "         ~/.claude/skills/markdown-convert/skills/mc-pdf/mc-pdf-setup.sh" >&2
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
echo "NOTE: socket unit is enabled at login. Service idle-exits after 60 s"
echo "      with no requests and re-activates on next connect."
