#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that denies blocking waits and slow polls.
#
# Run: bats tests/sleep-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/sleep-guard.sh"

# Feed a faked Bash tool input to the hook. Sets DECISION (ALLOW, DENY, or
# HOOK_ERROR) and TEXT (the deny reason shown to the agent).
# Args: command, run_in_background (true | false; default false)
decide() {
  local out rc
  out=$(jaq -n --arg cmd "$1" --argjson bg "${2:-false}" \
    '{tool_input: {command: $cmd, run_in_background: $bg}}' | "$HOOK" 2>&1)
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
# Foreground: a long sleep blocks the session
# ---------------------------------------------------------------------------

@test "a bare foreground sleep over 10 s is denied with a poll template" {
  decide 'sleep 60'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[sleep-blocks-session]"* ]]
  [[ "$TEXT" == *'`sleep 60` would block this session for 60 s'* ]]
  [[ "$TEXT" == *"next_step [poll-condition-in-background]"* ]]
  [ "$(next_command)" = 'until <condition>; do sleep 10; done' ]
}

@test "a sleep before a check keeps the check in the rebuilt command" {
  decide 'sleep 30 && tail -5 build.log'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'until <condition>; do sleep 10; done && tail -5 build.log' ]
}

@test "unit suffixes, decimals, summed operands, and infinity are measured" {
  decide 'sleep 2m'
  [[ "$TEXT" == *"for 120 s"* ]]
  decide 'sleep 1m 30s'
  [[ "$TEXT" == *"for 90 s"* ]]
  decide 'sleep 10.5'
  [ "$DECISION" = DENY ]
  decide 'sleep infinity'
  [ "$DECISION" = DENY ]
}

@test "a sleep split by a line continuation is still measured" {
  decide $'sleep \\\n  45'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"for 45 s"* ]]
}

@test "a long sleep inside a bash -c script is denied" {
  decide "bash -c 'sleep 45'"
  [ "$DECISION" = DENY ]
}

@test "a long sleep in a foreground for loop gets a 10 s interval in the background" {
  decide 'for i in 1 2 3; do curl -sf localhost:8000 && break; sleep 30; done'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"next_step [rerun-in-background]"* ]]
  [ "$(next_command)" = 'for i in 1 2 3; do curl -sf localhost:8000 && break; sleep 10; done' ]
}

# ---------------------------------------------------------------------------
# Foreground: a polling loop blocks the session whatever its interval
# ---------------------------------------------------------------------------

@test "a foreground until loop is denied even with a short sleep" {
  decide 'until [ -f done.flag ]; do sleep 5; done'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[poll-loop-blocks-session]"* ]]
  [ "$(next_command)" = 'until [ -f done.flag ]; do sleep 5; done' ]
}

@test "a foreground while loop with a long interval is rebuilt at 10 s" {
  decide $'while pgrep -f marker >/dev/null; do\n  sleep 60\ndone'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[poll-loop-blocks-session]"* ]]
  [[ "$TEXT" == *$'do\n  sleep 10\ndone'* ]]
}

@test "a foreground loop with a variable sleep is still a blocking poll" {
  decide 'while ! curl -sf localhost:8000; do sleep "$delay"; done'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[poll-loop-blocks-session]"* ]]
}

# ---------------------------------------------------------------------------
# Background: the interval and fixed waits still cost wall clock
# ---------------------------------------------------------------------------

@test "a background poll interval over 10 s is shortened" {
  decide 'until curl -sf localhost:8000; do sleep 60; done' true
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[poll-interval-too-long]"* ]]
  [[ "$TEXT" == *"next_step [shorten-interval]"* ]]
  [ "$(next_command)" = 'until curl -sf localhost:8000; do sleep 10; done' ]
}

@test "a background fixed wait over 10 s is denied and names the escape marker" {
  decide 'sleep 300; cat run.log' true
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[fixed-wait-too-long]"* ]]
  [[ "$TEXT" == *'# sleep-guard: required-delay'* ]]
  [ "$(next_command)" = 'until <condition>; do sleep 10; done; cat run.log' ]
}

@test "the deny names the docs section" {
  decide 'sleep 60'
  [[ "$TEXT" == *'docs: ~/.claude/guides/workflows-and-skills.md § "Waiting without blocking"'* ]]
}

# ---------------------------------------------------------------------------
# ALLOW
# ---------------------------------------------------------------------------

@test "short foreground sleeps pass" {
  decide 'sleep 5'
  [ "$DECISION" = ALLOW ]
  decide 'sleep 10'
  [ "$DECISION" = ALLOW ]
  decide 'sleep 2 && curl -sf localhost:8000'
  [ "$DECISION" = ALLOW ]
}

@test "a short foreground retry loop over a fixed list passes" {
  decide 'for i in 1 2 3; do curl -sf localhost:8000 && break; sleep 2; done'
  [ "$DECISION" = ALLOW ]
}

@test "a background poll at 10 s or less passes" {
  decide 'until curl -sf localhost:8000; do sleep 10; done; echo up' true
  [ "$DECISION" = ALLOW ]
}

@test "a background fixed wait carrying the marker passes" {
  decide 'sleep 60; gh api rate_limit # sleep-guard: required-delay' true
  [ "$DECISION" = ALLOW ]
}

@test "the marker does not excuse a slow background poll" {
  decide 'until gh api x; do sleep 60; done # sleep-guard: required-delay' true
  [ "$DECISION" = DENY ]
}

@test "sleep as an argument, not a command, passes" {
  decide 'echo sleep 60'
  [ "$DECISION" = ALLOW ]
  decide 'rg -n "sleep 60" scripts/'
  [ "$DECISION" = ALLOW ]
  decide "pgrep -f 'sleep 600'"
  [ "$DECISION" = ALLOW ]
  decide 'git log --grep=sleep'
  [ "$DECISION" = ALLOW ]
}

@test "a variable sleep outside a foreground loop passes" {
  decide 'sleep "$delay"'
  [ "$DECISION" = ALLOW ]
}

@test "a command without sleep passes" {
  decide 'while read -r line; do echo "$line"; done < file.txt'
  [ "$DECISION" = ALLOW ]
}
