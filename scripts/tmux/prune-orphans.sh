#!/usr/bin/env bash
# Kills tmux clients whose terminal is gone (client_tty "(none)"). A client
# left in that state keeps every descriptor it inherited open, which can
# include another session's pty master and keep that terminal from hanging up.
set -euo pipefail

# tmux runs this hook through `run-shell`, whose PATH can be narrower than an
# interactive shell's, so fall back to the per-platform Homebrew prefixes.
find_bin() {
  local candidate
  for candidate in "$1" "/opt/homebrew/bin/$1" "/usr/local/bin/$1" \
    "/home/linuxbrew/.linuxbrew/bin/$1"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TMUX_BIN="${TMUX_BIN:-$(find_bin tmux || true)}"
[ -n "$TMUX_BIN" ] || exit 0

TIMEOUT_BIN="$(find_bin timeout || find_bin gtimeout || true)"
if [ -z "$TIMEOUT_BIN" ]; then
  echo "ERROR: timeout not found; install coreutils" >&2
  exit 1
fi

# A wedged server never answers, and an unbounded list-clients would hang the
# hook and the systemd unit behind it.
TMUX_PRUNE_TIMEOUT="${TMUX_PRUNE_TIMEOUT:-10}"

# The client hands its stdin and stdout to the server over the socket, and a
# wedged server holds them open after the client is killed. Reading the output
# through a pipe would then wait forever for EOF, so it goes to a file.
clients_file="$(mktemp)"
trap 'rm -f "$clients_file"' EXIT

# list-clients exits nonzero when no server is running; that's not a failure.
status=0
"$TIMEOUT_BIN" -k 5 "$TMUX_PRUNE_TIMEOUT" "$TMUX_BIN" list-clients \
  -F '#{client_pid} #{client_tty}' </dev/null >"$clients_file" 2>/dev/null \
  || status=$?
if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "ERROR: tmux server did not answer list-clients within ${TMUX_PRUNE_TIMEOUT}s; it is likely wedged" >&2
  exit 1
fi

awk '$2 == "(none)" { print $1 }' "$clients_file" \
  | while read -r pid; do
    [ -z "$pid" ] && continue
    logger -t tmux-prune "killing orphan client pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
  done
