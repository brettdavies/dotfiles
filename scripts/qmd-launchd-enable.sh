#!/usr/bin/env bash
# One-shot enable script for the macOS qmd LaunchAgents.
#
# Macports the Linux systemd setup (qmd-update.timer, qmd-embed.timer,
# qmd-cleanup.timer) to launchd. Bootstraps all three agents into the
# user's GUI domain and verifies each is loaded. Idempotent.
#
# Usage: bash scripts/qmd-launchd-enable.sh

set -euo pipefail

# --- macOS gate ---
if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: qmd LaunchAgents are macOS-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

AGENT_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/dotfiles/scripts/qmd-launchd/logs"
AGENTS=(com.user.qmd-update com.user.qmd-embed com.user.qmd-cleanup)

# --- Verify the stow'd plists are in place ---
for agent in "${AGENTS[@]}"; do
  plist="$AGENT_DIR/$agent.plist"
  if [ ! -e "$plist" ]; then
    echo "ERROR: $plist not found." >&2
    echo "       Run scripts/stow-deploy --all first to symlink the launchagent package." >&2
    exit 1
  fi
done

# --- Verify qmd is installed (one of the two known paths) ---
if [ ! -x "$HOME/.local/bin/qmd" ] && [ ! -x "$HOME/.cache/bun/bin/qmd" ]; then
  echo "ERROR: qmd binary not found at ~/.local/bin/qmd or ~/.cache/bun/bin/qmd." >&2
  echo "       Install with:  bun install -g @tobilu/qmd" >&2
  exit 1
fi

# --- Ensure log dir exists (stow creates the symlink but launchd needs the target) ---
mkdir -p "$LOG_DIR"

# --- Bootstrap each agent (modern replacement for `launchctl load`) ---
# UID-scoped GUI domain so it works without sudo.
UID_DOMAIN="gui/$(id -u)"

for agent in "${AGENTS[@]}"; do
  plist="$AGENT_DIR/$agent.plist"

  # Unload if already loaded (idempotency — bootstrap fails on duplicate).
  if launchctl print "$UID_DOMAIN/$agent" >/dev/null 2>&1; then
    echo "==> $agent: already loaded — bootout first"
    launchctl bootout "$UID_DOMAIN" "$plist" 2>/dev/null || true
  fi

  echo "==> $agent: bootstrap"
  launchctl bootstrap "$UID_DOMAIN" "$plist"
done

# --- Verify all three are loaded ---
echo ""
echo "==> Verifying loaded state"
for agent in "${AGENTS[@]}"; do
  if launchctl print "$UID_DOMAIN/$agent" >/dev/null 2>&1; then
    echo "    [loaded] $agent"
  else
    echo "    [MISSING] $agent — bootstrap failed" >&2
  fi
done

echo ""
echo "Done. Agents fire every 5 min (update, embed) or nightly at 03:00 (cleanup)."
echo "Logs:  $LOG_DIR/"
echo "Tail:  tail -f $LOG_DIR/qmd-embed.log"
echo "Stop:  launchctl bootout $UID_DOMAIN $AGENT_DIR/<agent>.plist"
