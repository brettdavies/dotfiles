#!/usr/bin/env bash
# Async Claude hook: reports the state of a slot's Claude to Rex. Claude Code inside tmux sends nothing that reaches
# the Mac, so for the pane's top-level Claude in a slot's Claude session (see scripts/agent-slot/lib/hook.sh) this
# writes a tmux-wrapped OSC 7501 report to the pane's terminal and stores the record in the pane option @slot_status.
#
#   SessionStart idle; UserPromptSubmit and PostToolUse working; PermissionRequest blocked, kind=question on
#   AskUserQuestion and kind=permission otherwise; Elicitation, and PreToolUse on AskUserQuestion, blocked
#   kind=question; Stop done; StopFailure error; SessionEnd clear.
#
# Async hooks can finish out of order, so each report carries the time its hook started (@slot_status_at), and under a
# per-pane lock a report older than the stored one is dropped.
#
# `slot-status.sh --replay <socket-path>`, run by slots.conf's client-attached hook, rewrites each pane's stored report
# to its terminal, so a reattached tab shows the current state. Always exits 0; failures go to the agent-slot hooks.log.
#
# Env: the AGENT_SLOT_* overrides agent-slot documents; AGENT_SLOT_RUN_DIR holds the per-pane locks.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

STATUS_STARTED=$(date +%s%N)
STATUS_LOCK_FD=

AS_HOME=$(realpath -m "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

status_record() {
  local event tool
  IFS=$'\t' read -r event tool <<<"$(hook_field '"\(.hook_event_name // "")\t\(.tool_name // "")"')"
  case $event in
    SessionStart) echo idle ;;
    UserPromptSubmit | PostToolUse) echo working ;;
    PermissionRequest) [[ $tool == AskUserQuestion ]] && echo blocked:kind=question || echo blocked:kind=permission ;;
    Elicitation) echo blocked:kind=question ;;
    PreToolUse) [[ $tool != AskUserQuestion ]] || echo blocked:kind=question ;;
    Stop) echo "done" ;;
    StopFailure) echo error ;;
    SessionEnd) echo clear ;;
  esac
}

# Usage: status_lock <pane id>; holds the pane's lock until status_unlock or exit.
status_lock() {
  mkdir -p "$AS_RUN_DIR" || return 1
  exec {STATUS_LOCK_FD}>>"$AS_RUN_DIR/status-${HOOK_SOCKET##*/}-${1#%}.lock" || return 1
  flock -w "$HOOK_TMUX_SECS" "$STATUS_LOCK_FD"
}

status_unlock() {
  [[ -z $STATUS_LOCK_FD ]] || exec {STATUS_LOCK_FD}>&-
  STATUS_LOCK_FD=
}

# Usage: status_write <tty> <record>
# A write to a terminal can block, so it runs in a bounded child, which also keeps this hook from taking the terminal
# as its controlling one.
status_write() {
  local wrapped
  # shellcheck disable=SC1003 # the format ends in an escaped backslash, the second byte of the terminator
  printf -v wrapped '\033Ptmux;\033\033]7501;%s\007\033\\' "$2"
  # shellcheck disable=SC2016 # $1 and $2 belong to the child shell
  hook_bounded tty-write bash -c 'printf "%s" "$1" >>"$2"' slot-status "$wrapped" "$1"
}

status_report() {
  local record stored=''
  hook_use_socket "${TMUX%%,*}" || return 0
  [[ $STATUS_STARTED =~ ^[0-9]+$ ]] || return 0
  record=$(status_record)
  [[ -n $record ]] || return 0
  record+=:app=claude-code
  if ! hook_pane; then
    hook_log "pane $TMUX_PANE not found on $HOOK_SOCKET; dropped state=$record"
    return 0
  fi
  hook_claude_session && hook_top_level_claude || return 0
  if ! status_lock "$TMUX_PANE"; then
    hook_log "pane $TMUX_PANE lock not taken within ${HOOK_TMUX_SECS}s; dropped state=$record"
    return 0
  fi
  hook_tmux stored show-options -q -p -v -t "$TMUX_PANE" @slot_status_at || return 0
  if [[ $stored =~ ^[0-9]+$ ]] && ((stored > STATUS_STARTED)); then
    return 0
  fi
  if ! hook_tmux stored set-option -p -t "$TMUX_PANE" @slot_status "state=$record" \; \
    set-option -p -t "$TMUX_PANE" @slot_status_at "$STATUS_STARTED"; then
    hook_log "pane $TMUX_PANE options not set; dropped state=$record"
    return 0
  fi
  status_write "$HOOK_PANE_TTY" "state=$record" || hook_log "pane $TMUX_PANE tty $HOOK_PANE_TTY not written"
}

# Usage: status_replay <socket path>
status_replay() {
  local panes id tty record
  hook_use_socket "$1" || return 0
  hook_tmux panes list-panes -a -F $'#{pane_id}\t#{pane_tty}\t#{@slot_status}' || return 0
  while IFS=$'\t' read -r id tty record; do
    [[ -n $record ]] || continue
    if status_lock "$id" && hook_tmux record show-options -q -p -v -t "$id" @slot_status && [[ -n $record ]]; then
      status_write "$tty" "$record" || hook_log "pane $id tty $tty not written on replay"
    fi
    status_unlock
  done <<<"$panes"
}

if [[ ${1:-} == --replay ]]; then
  (
    set -euo pipefail
    shopt -s inherit_errexit
    exec 2>/dev/null
    # shellcheck source=/dev/null
    source "$AS_HOME/lib/hook.sh"
    hook_init slot-status "$AS_HOME"
    status_replay "${2:-}"
  ) </dev/null
  exit 0
fi

HOOK_PAYLOAD_IN=$(cat)
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-status "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  status_report
) </dev/null
exit 0
