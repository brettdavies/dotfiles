#!/usr/bin/env bats
# The subagent watchdog command in the workflows guide, run as written: it exits once the agent's output file shows the
# agent finished or has gone 10 minutes without a write, keeps waiting on a live agent, and passes the sleep guard when
# backgrounded.
#
# Run: bats tests/subagent-watchdog.bats

GUIDE="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/guides/workflows-and-skills.md"
HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/sleep-guard.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/projects"
}

# watchdog: the guide's watchdog block, the first bash fence after its heading.
watchdog() {
  awk '/^\*\*Watchdog for a background subagent\.\*\*/ { s = 1 }
    s && /^```bash$/ { f = 1; next }
    f && /^```$/ { exit }
    f' "$GUIDE"
}

# transcript LINE...: an agent output file, a symlink to a transcript holding the lines, as the Agent tool hands out.
transcript() {
  printf '%s\n' "$@" >"$T/projects/agent-a1.jsonl"
  ln -sf "$T/projects/agent-a1.jsonl" "$T/agent-a1.output"
  OUT=$T/agent-a1.output
}

# aged MINUTES: sets the transcript's modification time that many minutes back.
aged() {
  perl -e 'my $t = time - 60 * shift; utime $t, $t, @ARGV' "$1" "$T/projects/agent-a1.jsonl"
}

# run_watchdog: runs the block against OUT for up to 3 s; status 124 when it was still waiting.
run_watchdog() {
  local script pid i
  script=$(watchdog | sed "s|<agent output file>|$OUT|")
  bash -c "$script" >"$T/watchdog.out" 2>&1 3>&- &
  pid=$!
  for ((i = 0; i < 30; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    status=124
  else
    if wait "$pid"; then status=0; else status=$?; fi
  fi
  output=$(cat "$T/watchdog.out")
}

TOOL_USE='{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}'
END_TURN='{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}'
HANDBACK='{"type":"user","toolUseResult":{"success":true,"message":"Report delivered to your caller."},"message":{"content":[{"type":"tool_result"}]}}'

@test "the guide holds a watchdog block that names the agent output file" {
  [[ $(watchdog) == *"out=<agent output file>"* ]]
}

@test "the watchdog exits at once on an agent whose last message ended its turn" {
  transcript "$TOOL_USE" "$END_TURN"
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "agent finished: $OUT" ]
}

@test "the watchdog exits at once on an agent that handed its report back" {
  transcript "$TOOL_USE" "$HANDBACK"
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "agent finished: $OUT" ]
}

@test "the watchdog keeps waiting on an agent that is still writing" {
  transcript "$END_TURN" '{"type":"user","message":{"content":"The coordinator sent a message"}}' "$TOOL_USE"
  run_watchdog
  [ "$status" -eq 124 ]
}

@test "the watchdog exits on an agent whose output file has gone 10 minutes without a write" {
  transcript "$TOOL_USE"
  aged 11
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "agent quiet 10 min: $OUT" ]
}

@test "the sleep guard lets the watchdog run in the background and denies it in the foreground" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  local cmd out
  cmd=$(watchdog)
  out=$(jaq -n --arg cmd "$cmd" '{tool_input: {command: $cmd, run_in_background: true}}' | "$HOOK")
  [ -z "$out" ]
  out=$(jaq -n --arg cmd "$cmd" '{tool_input: {command: $cmd, run_in_background: false}}' | "$HOOK")
  jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null
}
