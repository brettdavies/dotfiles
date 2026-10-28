# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Helpers for the Claude hooks that act on slots (stow/claude/dot-claude/slot-status.sh and slot-context.sh). A hook
# acts only in a pane on the slot tmux server and only for that pane's own Claude, so a nested `claude -p`, or a Claude
# started by hand in a slot's files or git session, never reports. Every failure goes to hooks.log in the agent-slot
# log directory; nothing reaches Claude.

HOOK_NAME=hook
HOOK_LOG=/dev/null
HOOK_PAYLOAD=
HOOK_SOCKET=
HOOK_TMUX_SECS=2
HOOK_PANE_SESSION=
HOOK_PANE_PID=
HOOK_PANE_TTY=

# Usage: hook_init <hook name> <agent-slot directory>
# Loads the agent-slot libraries and configuration, then sends this shell's stderr to the hook log.
hook_init() {
  local lib
  HOOK_NAME=$1
  for lib in env contract names record bounded read release; do
    # shellcheck source=/dev/null
    source "$2/lib/$lib.sh" || return 1
  done
  agent_slot_env "$2" || return 1
  mkdir -p "$AS_LOG_DIR" || return 1
  HOOK_LOG=$AS_LOG_DIR/hooks.log
  exec 2>>"$HOOK_LOG"
}

hook_log() {
  printf '%s %s[%s] %s\n' "$(contract_now)" "$HOOK_NAME" "$$" "$1" >>"$HOOK_LOG"
}

# Usage: hook_field <jq filter>; prints the payload's value, or nothing.
hook_field() {
  contract_json -r "($1) // empty" <<<"$HOOK_PAYLOAD" || true
}

# Usage: hook_use_socket <socket path>; sets HOOK_SOCKET, or returns 1 unless the path is the slot server's socket.
hook_use_socket() {
  [[ -n $1 && ${1##*/} == "$AS_TMUX_SOCKET" ]] || return 1
  HOOK_SOCKET=$1
}

# Usage: hook_tmux <var> <tmux args...>
# A bounded tmux call on the server at HOOK_SOCKET. A failed call's output moves into the hook log.
hook_tmux() {
  local var=$1
  shift
  bounded "$var" tmux "$HOOK_TMUX_SECS" "$AS_TMUX" -S "$HOOK_SOCKET" "$@" && return 0
  _hook_absorb
  return 1
}

# Usage: hook_bounded <label> <command...>; a bounded call whose failure moves into the hook log.
hook_bounded() {
  local label=$1 out
  shift
  bounded out "$label" "$HOOK_TMUX_SECS" "$@" && return 0
  _hook_absorb
  return 1
}

_hook_absorb() {
  [[ -n $BOUNDED_LOG && -f $BOUNDED_LOG ]] || return 0
  cat "$BOUNDED_LOG" >>"$HOOK_LOG"
  rm -f "$BOUNDED_LOG"
}

# Sets HOOK_PANE_SESSION, HOOK_PANE_PID, and HOOK_PANE_TTY for the pane $TMUX_PANE names. tmux expands the format to
# empty fields for a pane it cannot find, which returns 1.
hook_pane() {
  local info
  [[ -n ${TMUX_PANE:-} ]] || return 1
  hook_tmux info display -p -t "$TMUX_PANE" $'#{session_name}\t#{pane_pid}\t#{pane_tty}' || return 1
  IFS=$'\t' read -r HOOK_PANE_SESSION HOOK_PANE_PID HOOK_PANE_TTY <<<"$info"
  [[ -n $HOOK_PANE_SESSION && $HOOK_PANE_PID =~ ^[0-9]+$ && -n $HOOK_PANE_TTY ]]
}

hook_claude_session() {
  slot_session_is_claude "$HOOK_PANE_SESSION"
}

# Whether this hook belongs to the pane's top-level Claude: the nearest claude process above it is a child of the
# pane's shell. A `claude -p` run from that Claude's Bash tool has a tool shell as its parent instead. /proc/<pid>/stat
# gives comm in parentheses, and comm can hold spaces and parentheses, so ppid is read after the last ") ".
hook_top_level_claude() {
  local pid=$$ stat comm ppid depth
  for ((depth = 0; depth < 64; depth++)); do
    stat=$(<"/proc/$pid/stat") || return 1
    comm=${stat#*(}
    comm=${comm%)*}
    read -r _ ppid _ <<<"${stat##*) }"
    if [[ $comm == claude ]]; then
      [[ $ppid == "$HOOK_PANE_PID" ]]
      return
    fi
    [[ $ppid =~ ^[0-9]+$ ]] && ((ppid > 1)) || return 1
    pid=$ppid
  done
  return 1
}
