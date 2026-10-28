#!/usr/bin/env bats
# agent-slot release and the automatic sweep: a slot's agent hands its teardown upstream once it has run the closing
# skills, a detached finish tears the slot down once the agent is idle, and the timer's sweep tears down only what was
# released or finished by the operator, sending a finished slot's idle agent its closing steps instead.
#
# Run: bats tests/agent-slot-release.bats

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  export AGENT_SLOT_RELEASE_POLL=0.2 AGENT_SLOT_RELEASE_WAIT=20
  TEARDOWN_LOG=$AGENT_SLOT_STATE_DIR/teardown.log
  AGENT=
}

teardown() {
  local runner
  [ -z "$AGENT" ] || kill -KILL "$AGENT" 2>/dev/null || true
  runner=$(jaq -r '.release.runner_pid // empty' "$SLOT/.git/agent-slot.json" 2>/dev/null || true)
  [ -z "$runner" ] || kill "$runner" 2>/dev/null || true
}

# agent STATUS: a stand-in for the slot's Claude in claude agents, with that status; its working directory is outside
# the slot, so only claude agents ties it to the slot. agent_status STATUS changes the status it reports.
agent() {
  bash -c "trap 'exit 0' TERM; sleep 120 & wait" </dev/null >/dev/null 2>&1 3>&- &
  AGENT=$!
  agent_status "$1"
}
agent_status() {
  jaq -n -c --arg cwd "$SLOT" --argjson pid "$AGENT" --arg s "$1" '[{pid: $pid, cwd: $cwd, status: $s, sessionId: "s1"}]' \
    >"$STUBS/claude-agents.json"
}

# ran SKILL...: the slot's session transcript holds a Skill call for each, as the agent's own tool calls.
ran() {
  local skill
  : >"$T/transcript.jsonl"
  for skill in "$@"; do
    jaq -n -c --arg s "compound-engineering:$skill" \
      '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: $s, args: "x"}}]}}' \
      >>"$T/transcript.jsonl"
  done
  record_set ".transcript = \"$T/transcript.jsonl\""
}

record_set() {
  jaq -c "$1" "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
}
record() { jaq -r "$1" "$SLOT/.git/agent-slot.json"; }

release() {
  run --separate-stderr bash -c 'cd "$1" && shift && "$@"' _ "$SLOT" "$AGENT_SLOT" release --output json
}

# eventually COMMAND...: retries the command for up to 15 s until it succeeds.
eventually() {
  local i
  for ((i = 0; i < 150; i++)); do
    "$@" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "never true: $*" >&2
  cat "$TEARDOWN_LOG" "$AGENT_SLOT_STATE_DIR"/logs/release-* >&2 2>/dev/null || true
  return 1
}
gone() { [ ! -e "$SLOT" ]; }
logged() { jaq -e -s "$1" "$TEARDOWN_LOG" >/dev/null; }

# --- the gate ----------------------------------------------------------------------------------------------------------

@test "release refuses until the slot's session has run both ce-compound and ce-compound-refresh" {
  finished_task
  ran ce-compound
  release
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "compound-not-run" and .value == "ce-compound-refresh"
    and (.next_step.command | startswith("/compound-engineering:ce-compound-refresh "))' <<<"$stderr"
  [ "$(record '.release')" = null ]
  logged 'any(.[]; .event == "release" and .result == "refused" and .missing == ["ce-compound-refresh"])'
  [ -d "$SLOT" ]
}

@test "a skill named only in a tool's result, or typed as a slash command, is told apart" {
  finished_task
  jaq -n -c '{type: "user", message: {content: [{type: "tool_result",
    content: "<command-name>/compound-engineering:ce-compound</command-name> \"skill\":\"ce-compound-refresh\""}]}}' \
    >"$T/transcript.jsonl"
  record_set ".transcript = \"$T/transcript.jsonl\""
  release
  [ "$status" -eq 1 ]
  jaq -e '.reason == "compound-not-run" and .value == "ce-compound ce-compound-refresh"' <<<"$stderr"
  jaq -n -c '{type: "user", message: {content: "<command-message>compound-engineering:ce-compound</command-message>\n<command-name>/compound-engineering:ce-compound</command-name>"}}' \
    >>"$T/transcript.jsonl"
  jaq -n -c '{type: "user", message: {content: "<command-name>/compound-engineering:ce-compound-refresh</command-name>"}}' \
    >>"$T/transcript.jsonl"
  agent busy
  release
  [ "$status" -eq 0 ]
}

@test "the gate reads every session the slot's task has had, from the ledger" {
  finished_task
  jaq -n -c '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill",
    input: {skill: "compound-engineering:ce-compound"}}]}}' >"$T/first.jsonl"
  printf '{"event":"session","ts":"2026-01-02T00:00:00Z","repo":"repoa","slot":1,"transcript":"%s"}\n' \
    "$T/first.jsonl" >>"$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  ran ce-compound-refresh
  agent busy
  release
  [ "$status" -eq 0 ]
}

# --- the release and its teardown --------------------------------------------------------------------------------------

