#!/usr/bin/env bats
# agent-slot retask: a live slot takes a new task in a new Claude session, so one conversation never carries two tasks.
#
# Run: bats tests/agent-slot-retask.bats
#
# Fixtures only: tmux is a stub that records its calls, and the agent is a stand-in process that claude agents lists.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  printf 'Scope: x\nLimits: y\nReviews: ce-code-review\nReports to: z\nTouches: src/**\nAdds: none\n' >"$T/brief.md"
  AGENT=
}

teardown() {
  stop_spawned
  assert_no_leaks
}

record() { jaq -r "$1" "$SLOT/.git/agent-slot.json"; }

edit_record() {
  jaq "$1" "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
}

typed() { cat "$STUBS/typed-repoa-1"; }

listed() {
  jaq -n -c --arg cwd "$SLOT" --argjson pid "$2" --arg state "$1" \
    '[{pid: $pid, cwd: $cwd, status: $state, sessionId: "s1"}]' >"$STUBS/claude-agents.json"
}

agent() {
  spawn bash -c "trap 'exit 0' TERM; sleep 120 & wait" </dev/null >/dev/null 2>&1 3>&-
  AGENT=$!
  listed "$1" "$AGENT"
}

alive() { kill -0 "$AGENT" 2>/dev/null; }

retask() { run --separate-stderr "$AGENT_SLOT" retask repoa/1 "$@" --output json; }

ledger_line() { jaq -c --arg e "$1" 'select(.event == $e)' "$AGENT_SLOT_STATE_DIR/ledger.jsonl" | tail -1; }

@test "an idle slot's new task starts a new session under its own name, with its own brief" {
  agent idle
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  result=$output
  new=$(record .session_id)
  [ "$new" != s1 ]
  [ "$(record .task)" = next-task ]
  [ "$(record .name)" = next-task ]
  [ "$(record .named_as)" = next-task ]
  [ "$(record '.scope.touches[0]')" = 'src/**' ]
  run ! alive
  [[ $(typed) == *"--session-id $new -n next-task -- \"\$(cat "* ]]
  [[ $(typed) != *--resume* ]]
  grep -q 'Scope: x' "$SLOT/.git/agent-slot-prompt.md"
  [ "$(jaq -r .session_id <<<"$result")" = "$new" ]
  [ "$(jaq -r .previous_session_id <<<"$result")" = s1 ]
}

@test "the previous session stays on the record and in the ledger, so it can still be found" {
  agent idle
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  [ "$(record '.prior_sessions[0].session_id')" = s1 ]
  [ "$(record '.prior_sessions[0].task')" = t1 ]
  [ "$(ledger_line retask | jaq -r .session_id)" = s1 ]
  [ "$(ledger_line retask | jaq -r .transcript)" != null ]
}

@test "the old task's close-out state goes with it" {
  edit_record '. + {prs: [7], release: {id: "r"}, not_yet: ["x"], reminded_at: "t", closing_sent_at: "t",
    cleanup_sent_at: "t", finished_by_operator: true}'
  agent idle
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  [ "$(record '.prs | length')" = 0 ]
  [ "$(record '[.release, .not_yet, .reminded_at, .closing_sent_at, .cleanup_sent_at] | map(select(. != null)) | length')" = 0 ]
  [ "$(record .finished_by_operator)" = false ]
  [ "$(record .task_started_at)" != null ]
}

@test "the new task starts on the base, and the old task's pushed branch is gone from the clone but kept in the ledger" {
  git -C "$SLOT" switch -q -c feat/old
  git -C "$SLOT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m old
  git -C "$SLOT" push -q -u origin feat/old
  git -C "$SLOT" push -q origin 'HEAD:refs/pull/7/head'
  pr_listed 7 OPEN feat/old "$(git -C "$SLOT" rev-parse HEAD)" 2026-01-02T00:00:00Z
  edit_record '.prs = [7]'
  agent idle
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SLOT" branch --show-current)" = main ]
  run ! git -C "$SLOT" rev-parse --verify -q refs/heads/feat/old
  [ "$(ledger_line retask | jaq -r '.branches[0].name')" = feat/old ]
}

@test "an issue names the session and becomes the slot's item" {
  echo '{"number": 12, "title": "fix login", "state": "open"}' >"$STUBS/gh-issue-12.json"
  agent idle
  retask --issue 12 --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  [ "$(record '.items[0].number')" = 12 ]
  [[ $(record .name) == *issue12* ]]
  [[ $(typed) == *"-n $(record .name)"* ]]
}

@test "work the old task has not pushed is refused, and nothing changes" {
  echo change >"$SLOT/new-file"
  agent idle
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -ne 0 ]
  [ "$(jaq -r .reason <<<"$stderr")" = slot-work-unfinished ]
  [ "$(jaq -r .value <<<"$stderr")" = untracked-files ]
  [ "$(record .session_id)" = s1 ]
  alive
  [ ! -e "$STUBS/typed-repoa-1" ]
}

@test "a busy agent is refused and left running, as resume --model leaves it" {
  agent busy
  retask --task next-task --prompt-file "$T/brief.md"
  [ "$status" -ne 0 ]
  [ "$(jaq -r .reason <<<"$stderr")" = agent-busy ]
  [[ $(jaq -r .next_step.command <<<"$stderr") == *"agent-slot retask repoa/1"* ]]
  [ "$(record .session_id)" = s1 ]
  alive
}

@test "a retask needs a name for the session and a whole brief" {
  retask --prompt-file "$T/brief.md"
  [ "$status" -ne 0 ]
  [[ $(jaq -r .message <<<"$stderr") == *'--task'* ]]
  retask --task next-task
  [ "$status" -ne 0 ]
  [[ $(jaq -r .message <<<"$stderr") == *'--prompt-file'* ]]
  echo 'Scope: only' >"$T/thin.md"
  retask --task next-task --prompt-file "$T/thin.md"
  [ "$status" -ne 0 ]
  [ "$(jaq -r .reason <<<"$stderr")" = brief-incomplete ]
  [ "$(record .session_id)" = s1 ]
}

@test "a PR's work starts with launch, which checks its head out" {
  retask --pr 7 --prompt-file "$T/brief.md"
  [ "$status" -ne 0 ]
  [[ $(jaq -r .message <<<"$stderr") == *'launch --pr'* ]]
}

@test "launch's held-slot refusal names retask for a new task" {
  run grep -c 'agent-slot retask' "$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/launch.sh"
  [ "$output" -ge 1 ]
}
