#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-unattended.sh, the Claude hook that answers, in a slot, the dialogs nobody in a
# slot's tab answers.
#
# Run: bats tests/slot-unattended.bats
#
# The hook runs as the pane's top-level Claude: a pane shell that records its own pid as the pane's #{pane_pid}, then
# `claude` (a symlink to bash, so /proc comm reads claude), then the hook. The tmux stub answers display from files.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-unattended.sh"
RUNS='"$@"; exit $?'

setup_file() {
  load lib/platform
  require_linux "the hook finds the pane's top-level Claude through /proc"
}

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
[ ! -f "$STUBS/tmux-hang" ] || sleep 30
case " $* " in
  *" display "*) printf "%s\t%s\t%s\n" "$(cat "$STUBS/pane-session")" "$(cat "$STUBS/pane-pid")" /dev/null ;;
esac'
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  HOOKS_LOG=$AGENT_SLOT_STATE_DIR/logs/hooks.log
}

# payload EVENT [JSON MEMBERS]: a hook payload from the slot's Claude, with the members merged in.
payload() {
  local more=${2:-}
  [[ -n $more ]] || more="{}"
  jaq -n -c --arg e "$1" --arg cwd "$SLOT" --argjson more "$more" \
    '{hook_event_name: $e, session_id: "s1", transcript_path: "/t/s1.jsonl", cwd: $cwd,
      permission_mode: "bypassPermissions"} + $more'
}

# fire: runs the hook on stdin's payload as the pane's top-level Claude.
fire() { "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK"; }

permission() { payload PermissionRequest '{"tool_name": "Bash", "tool_input": {"command": "mv a b"}}' | fire; }

pretool() {
  local input=${2:-}
  [[ -n $input ]] || input="{}"
  payload PreToolUse "{\"tool_name\": \"$1\", \"tool_input\": $input, \"tool_use_id\": \"tu1\"}" | fire
}

ledger() { jaq -c "select(.event == \"$1\")" "$LEDGER" 2>/dev/null || true; }

@test "in a slot a permission request is denied with a message that says how to go on" {
  slot repo 1
  run permission
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "PermissionRequest"
    and .hookSpecificOutput.decision.behavior == "deny"
    and (.hookSpecificOutput.decision | has("interrupt") | not)' <<<"$output"
  message=$(jaq -r '.hookSpecificOutput.decision.message' <<<"$output")
  [[ $message == *unattended* ]]
  [[ $message == *"nobody can approve"* ]]
  [[ $message == *"another way within your brief"* ]]
  [[ $message == *'`cp`'*'`trash`'*'`mv`'* ]]
  [[ $message == *'`uv run`'*'`python`'* ]]
  [[ $message == *"the session your brief reports to"* ]]
}

@test "each denied permission request writes a prompt-denied ledger line naming the slot, tool, and input" {
  permission >/dev/null
  run ledger prompt-denied
  [ "$(wc -l <<<"$output")" -eq 1 ]
  jaq -e '.repo == "repo" and .slot == 1 and .session_id == "s1" and .hook == "PermissionRequest"
    and .tool == "Bash" and .input == "mv a b" and (has("agent_id") | not)' <<<"$output"
}

@test "a subagent's permission request is denied too, and its ledger line names the subagent" {
  run fire < <(payload PermissionRequest '{"tool_name": "Bash", "tool_input": {"command": "mv c d"},
    "agent_id": "a7", "agent_type": "general-purpose"}')
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.decision.behavior == "deny"' <<<"$output"
  jaq -e '.agent_id == "a7" and .agent_type == "general-purpose" and .input == "mv c d"' <<<"$(ledger prompt-denied)"
}

@test "a ledger that cannot be written still leaves the request denied" {
  mkdir -p "$LEDGER.lock" "$LEDGER"
  run permission
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.decision.behavior == "deny"' <<<"$output"
}

@test "a long input is cut to 200 characters in the ledger" {
  long=$(printf 'x%.0s' {1..300})
  payload PermissionRequest "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"echo $long\"}}" | fire >/dev/null
  run jaq -r '.input | length' <<<"$(ledger prompt-denied)"
  [ "$output" -eq 200 ]
}

