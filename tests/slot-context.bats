#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-context.sh, the SessionStart hook that records a slot's Claude session and
# hands the agent its slot context.
#
# Run: bats tests/slot-context.bats
#
# The hook runs as the pane's top-level Claude: a pane shell that records its own pid as the pane's #{pane_pid}, then
# `claude` (a symlink to bash, so /proc comm reads claude), then the hook. The tmux stub answers display from files.

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-context.sh"
RUNS='"$@"; exit $?'

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" TMUX_PANE=%3
  FAKE=$T/fake
  mkdir -p "$FAKE"
  ln -s "$(command -v bash)" "$FAKE/claude"
  printf '%s' repo-1 >"$STUBS/pane-session"
  printf '#!/usr/bin/env bash\nprintf %%s "$$" >"$STUBS/pane-pid"\n"$@"\nexit $?\n' >"$T/pane-shell"
  chmod +x "$T/pane-shell"
  stub tmux '
case " $* " in
  *" display "*) printf "%s\t%s\t%s\n" "$(cat "$STUBS/pane-session")" "$(cat "$STUBS/pane-pid")" /dev/null ;;
esac'
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
}

# start SESSION_ID SOURCE [CWD]: runs the hook for a SessionStart as the pane's top-level Claude.
start() {
  jaq -n -c --arg sid "$1" --arg src "$2" --arg cwd "${3:-$SLOT}" \
    '{hook_event_name: "SessionStart", session_id: $sid, transcript_path: "/t/\($sid).jsonl", cwd: $cwd,
      source: $src}' | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK"
}

record() { jaq -c "$1" "$SLOT/.git/agent-slot.json"; }

ledger() { jaq -c "select(.event == \"$1\")" "$LEDGER" 2>/dev/null || true; }

@test "inside a slot the hook returns additionalContext naming the slot, task, base, and prime" {
  slot repo 1 '{"task": "fix-login"}'
  run start s1 startup
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$output"
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"repo/1"* ]]
  [[ $context == *"$SLOT"* ]]
  [[ $context == *fix-login* ]]
  [[ $context == *"base branch is main"* ]]
  [[ $context == *"$AGENT_SLOT_DEV/repo"*read-only* ]]
  [[ $context == *sd-commit-doc* ]]
  [[ $context == *"agent-slot check"* ]]
  [[ $context == *"git add"*"git commit"* ]]
  [[ $context == *worktree* ]]
  [[ $context == *"--output json"* ]]
  [[ $context == *"agent-slot whoami"* ]]
  [[ $context == *"agent-slot schema"* ]]
  [[ $context == *"agent-slot launch"*"--request-id"* ]]
  [[ $context == *"ask the operator"* ]]
  [[ $context == *"--dangerously-skip-permissions"* ]]
}

@test "a slot with no task says so" {
  slot repo 1
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"no task name"* ]]
}

@test "outside a slot the hook prints nothing" {
  slot repo 1
  mkdir -p "$T/elsewhere"
  run start s1 startup "$T/elsewhere"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
}

@test "the slot is found from the working directory when the payload has none" {
  slot repo 1 '{"task": "t"}'
  cd "$SLOT"
  output=$(printf '{"hook_event_name":"SessionStart","session_id":"s1"}' \
    | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK")
  [[ $(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output") == *"repo/1"* ]]
}

@test "outside the slot socket, or for a Claude not on the pane's shell, the hook prints nothing" {
  slot repo 1
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run start s1 startup
  [ -z "$output" ]

  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0"
  output=$(printf '{"session_id":"s1","cwd":"%s"}' "$SLOT" | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude \
    bash -c "$RUNS" tool "$FAKE/claude" -c "$RUNS" claude "$HOOK")
  [ -z "$output" ]

  printf '%s' repo-1-git >"$STUBS/pane-session"
  run start s1 startup
  [ -z "$output" ]
  [ "$(record .session_id)" = '"11111111-2222-3333-4444-555555555555"' ]
  [ ! -e "$LEDGER" ]
}

@test "a clear with a new session ID updates the record and appends a session line" {
  slot repo 1 '{"task": "t", "session_id": "s1", "transcript": "/t/s1.jsonl", "ready_at": 5}'
  run start s2 clear
  [ "$status" -eq 0 ]
  [ "$(record .session_id)" = '"s2"' ]
  [ "$(record .transcript)" = '"/t/s2.jsonl"' ]
  [ "$(ledger session | wc -l)" -eq 1 ]
  ledger session | jaq -e '.repo == "repo" and .slot == 1 and .task == "t" and .session_id == "s2"
    and .transcript == "/t/s2.jsonl" and .source == "clear" and .schema == "dotfiles.agent-slot/1"'
}

@test "a start with the session already recorded appends no session line" {
  slot repo 1 '{"session_id": "s1", "transcript": "/t/s1.jsonl", "ready_at": 5}'
  start s1 resume >/dev/null
  [ -z "$(ledger session)" ]
}

@test "the first start appends one ready line with the launch's request ID; later starts append none" {
  slot repo 1 '{"request_id": "req-1", "session_id": "s1"}'
  start s1 startup >/dev/null
  [ "$(ledger ready | wc -l)" -eq 1 ]
  ledger ready | jaq -e '.request_id == "req-1" and (.ready_at | type == "number") and .repo == "repo"
    and .slot == 1 and .session_id == "s1"'
  [ "$(record '.ready_at | type')" = '"number"' ]
  ready_at=$(record .ready_at)

  start s2 clear >/dev/null
  start s2 resume >/dev/null
  [ "$(ledger ready | wc -l)" -eq 1 ]
  [ "$(record .ready_at)" = "$ready_at" ]
}

@test "a first start with no request ID marks the slot ready and appends no ready line" {
  slot repo 1
  start s1 startup >/dev/null
  [ "$(record '.ready_at | type')" = '"number"' ]
  [ -z "$(ledger ready)" ]
}
