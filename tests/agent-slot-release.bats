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
  local runner pid
  if [ -n "$AGENT" ]; then
    for pid in $(ps -o pid= --ppid "$AGENT" 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
    kill -KILL "$AGENT" 2>/dev/null || true
  fi
  runner=$(jaq -r '.release.runner_pid // empty' "$SLOT/.git/agent-slot.json" 2>/dev/null || true)
  [ -z "$runner" ] || kill "$runner" 2>/dev/null || true
}

# claude_script COMMAND: the script Claude Code hands its shell for a Bash tool command.
claude_script() {
  local q=${1//\'/\'\"\'\"\'}
  printf "source /dev/null 2>/dev/null || true && eval '%s' < /dev/null && pwd -P >| %s/claude-1a2b-cwd" "$q" "$T"
}

# agent STATUS [JOB [HOOK]]: a stand-in for the slot's Claude in claude agents, with that status; its working directory
# is outside the slot, so only claude agents ties it to the slot. JOB runs as one of its background Bash tool commands,
# a child shell of the shape Claude Code starts, and HOOK as a child `sh -c`, the way Claude runs a hook or its status
# line. agent_status STATUS changes the status it reports, and release_inside has it run release as its own foreground
# Bash tool command.
agent() {
  local job='' inside
  [ -z "${2:-}" ] || job=$(claude_script "$2")
  inside=$(claude_script "cd '$SLOT' && '$AGENT_SLOT' release --output json >'$T/inside.out' 2>'$T/inside.err'; \
echo \$? >'$T/inside.rc'")
  bash -c '
    trap "exit 0" TERM
    if [ -n "$1" ]; then bash -c "$1" & fi
    if [ -n "$4" ]; then sh -c "$4" & fi
    while :; do
      until [ -e "$2" ]; do sleep 0.05; done
      rm -f "$2"
      bash -c "$3"
    done' _ "$job" "$T/go" "$inside" "${3:-}" </dev/null >/dev/null 2>&1 3>&- &
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

# agent_job: prints the PID of the stand-in agent's background Bash tool command while one runs.
agent_job() {
  local pid
  for pid in $(ps -o pid= --ppid "$AGENT"); do
    grep -qaF "$T/inside.rc" "/proc/$pid/cmdline" 2>/dev/null && continue
    grep -qaF claude-1a2b-cwd "/proc/$pid/cmdline" 2>/dev/null && echo "$pid" && return 0
  done
  return 1
}
agent_job_gone() { ! agent_job >/dev/null; }

# release_inside: has the stand-in agent run release, and sets status, output, and stderr from that run.
release_inside() {
  rm -f "$T/inside.rc"
  touch "$T/go"
  eventually test -s "$T/inside.rc"
  status=$(cat "$T/inside.rc") output=$(cat "$T/inside.out") stderr=$(cat "$T/inside.err")
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

# --- background jobs ---------------------------------------------------------------------------------------------------

@test "release refuses while the agent's Claude still runs a background Bash tool command, and names it" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy "until [ -e '$T/ci-done' ]; do sleep 0.1; done"
  eventually agent_job
  local pid command="until [ -e '$T/ci-done' ]; do sleep 0.1; done"
  pid=$(agent_job)
  release
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e --arg v "$pid $command" '.reason == "background-jobs-running" and .value == $v
    and .next_step.command == "agent-slot release --output json"
    and (.message | contains("Stop each one you no longer need")
      and contains("agent-slot release --not-yet '"'<why>'"' --output json"))' <<<"$stderr"
  [ "$(record '.release')" = null ]
  jaq -e -s --argjson pid "$pid" --arg c "$command" 'any(.[]; .event == "release" and .result == "refused"
    and .reason == "background-jobs-running" and .jobs == [{pid: $pid, command: $c}])' "$TEARDOWN_LOG" >/dev/null
}

@test "release goes through once the agent's background job has exited" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy "until [ -e '$T/ci-done' ]; do sleep 0.1; done"
  eventually agent_job
  release
  [ "$status" -eq 1 ]
  touch "$T/ci-done"
  eventually agent_job_gone
  release
  [ "$status" -eq 0 ]
  [ "$(record '.release.runner_pid')" = "$(jaq -r .runner_pid <<<"$output")" ]
}

