#!/usr/bin/env bash
# Checks that the vault's agent-workspace mirror to the NAS has succeeded within the last three hours.
# vault-agent-sync.service runs the mirror hourly and logs each success to the sync log, and vault-agent-sync-check.timer
# runs this check at five past each hour. Every run prints one line, which the unit appends to its own log. A stall also
# goes to stderr, which the unit sends to the journal at err priority, and exits 1: the unit then stays failed until a
# run finds a recent success, and the failed-user-units.sh hook names failed user units at the start of every Claude
# session, on screen and to Claude.
#
# Usage: vault-agent-sync-check.sh
# VAULT_SYNC_LOG names the sync log to read (default ~/.openclaw/logs/sync-pool.log).
set -euo pipefail

log=${VAULT_SYNC_LOG:-$HOME/.openclaw/logs/sync-pool.log}
max_age_s=$((3 * 3600))
now=$(date +%s)
stamp=$(date -d "@$now" '+%Y-%m-%d %H:%M:%S')

stalled() {
  printf '[%s] %s\n' "$stamp" "$1"
  printf 'vault-agent-sync-check: %s; see %s\n' "$1" "$log" >&2
  exit 1
}

last=$({ sed -n 's/^\[\([0-9-]\{10\} [0-9:]\{8\}\)\] .*Sync completed successfully.*/\1/p' "$log" 2>/dev/null || true; } | tail -n 1)
[ -n "$last" ] || stalled "ERROR: no successful sync found in the sync log"
last_s=$(date -d "$last" +%s)
age_h=$(((now - last_s) / 3600))
[ $((now - last_s)) -le "$max_age_s" ] || stalled "ALERT: last successful sync was ${age_h}h ago ($last)"
printf '[%s] OK: Last sync %s (%sh ago)\n' "$stamp" "$last" "$age_h"
