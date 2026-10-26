#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-status.sh, the async Claude hook that reports an agent's state from a slot's
# pane on the slot tmux server.
#
# Run: bats tests/slot-status.bats
#
# The hook runs under the process chain a real slot pane gives it: a pane shell that records its own pid as the pane's
# #{pane_pid}, then `claude` (a symlink to bash, so /proc comm reads claude), then the hook. The tmux stub serves one
# pane per directory under $STUBS/panes and keeps pane options as files, and the pane's tty is a regular file.

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-status.sh"
RUNS='"$@"; exit $?'

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  export AGENT_SLOT_RUN_DIR=$T/run
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" TMUX_PANE=%7
  FAKE=$T/fake
  mkdir -p "$FAKE"
  ln -s "$(command -v bash)" "$FAKE/claude"
  pane 7 repo-1
  printf '#!/usr/bin/env bash\nprintf %%s "$$" >"$STUBS/panes/7/pid"\n"$@"\nexit $?\n' >"$T/pane-shell"
  chmod +x "$T/pane-shell"

  stub tmux '
[ ! -f "$STUBS/tmux-hang" ] || sleep 30
expand() {
  local d=$STUBS/panes/$1 f=$2
  f=${f//"#{session_name}"/$(cat "$d/session" 2>/dev/null)}
  f=${f//"#{pane_pid}"/$(cat "$d/pid" 2>/dev/null)}
  f=${f//"#{pane_tty}"/$(cat "$d/tty" 2>/dev/null)}
  f=${f//"#{pane_id}"/%$1}
  f=${f//"#{@slot_status}"/$(cat "$d/opts/@slot_status" 2>/dev/null)}
  printf "%s\n" "$f"
}
one() {
  local cmd=$1 t= p=() d
  shift
  while [ $# -gt 0 ]; do
    case $1 in -t) t=${2#%}; shift ;; -[a-zA-Z]*) ;; *) p+=("$1") ;; esac
    shift
  done
  d=$STUBS/panes/$t
  case $cmd in
    display | display-message) expand "$t" "${p[0]}" ;;
    show-options) cat "$d/opts/${p[0]}" 2>/dev/null; echo ;;
    set-option)
      [ -n "$t" ] && [ -d "$d" ] || { echo "no such pane: %$t" >&2; return 1; }
      mkdir -p "$d/opts"
      printf "%s" "${p[1]}" >"$d/opts/${p[0]}" ;;
    list-panes) for d in "$STUBS"/panes/*/; do d=${d%/}; expand "${d##*/}" "${p[0]}"; done ;;
  esac
}
[ "$1" = -S ] && shift 2
cmd=()
for a in "$@" ";"; do
  if [ "$a" = ";" ]; then one "${cmd[@]}" || exit 1; cmd=(); else cmd+=("$a"); fi
done'
}

# pane ID SESSION: a pane on the stub server with its own tty file.
pane() {
  mkdir -p "$STUBS/panes/$1/opts"
  printf '%s' "$2" >"$STUBS/panes/$1/session"
  : >"$T/tty-$1"
  printf '%s' "$T/tty-$1" >"$STUBS/panes/$1/tty"
}

option() { cat "$STUBS/panes/${2:-7}/opts/$1" 2>/dev/null; }

payload() {
  jaq -n -c --arg e "$1" --arg tool "${2:-}" \
    '{hook_event_name: $e, session_id: "s1", transcript_path: "/x/s1.jsonl", cwd: "/x"}
     + (if $tool == "" then {} else {tool_name: $tool} end)'
}

# report EVENT [TOOL]: runs the hook as the pane's top-level Claude.
report() {
  payload "$1" "${2:-}" | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK"
}

# shellcheck disable=SC1003 # the format ends in an escaped backslash, the second byte of the terminator
wrapped() { printf '\033Ptmux;\033\033]7501;%s\007\033\\' "$1"; }

@test "Stop writes one wrapped done report to the pane tty and stores it" {
  run report Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$T/tty-7")" = "$(wrapped state=done:app=claude-code)" ]
  [ "$(option @slot_status)" = state=done:app=claude-code ]
  [[ $(option @slot_status_at) =~ ^[0-9]{19}$ ]]
  grep -qF "tmux -S $T/$AGENT_SLOT_TMUX_SOCKET display" "$CALLS"
}

@test "PermissionRequest reports blocked on permission, and on AskUserQuestion a question" {
  report PermissionRequest Bash
  [ "$(option @slot_status)" = state=blocked:kind=permission:app=claude-code ]
  [ "$(cat "$T/tty-7")" = "$(wrapped state=blocked:kind=permission:app=claude-code)" ]

  : >"$T/tty-7"
  report PermissionRequest AskUserQuestion
  [ "$(option @slot_status)" = state=blocked:kind=question:app=claude-code ]
  [ "$(cat "$T/tty-7")" = "$(wrapped state=blocked:kind=question:app=claude-code)" ]
}

