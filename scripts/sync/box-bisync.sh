#!/usr/bin/env bash
set -euo pipefail

# Bidirectional sync between Box:TX-AI and ~/box/TX-AI using rclone bisync.
# Intended to run on a 1-minute systemd timer. Lock files prevent overlap.
#
# First run requires: box-bisync.sh --resync
# Subsequent runs:    box-bisync.sh  (called by systemd timer)

REMOTE="box:TX-AI"
LOCAL="$HOME/box/TX-AI"
LOG_DIR="$HOME/.local/share/rclone/logs"
RCLONE="/home/linuxbrew/.linuxbrew/bin/rclone"

mkdir -p "$LOCAL" "$LOG_DIR"

BISYNC_ARGS=(
  "$LOCAL" "$REMOTE"
  --verbose
  --max-lock 5m            # auto-expire stale lock files after 5 minutes
  --resilient              # retry on transient errors instead of aborting
  --recover                # attempt to recover from prior interrupted sync
  --conflict-resolve newer # if both sides changed, keep the newer file
  --conflict-loser num     # rename the loser with a numeric suffix
  --log-file "$LOG_DIR/box-bisync.log"
  --filter-from "$HOME/.config/rclone/box-filters.txt"
)

# Pass --resync for initial sync (required on first run)
if [[ "${1:-}" == "--resync" ]]; then
  BISYNC_ARGS+=(--resync)
  echo "Performing initial resync..."
fi

exec "$RCLONE" bisync "${BISYNC_ARGS[@]}"