@test "release records the request and starts the teardown in its own session, outside the slot" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy
  release
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and (.runner_pid | type == "number")' <<<"$output"
  local runner
  runner=$(jaq -r .runner_pid <<<"$output")
  [ "$(record '.release.runner_pid')" = "$runner" ]
  [ "$(record '.release.requested_at | test("^[0-9]{4}-")')" = true ]
  jaq -e -s 'any(.[]; .event == "release" and .repo == "repoa" and .slot == 1)' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  [ "$(readlink "/proc/$runner/cwd")" = / ]
  [ "$(ps -o sid= -p "$runner" | tr -d ' ')" = "$runner" ]
  tr '\0' ' ' <"/proc/$runner/cmdline" | grep -q 'finish repoa/1 --yes --when-idle --output json'
  run ! grep -q '^TMUX=' <(tr '\0' '\n' <"/proc/$runner/environ")
  [ -d "$SLOT" ]
  logged 'any(.[]; .event == "release" and .result == "requested" and .key == "repoa/1")'
}

@test "the teardown waits for the agent to go idle, then removes a finished slot" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy
  release
  [ "$status" -eq 0 ]
  sleep 1
  [ -d "$SLOT" ]
  agent_status idle
  eventually gone
  eventually logged 'any(.[]; .event == "finish" and .by == "release" and .result == "torn-down" and .key == "repoa/1")'
}

@test "an unfinished slot stays requested, and the automatic sweep removes it once its PR merges" {
  work feat/x 2
  git -C "$SLOT" push -q origin feat/x
  pr 7 OPEN feat/x
  ran ce-compound ce-compound-refresh
  agent idle
  release
  [ "$status" -eq 0 ]
  eventually logged 'any(.[]; .event == "finish" and .by == "release" and .result == "refused"
    and .reason == "task-has-open-pr")'
  [ -d "$SLOT" ]
  [ "$(record '.release != null')" = true ]
  jaq -c 'map(.state = "MERGED")' "$STUBS/gh-prs.json" >"$T/prs" && mv "$T/prs" "$STUBS/gh-prs.json"
  squash_merge feat/x
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  gone
  logged 'any(.[]; .event == "sweep" and .by == "timer" and .torn_down == ["repoa/1"])'
}

@test "a slot that needs the operator is never removed, by its release or by the automatic sweep" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'not pushed'
  ran ce-compound ce-compound-refresh
  agent idle
  release
  [ "$status" -eq 0 ]
  eventually logged 'any(.[]; .event == "finish" and .by == "release" and .result == "refused"
    and .reason == "teardown-blocked")'
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and (.needs_you[0].needs_you[0].code == "unpushed-commits")' <<<"$output"
  [ -d "$SLOT" ]
}

# --- the automatic sweep -----------------------------------------------------------------------------------------------

@test "the automatic sweep keeps a finished slot that never released and types its idle agent the closing steps, once" {
  finished_task
  agent idle
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and .closing_sent == ["repoa/1"]' <<<"$output"
  [ -d "$SLOT" ]
  grep -q '/compound-engineering:ce-compound mode:non-interactive depth:full' "$STUBS/typed-repoa-1"
  grep -q '/compound-engineering:ce-compound-refresh .* mode:non-interactive' "$STUBS/typed-repoa-1"
  grep -q 'agent-slot release --output json' "$STUBS/typed-repoa-1"
  [ "$(record '.closing_sent_at | test("^[0-9]{4}-")')" = true ]
  logged 'any(.[]; .event == "sweep" and .by == "timer" and .closing_sent == ["repoa/1"])'
  : >"$STUBS/typed-repoa-1"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.closing_sent == [] and .needs_you[0].needs_you[0].code == "not-released"' <<<"$output"
  [ ! -s "$STUBS/typed-repoa-1" ]
  [ -d "$SLOT" ]
}

@test "the automatic sweep lists a finished slot whose agent is gone as needing the operator" {
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and .needs_you[0].key == "repoa/1" and .needs_you[0].needs_you[0].code == "not-released"' \
    <<<"$output"
  [ -d "$SLOT" ]
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0].needs_you[0].code == "not-released"' <<<"$output"
}

@test "the operator's sweep still tears down a finished slot its agent never released" {
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  gone
  logged 'any(.[]; .event == "sweep" and .by == "operator" and .torn_down == ["repoa/1"])'
}

@test "the automatic sweep tears down a finished slot the operator marked finished" {
  record_set '.finished_by_operator = true'
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
}

# --- the timer ---------------------------------------------------------------------------------------------------------

@test "the sweep timer runs the automatic sweep, waits for its pushes, and ships in a deployed stow package" {
  local unit=$BATS_TEST_DIRNAME/../stow/local/dot-config/systemd/user
  grep -qx 'ExecStart=%h/.local/bin/agent-slot sweep --yes --auto --output json' "$unit/agent-slot-sweep.service"
  grep -qx 'Environment=AGENT_SLOT_PUSH_WAIT=1' "$unit/agent-slot-sweep.service"
  grep -qx 'Type=oneshot' "$unit/agent-slot-sweep.service"
  grep -qxF 'OnCalendar=*:0/10' "$unit/agent-slot-sweep.timer"
  grep -qx 'WantedBy=timers.target' "$unit/agent-slot-sweep.timer"
  grep -qE '^SHARED_PACKAGES=\(.* local .*\)$' "$BATS_TEST_DIRNAME/../scripts/stow-deploy"
}