@test "PreToolUse on AskUserQuestion reports a question; on another tool it reports nothing" {
  report PreToolUse Bash
  [ ! -s "$T/tty-7" ]
  [ -z "$(option @slot_status)" ]

  report PreToolUse AskUserQuestion
  [ "$(cat "$T/tty-7")" = "$(wrapped state=blocked:kind=question:app=claude-code)" ]
}

@test "each event maps to its state" {
  for pair in SessionStart:idle UserPromptSubmit:working PostToolUse:working Elicitation:blocked:kind=question \
    StopFailure:error SessionEnd:clear; do
    report "${pair%%:*}"
    [ "$(option @slot_status)" = "state=${pair#*:}:app=claude-code" ] || {
      echo "${pair%%:*} stored $(option @slot_status)"
      return 1
    }
  done
}

@test "a report stamped earlier than the stored one is dropped" {
  printf '%s' state=blocked:kind=permission:app=claude-code >"$STUBS/panes/7/opts/@slot_status"
  later=$(($(date +%s%N) + 60000000000))
  printf '%s' "$later" >"$STUBS/panes/7/opts/@slot_status_at"
  run report PostToolUse Bash
  [ "$status" -eq 0 ]
  [ "$(option @slot_status)" = state=blocked:kind=permission:app=claude-code ]
  [ "$(option @slot_status_at)" = "$later" ]
  [ ! -s "$T/tty-7" ]
}

@test "a report stamped later than the stored one replaces it" {
  printf '%s' state=blocked:kind=permission:app=claude-code >"$STUBS/panes/7/opts/@slot_status"
  printf '%s' 1000 >"$STUBS/panes/7/opts/@slot_status_at"
  report PostToolUse Bash
  [ "$(option @slot_status)" = state=working:app=claude-code ]
  [ "$(cat "$T/tty-7")" = "$(wrapped state=working:app=claude-code)" ]
}

@test "a nested claude -p inside the pane reports nothing" {
  report UserPromptSubmit
  : >"$T/tty-7"
  payload Stop | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude bash -c "$RUNS" tool \
    "$FAKE/claude" -c "$RUNS" claude "$HOOK"
  [ "$(option @slot_status)" = state=working:app=claude-code ]
  [ ! -s "$T/tty-7" ]
}

@test "a hook with no claude above it reports nothing" {
  payload Stop | "$T/pane-shell" "$HOOK"
  [ -z "$(option @slot_status)" ]
  [ ! -s "$T/tty-7" ]
}

@test "a Claude started by hand in a slot's files or git session reports nothing" {
  for session in repo-1-files repo-1-git; do
    printf '%s' "$session" >"$STUBS/panes/7/session"
    report Stop
    [ -z "$(option @slot_status)" ]
    [ ! -s "$T/tty-7" ]
  done
}

@test "outside the slot socket, or outside tmux, the hook does nothing and exits 0" {
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run report Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unset TMUX
  run report Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(option @slot_status)" ]
  [ ! -s "$T/tty-7" ]
  [ ! -s "$CALLS" ]
}

@test "a pane tmux cannot find is logged, not raised" {
  export TMUX_PANE=%9
  run report Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'pane %9' "$AGENT_SLOT_STATE_DIR/logs/hooks.log"
}

@test "a tty write error is logged, not raised" {
  printf '%s' "$T/no-such-dir/tty" >"$STUBS/panes/7/tty"
  run report Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'no-such-dir' "$AGENT_SLOT_STATE_DIR/logs/hooks.log"
}

@test "a tmux server that hangs leaves the hook exiting 0 within its bound" {
  touch "$STUBS/tmux-hang"
  start=$SECONDS
  run report Stop
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -le 6 ]
  [ ! -s "$T/tty-7" ]
}

@test "--replay writes each pane's stored report to its tty and nothing for a pane without one" {
  pane 8 repo-2
  pane 9 other
  printf '%s' state=done:app=claude-code >"$STUBS/panes/7/opts/@slot_status"
  printf '%s' state=blocked:kind=question:app=claude-code >"$STUBS/panes/8/opts/@slot_status"
  unset TMUX TMUX_PANE
  run "$HOOK" --replay "$T/$AGENT_SLOT_TMUX_SOCKET" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$T/tty-7")" = "$(wrapped state=done:app=claude-code)" ]
  [ "$(cat "$T/tty-8")" = "$(wrapped state=blocked:kind=question:app=claude-code)" ]
  [ ! -s "$T/tty-9" ]
}

@test "--replay on another server's socket writes nothing" {
  printf '%s' state=done:app=claude-code >"$STUBS/panes/7/opts/@slot_status"
  run "$HOOK" --replay /tmp/tmux-1000/default </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$T/tty-7" ]
  [ ! -s "$CALLS" ]
}
