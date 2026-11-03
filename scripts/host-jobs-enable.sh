#!/usr/bin/env bash
# One-shot enable script for the Linux server's scheduled jobs and long-running user services. The timers run the vault
# agent-workspace mirror and its health check, the OpenClaw settings backup, the GitHub stars sync, the daily brew and
# uv tool upgrades, the automatic agent slot sweep, and the minute pass that keeps agent slot tabs matched to the
# slots. The services keep the account's Rex server running with no client connected.
#
# The units ship in the shared `obsidian` and `local` packages and carry ConditionHost=bigdaddy, so a deploy on any
# other host leaves them inert. This script enables them on that host and retires the crontab lines the timers replace.
#
# The stars sync authenticates with a read-only GitHub token that the units load from ~/.config/github-stars/env. When
# that file is missing, this script writes it from 1Password through the 1password skill's read_field.sh; without
# either, the sync falls back to the gh login. Idempotent and safe to re-run.
#
# Usage: bash scripts/host-jobs-enable.sh

set -euo pipefail

# --- Linux gate ---
if [ "$(uname -s)" != "Linux" ]; then
  echo "NOTE: host jobs are Linux-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

# --- Host gate ---
EXPECTED_HOST="bigdaddy"
if [ "$(hostname -s)" != "$EXPECTED_HOST" ]; then
  echo "NOTE: these are ${EXPECTED_HOST}'s scheduled jobs; this host is $(hostname -s). Skipping." >&2
  exit 0
fi

TIMERS=(
  vault-agent-sync.timer
  vault-agent-sync-check.timer
  openclaw-settings-backup.timer
  github-stars.timer
  github-stars-clone.timer
  brew-upgrade.timer
  uv-tools-upgrade.timer
  agent-slot-sweep.timer
  agent-slot-reconcile.timer
)
SERVICES=(
  rex-server.service
)
RETIRED_CRON='(sync-to-pool|pool-sync-check|github-stars|backup-openclaw-settings)[.]sh'
OP_SKILL="${OP_SKILL:-$HOME/.claude/skills/1password/scripts}"
STARS_ENV="${STARS_ENV:-$HOME/.config/github-stars/env}"
# 1Password item "GitHub Token - stars sync read (public repos)"
STARS_TOKEN_ITEM="6zqmvltmdtcsoxew2vgvnfrb2y"

# --- Read-only token for the stars sync ---
if [ ! -s "$STARS_ENV" ]; then
  if [ -x "$OP_SKILL/read_field.sh" ] && token=$("$OP_SKILL/read_field.sh" "$STARS_TOKEN_ITEM" credential 2>/dev/null) \
    && [ -n "$token" ]; then
    mkdir -p "${STARS_ENV%/*}"
    chmod 700 "${STARS_ENV%/*}"
    (umask 077 && printf 'GH_TOKEN=%s\n' "$token" >"$STARS_ENV")
    echo "==> Wrote ${STARS_ENV/#$HOME/\~} from 1Password"
  else
    echo "NOTE: no ${STARS_ENV/#$HOME/\~} and no 1Password read; the stars sync falls back to the gh login." >&2
  fi
fi

# --- Reload systemd user manager + enable the timers and services ---
echo "==> systemctl --user daemon-reload"
systemctl --user daemon-reload

for timer in "${TIMERS[@]}"; do
  echo "==> systemctl --user enable --now ${timer}"
  systemctl --user enable --now "$timer"
done

# systemd fails a start that waits when the first try exits, though Restart= goes on retrying, and the Rex server's
# first try exits while the login server's own server holds the account socket. Under set -e that failure would end
# this script.
for service in "${SERVICES[@]}"; do
  echo "==> systemctl --user enable --now --no-block ${service}"
  systemctl --user enable --now --no-block "$service"
done

# --- Retire the crontab lines the timers replace ---
current=$(crontab -l 2>/dev/null) || current=""
if grep -qE "^[^#]*${RETIRED_CRON}" <<<"$current"; then
  echo "==> Retiring crontab lines now run by the timers"
  # A retired job's heading comments go with it; commented-out jobs stay.
  awk -v pat="$RETIRED_CRON" '
    /^[[:space:]]*#/ { held = held $0 "\n"; next }
    $0 ~ pat { held = ""; next }
    { printf "%s", held; held = ""; print }
    END { printf "%s", held }
  ' <<<"$current" | cat -s | crontab -
fi

echo ""
systemctl --user list-timers "${TIMERS[@]}" --no-pager || true
systemctl --user list-units --all "${SERVICES[@]}" --no-pager || true
