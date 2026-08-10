#!/usr/bin/env bash
# A tmux client whose terminal died abnormally keeps its socket end open
# without ever returning to the event loop, eventually wedging the server.
# Catch them early so list/show commands don't pile up behind a stuck poll.
set -euo pipefail

TMUX_BIN="${TMUX_BIN:-/home/linuxbrew/.linuxbrew/bin/tmux}"

command -v "$TMUX_BIN" >/dev/null || exit 0

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
