#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that denies a pgrep -f / pkill -f whose pattern matches
# the tool call's own command line.
#
# Run: bats tests/self-match-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/self-match-guard.sh"

# Feed a faked Bash tool input to the hook. Sets DECISION (ALLOW, DENY, or HOOK_ERROR) and
# TEXT (the deny reason shown to the agent).
# Args: command
decide() {
  local out rc
  out=$(jaq -n --arg cmd "$1" '{tool_input: {command: $cmd}}' | "$HOOK" 2>&1)
  rc=$?
  TEXT=""
  if [ "$rc" -ne 0 ]; then
    DECISION=HOOK_ERROR
    TEXT=$out
  elif [ -z "$out" ]; then
    DECISION=ALLOW
  elif printf '%s' "$out" | jaq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    DECISION=DENY
    TEXT=$(printf '%s' "$out" | jaq -r '.hookSpecificOutput.permissionDecisionReason')
  else
    DECISION="OTHER:$out"
  fi
}

# The line after "next_step", which holds the rebuilt command.
next_command() { awk 'f { print; exit } /^next_step/ { f = 1 }' <<<"$TEXT"; }

setup() { command -v jaq >/dev/null 2>&1 || skip "jaq not available"; }

# ---------------------------------------------------------------------------
# Denied: the pattern matches the command's own text
# ---------------------------------------------------------------------------

@test "a polling loop on pgrep -f with a literal pattern is denied with a bracket pattern" {
  decide "until ! pgrep -f 'git push -u origin fix/x' >/dev/null; do sleep 10; done"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[pattern-matches-own-command]"* ]]
  [[ "$TEXT" == *"next_step [use-bracket-pattern]"* ]]
  [ "$(next_command)" = "until ! pgrep -f '[g]it push -u origin fix/x' >/dev/null; do sleep 10; done" ]
}

@test "pkill -f with a literal pattern is denied" {
  decide "pkill -f 'served-model-name lighton'"
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = "pkill -f '[s]erved-model-name lighton'" ]
}

@test "combined flags and option arguments before the pattern are read" {
  decide 'pgrep -u brett -af "vllm serve"'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'pgrep -u brett -af "[v]llm serve"' ]
  decide 'pkill -9 --full vllm'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'pkill -9 --full [v]llm' ]
}

@test "a pattern from a variable assigned in the same command is resolved and denied" {
  decide 'E=/tmp/run/e2e; until ! pgrep -f "$E" >/dev/null; do sleep 10; done'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"next_step [wait-on-pid]"* ]]
}

@test "a pattern whose text the command also runs gets the PID advice, not a bracket" {
  decide "git push -u origin fix/x & until ! pgrep -f 'git push -u origin fix/x' >/dev/null; do sleep 10; done"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"next_step [wait-on-pid]"* ]]
}

# ---------------------------------------------------------------------------
# Allowed
# ---------------------------------------------------------------------------

@test "a bracket pattern that cannot match its own text passes" {
  decide "until ! pgrep -f '[g]it push -u origin fix/x' >/dev/null; do sleep 10; done"
  [ "$DECISION" = ALLOW ]
}

@test "pgrep without -f matches process names only and passes" {
  decide 'pgrep -x lazygit; pkill vllm'
  [ "$DECISION" = ALLOW ]
}

@test "a pattern from a variable the command does not assign passes" {
  decide 'pgrep -f "$TARGET"'
  [ "$DECISION" = ALLOW ]
}

@test "the words pgrep and pkill outside command position pass" {
  decide "echo 'use pgrep -f carefully'; rg -n 'pkill -f' notes.md"
  [ "$DECISION" = ALLOW ]
}

@test "a command without pgrep or pkill passes" {
  decide 'ps -eo pid,args | grep -E "[v]llm"'
  [ "$DECISION" = ALLOW ]
}