@test "release run as the agent's own Bash tool command names the agent's other jobs, never its own shell" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy "until [ -e '$T/ci-done' ]; do sleep 0.1; done"
  eventually agent_job
  local pid
  pid=$(agent_job)
  release_inside
  [ "$status" -eq 1 ]
  jaq -e --arg pid "$pid" '.reason == "background-jobs-running"
    and (.value | split("\n") | map(split(" ")[0])) == [$pid]' <<<"$stderr"
  touch "$T/ci-done"
  eventually agent_job_gone
  release_inside
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .already_requested == false' <<<"$output"
}

@test "a child of the agent's Claude that is not a Bash tool command, such as a hook, is no job" {
  finished_task
  ran ce-compound ce-compound-refresh
  agent busy "" "touch '$T/hook-ran'; sleep 30; : ~/.claude/slot-status.sh"
  eventually test -e "$T/hook-ran"
  release
  [ "$status" -eq 0 ]
}

# --- not yet ready to release ------------------------------------------------------------------------------------------

@test "an agent that says it is not ready is held off the needs-you list, reminded once later, then listed" {
  finished_task
  agent idle
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  jaq -e '.closing_sent == ["repoa/1"]' <<<"$output"
  run --separate-stderr bash -c 'cd "$1" && "$2" release --not-yet "release.yml run 42 has not finished" --output json' \
    _ "$SLOT" "$AGENT_SLOT"
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .not_yet.why == "release.yml run 42 has not finished"' <<<"$output"
  [ "$(record '.release')" = null ]
  logged 'any(.[]; .event == "release" and .result == "not-yet" and .why == "release.yml run 42 has not finished")'
  : >"$STUBS/typed-repoa-1"
  AGENT_SLOT_RELEASE_REMIND=3600 run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.needs_you == [] and .not_yet == ["repoa/1"] and .reminded == [] and .torn_down == []' <<<"$output"
  [ ! -s "$STUBS/typed-repoa-1" ]
  AGENT_SLOT_RELEASE_REMIND=0 run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.needs_you == [] and .reminded == ["repoa/1"]' <<<"$output"
  grep -qF 'You said this slot was not ready to release: release.yml run 42 has not finished.' "$STUBS/typed-repoa-1"
  grep -qF 'agent-slot release --output json' "$STUBS/typed-repoa-1"
  logged 'any(.[]; .event == "sweep" and .reminded == ["repoa/1"])'
  : >"$STUBS/typed-repoa-1"
  AGENT_SLOT_RELEASE_REMIND=0 run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  [ "$status" -eq 0 ]
  jaq -e '.reminded == [] and .needs_you[0].needs_you[0].code == "not-released"
    and (.needs_you[0].needs_you[0].message | contains("was reminded at"))' <<<"$output"
  [ ! -s "$STUBS/typed-repoa-1" ]
  [ -d "$SLOT" ]
}

@test "an agent busy on the job it said it waits on is not listed, and one that is gone is" {
  finished_task
  agent busy "until [ -e '$T/ci-done' ]; do sleep 0.1; done"
  run --separate-stderr bash -c 'cd "$1" && "$2" release --not-yet "CI on the release chain" --output json' \
    _ "$SLOT" "$AGENT_SLOT"
  [ "$status" -eq 0 ]
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  jaq -e '.needs_you == [] and .not_yet == ["repoa/1"]' <<<"$output"
  echo '[]' >"$STUBS/claude-agents.json"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --auto --output json
  jaq -e '.not_yet == [] and .needs_you[0].needs_you[0].code == "not-released"' <<<"$output"
}

@test "release --not-yet needs a reason, and a release clears the one recorded" {
  finished_task
  run --separate-stderr bash -c 'cd "$1" && "$2" release --not-yet " " --output json' _ "$SLOT" "$AGENT_SLOT"
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  run --separate-stderr bash -c 'cd "$1" && "$2" release --not-yet "waiting" --output json' _ "$SLOT" "$AGENT_SLOT"
  [ "$status" -eq 0 ]
  ran ce-compound ce-compound-refresh
  agent busy
  release
  [ "$status" -eq 0 ]
  [ "$(record '.not_yet')" = null ]
}

# --- the release and its teardown--------------------------------------------------------------------------------------

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
  grep -qF 'then stop every background job you no longer need; then run agent-slot release' "$STUBS/typed-repoa-1"
  grep -qF "If you are still waiting on something, such as CI or a release chain, never stop it to pass release's \
check: say what with agent-slot release --not-yet '<why>' --output json, and release when it is done." \
    "$STUBS/typed-repoa-1"
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
