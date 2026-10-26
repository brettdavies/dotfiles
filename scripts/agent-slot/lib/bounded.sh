# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Bounded calls. Every tmux, git network, gh, and claude call runs under timeout with stdin from /dev/null. Output goes
# through files rather than pipes: a tmux client hands its descriptors to the server, and a wedged server holds them
# open after timeout kills the client, so a pipe would never reach EOF. A failed call keeps its output in a log file
# under the state directory, whose path an error reports.

BOUNDED_STATUS=0
BOUNDED_LOG=

# Usage: bounded <var> <label> <seconds> <command...>
# Sets <var> to the command's stdout, BOUNDED_STATUS to its exit status (124 after a timeout), and BOUNDED_LOG to the
# kept log on failure. Lock descriptors are closed in the child, so a daemon it starts (a tmux server) never holds a
# slot lock.
bounded() {
  local -n __bounded_ref=$1
  local __bounded_label=$2 __bounded_secs=$3 __bounded_o __bounded_e __bounded_fd
  shift 3
  __bounded_o=$(mktemp) __bounded_e=$(mktemp)
  BOUNDED_STATUS=0 BOUNDED_LOG=
  (
    for __bounded_fd in "${RECORD_LOCK_FDS[@]}"; do exec {__bounded_fd}>&-; done
    exec timeout --kill-after=2 "$__bounded_secs" "$@"
  ) </dev/null >"$__bounded_o" 2>"$__bounded_e" || BOUNDED_STATUS=$?
  __bounded_ref=$(<"$__bounded_o")
  if ((BOUNDED_STATUS != 0)); then
    BOUNDED_LOG=$(_bounded_keep "$__bounded_label" "$__bounded_o" "$__bounded_e" "$@")
  fi
  rm -f "$__bounded_o" "$__bounded_e"
  return "$BOUNDED_STATUS"
}

_bounded_keep() {
  local label=$1 out=$2 err=$3 log
  shift 3
  mkdir -p "$AS_LOG_DIR"
  log="$AS_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-$label.log"
  {
    printf 'command: %s\nexit: %s\n--- stdout\n' "$(contract_quote "$@")" "$BOUNDED_STATUS"
    cat "$out"
    printf -- '--- stderr\n'
    cat "$err"
  } >"$log"
  printf '%s' "$log"
}

# Usage: slot_tmux <var> <seconds> <tmux args...>
# A tmux call on the slot server, which always loads slots.conf rather than tmux.conf and its plugins.
slot_tmux() {
  local var=$1 secs=$2
  shift 2
  bounded "$var" tmux "$secs" "$AS_TMUX" -L "$AS_TMUX_SOCKET" -f "$AS_TMUX_CONF" "$@"
}

# Sets SLOT_SESSIONS to the session names on the slot server, one per line; empty when no server is running. Returns
# 124 when the server did not answer.
SLOT_SESSIONS=
slot_tmux_sessions() {
  SLOT_SESSIONS=
  if slot_tmux SLOT_SESSIONS 5 list-sessions -F '#{session_name}'; then
    return 0
  fi
  SLOT_SESSIONS=
  ((BOUNDED_STATUS != 124)) || return 124
  if grep -qE 'no server running|error connecting|No such file' "$BOUNDED_LOG"; then
    rm -f "$BOUNDED_LOG"
    BOUNDED_LOG=
    return 0
  fi
  return "$BOUNDED_STATUS"
}

# Like slot_tmux_sessions, but stops the command when the slot server does not answer or tmux fails.
slot_sessions_or_fail() {
  local status=0
  slot_tmux_sessions || status=$?
  ((status != 0)) || return 0
  ((status != 124)) || tmux_unresponsive
  contract_use_tools tmux
  contract_fail tmux-failed "tmux list-sessions on the $AS_TMUX_SOCKET server exited $status" --value "$AS_TMUX_SOCKET" \
    --command "$AS_TMUX -L $AS_TMUX_SOCKET list-sessions" --log "$BOUNDED_LOG"
}

tmux_unresponsive() {
  contract_use_tools tmux
  contract_fail tmux-unresponsive "the $AS_TMUX_SOCKET tmux server did not answer within its bound" \
    --value "$AS_TMUX_SOCKET" --command "$AS_TMUX -L $AS_TMUX_SOCKET list-sessions" --side-effects "${1:-none}" \
    --log "$BOUNDED_LOG"
}