@test "in a slot AskUserQuestion is denied and routed to the session the brief reports to" {
  run pretool AskUserQuestion '{"questions": [{"question": "Which name?", "header": "Name", "options": []}]}'
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *unattended* ]]
  [[ $reason == *"to the session your brief reports to as one \`SendMessage\`"* ]]
  [[ $reason == *"your recommendation"* ]]
  jaq -e '.hook == "PreToolUse" and .tool == "AskUserQuestion" and (.input | contains("Which name?"))' \
    <<<"$(ledger prompt-denied)"
}

@test "in a slot EnterPlanMode and ExitPlanMode are denied, since nobody approves a plan" {
  for tool in EnterPlanMode ExitPlanMode; do
    run pretool "$tool"
    [ "$status" -eq 0 ]
    jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
    reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
    [[ $reason == *"plan mode"* ]]
    [[ $reason == *"the session your brief reports to"* ]]
  done
  [ "$(ledger prompt-denied | jaq -s -c 'map(.tool)')" = '["EnterPlanMode","ExitPlanMode"]' ]
}

@test "PreToolUse on any other tool prints nothing, even in a slot" {
  run pretool Bash '{"command": "mv a b"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ledger prompt-denied)" ]
}

@test "a dialog that waited for a person writes a prompt-waiting ledger line and prints nothing" {
  for type in permission_prompt elicitation_dialog agent_needs_input; do
    run fire < <(payload Notification "{\"notification_type\": \"$type\", \"message\": \"Claude needs you\"}")
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  run fire < <(payload Notification '{"notification_type": "idle_prompt", "message": "waiting"}')
  [ -z "$output" ]
  [ "$(ledger prompt-waiting | jaq -s -c 'map(.notification_type)')" = \
    '["permission_prompt","elicitation_dialog","agent_needs_input"]' ]
  jaq -e '.repo == "repo" and .slot == 1 and .session_id == "s1" and .message == "Claude needs you"' \
    <<<"$(ledger prompt-waiting | head -1)"
}

@test "outside the slot socket, or outside tmux, the hook prints nothing and exits 0" {
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run permission
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run pretool AskUserQuestion
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unset TMUX
  run permission
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
  [ ! -e "$LEDGER" ]
}

@test "a Claude started by hand in a slot's files or git session gets the dialog as usual" {
  for session in repo-1-files repo-1-git; do
    printf '%s' "$session" >"$STUBS/pane-session"
    run permission
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$LEDGER" ]
}

@test "a nested claude inside the slot's pane gets the dialog as usual" {
  run "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude bash -c "$RUNS" tool "$FAKE/claude" -c "$RUNS" claude "$HOOK" \
    < <(payload PermissionRequest '{"tool_name": "Bash", "tool_input": {"command": "mv a b"}}')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a malformed payload in a slot leaves the dialog to show and is logged" {
  run fire <<<'not json {'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run fire < <(payload PermissionRequest)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
  [ "$(grep -c 'payload' "$HOOKS_LOG")" -eq 2 ]
}

@test "a tmux server that hangs leaves the dialog to show, within the hook's bound" {
  touch "$STUBS/tmux-hang"
  start=$SECONDS
  run permission
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((SECONDS - start)) -le 6 ]
}

@test "on a foreign head a denied permission steers the agent away from running Python in the tree" {
  slot repo 1 '{"task": "review", "head_foreign": true, "head_owner": "evil"}'
  run permission
  [ "$status" -eq 0 ]
  message=$(jaq -r '.hookSpecificOutput.decision.message' <<<"$output")
  [[ $message != *'`uv run` in place of `python`'* ]]
  [[ $message == *'from outside this tree'* ]]
  [[ $message == *"the session your brief reports to"* ]]
}

@test "a denied permission gives a slot whose record cannot be read the foreign head's advice, since it may be one" {
  run permission
  [ "$status" -eq 0 ]
  message=$(jaq -r '.hookSpecificOutput.decision.message' <<<"$output")
  [[ $message == *'from outside this tree'* ]]
}
