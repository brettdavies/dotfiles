#!/usr/bin/env bash
# A tmux client whose terminal died abnormally keeps its socket end open
# without ever returning to the event loop, eventually wedging the server.
# Catch them early so list/show commands don't pile up behind a stuck poll.
set -euo pipefail

# tmux runs this hook through `run-shell`, whose PATH can be narrower than an
# interactive shell's, so fall back to the per-platform Homebrew prefixes.
TMUX_BIN="${TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
  for candidate in tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux \
    /home/linuxbrew/.linuxbrew/bin/tmux; do
    if command -v "$candidate" >/dev/null 2>&1; then
      TMUX_BIN="$candidate"
      break
    fi
  done
fi

[ -n "$TMUX_BIN" ] || exit 0

# list-clients exits nonzero when no server is running; that's not a failure.
clients="$("$TMUX_BIN" list-clients -F '#{client_pid} #{client_tty}' 2>/dev/null || true)"
[ -z "$clients" ] && exit 0

printf '%s\n' "$clients" \
  | awk '$2 == "(none)" { print $1 }' \
  | while read -r pid; do
    [ -z "$pid" ] && continue
    logger -t tmux-prune "killing orphan client pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
  done
