#!/usr/bin/env bats
# agent-slot sweep and finish: deleting only the slots check passes, and nothing written after the verdict.
#
# Run: bats tests/agent-slot-teardown.bats
#
# Fixtures only: the slot root, home, and trash are sandboxed, and the trash is a stub that copies before it deletes.

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
  AGENT=
}

teardown() {
  [ -z "$AGENT" ] || kill -KILL "$AGENT" 2>/dev/null || true
}

# idle_agent [ON-TERM]: a stand-in for the slot's Claude, idle in claude agents, running ON-TERM when stopped. Its
# working directory is outside the slot, so only claude agents ties it to the slot.
idle_agent() {
  bash -c "trap '${1:-:}; exit 0' TERM; sleep 120 & wait" </dev/null >/dev/null 2>&1 3>&- &
  AGENT=$!
  jaq -n -c --arg cwd "$SLOT" --argjson pid "$AGENT" '[{pid: $pid, cwd: $cwd, status: "idle", sessionId: "s1"}]' \
    >"$STUBS/claude-agents.json"
}

record() { jaq -r "$1" "$SLOT/.git/agent-slot.json"; }

@test "AE7: sweep --yes stops a finished, clean, idle slot's agent, kills its sessions, trashes it, and keeps its history" {
  finished_task
  idle_agent "touch '$T/agent-stopped'"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"] and .needs_you == []' <<<"$output"
  [ -f "$T/agent-stopped" ]
  [ ! -e "$SLOT" ]
  [ -d "$STUBS/trashed/1/.git" ]
  [ ! -s "$STUBS/tmux-sessions" ]
  jaq -e -s 'map(select(.event == "teardown")) | .[-1] | .repo == "repoa" and .slot == 1
    and .session_id == "s1" and .transcript == "/t/s1.jsonl" and .prs == [7]' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots == []' <<<"$output"
}

@test "teardown also stops the processes the agent started" {
  finished_task
  idle_agent
  local child n=0
  until child=$(pgrep -P "$AGENT" sleep) || ((n++ > 50)); do sleep 0.1; done
  [ -n "$child" ]
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  n=0
  while kill -0 "$child" 2>/dev/null && ((n++ < 30)); do sleep 0.1; done
  run ! kill -0 "$child"
}

@test "finish --yes tears down a finished slot whose only change is setup re-pointing a tracked docs/solutions link" {
  origin_symlink repoa docs/solutions ../../dev/solutions-docs
  git -C "$SLOT" pull -q origin main
  ln -sfn "$AGENT_SLOT_SOLUTIONS" "$SLOT/docs/solutions"
  finished_task
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "AE12: finish --yes on a task with an open PR exits 1 with task-has-open-pr and deletes nothing" {
  work feat/x
  git -C "$SLOT" push -q origin feat/x
  pr 11 OPEN feat/x
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "task-has-open-pr" and (.message | test("#11"))' <<<"$stderr"
  [ -d "$SLOT/.git" ]
  [ "$(record .finished_by_operator)" = false ]
}

@test "finish --yes tears down a task that never had a PR, with every commit on an origin branch" {
  work feat/w
  git -C "$SLOT" push -q origin feat/w
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "AE13: finish --yes tears down a task whose only PR closed without merging, once its head holds every commit" {
  work feat/y
  git -C "$SLOT" push -q origin feat/y
  pr 9 CLOSED feat/y
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  [ ! -e "$SLOT" ]
}

@test "sweep --yes alone leaves the closed-unmerged task listed with pr-closed-unmerged" {
  work feat/y
  git -C "$SLOT" push -q origin feat/y
  pr 9 CLOSED feat/y
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and .needs_you[0].key == "repoa/1"
    and .needs_you[0].needs_you[0].code == "pr-closed-unmerged"' <<<"$output"
  [ -d "$SLOT/.git" ]
}

@test "sweep without --yes reports what it would delete and deletes nothing" {
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --output json
  [ "$status" -eq 0 ]
  jaq -e '.dry_run == true and .would_tear_down == ["repoa/1"] and .torn_down == []' <<<"$output"
  [ -d "$SLOT/.git" ]
  [ "$(grep -c 'kill-session' "$CALLS")" -eq 0 ]
}

@test "finish without --yes reports and changes nothing" {
  work feat/w
  git -C "$SLOT" push -q origin feat/w
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.dry_run == true and .would_tear_down == true' <<<"$output"
  [ "$(record .finished_by_operator)" = false ]
  [ -d "$SLOT/.git" ]
}

@test "a file written between the verdict and the re-check stops the teardown, keeps the sessions, and lists the slot" {
  finished_task
  idle_agent "touch '$SLOT/late-notes.txt'"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and (.needs_you[0].needs_you[] | select(.code == "untracked-files")
    | .values == ["late-notes.txt"])' <<<"$output"
  [ -d "$SLOT/.git" ]
  [ "$(record .state)" = active ]
  [ "$(record '.last_check.blockers[0].code')" = untracked-files ]
  [ "$(grep -c 'kill-session' "$CALLS")" -eq 0 ]
}

@test "a commit made while the agent stops keeps the slot with unpushed-commits" {
  finished_task
  idle_agent "git -C '$SLOT' commit -q --allow-empty -m late"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and any(.needs_you[0].needs_you[]; .code == "unpushed-commits")' <<<"$output"
  [ -d "$SLOT/.git" ]
  [ "$(grep -c 'kill-session' "$CALLS")" -eq 0 ]
}

@test "a stash made while the agent stops keeps the slot with stash-present" {
  finished_task
  idle_agent "echo late >'$SLOT/late.txt' && git -C '$SLOT' stash -q -u"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and any(.needs_you[0].needs_you[]; .code == "stash-present")' <<<"$output"
  [ -d "$SLOT/.git" ]
}

@test "a stash lookup that fails during the re-check keeps the slot with git-state-unknown" {
  finished_task
  idle_agent "echo 0000000000000000000000000000000000000001 >'$SLOT/.git/refs/stash'"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and any(.needs_you[0].needs_you[]; .code == "git-state-unknown"
    and .message == "git stash list failed in the slot")' <<<"$output"
  [ -d "$SLOT/.git" ]
}

@test "an agent that turns busy after the verdict is not stopped, and the slot is kept" {
  finished_task
  idle_agent "touch '$T/agent-stopped'"
  stub gh 'jaq -c "map(.status = \"busy\")" "$STUBS/claude-agents.json" >"$STUBS/agents.new"
mv "$STUBS/agents.new" "$STUBS/claude-agents.json"
cat "$STUBS/gh-prs.json"'
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and any(.needs_you[0].needs_you[]; .code == "agent-not-idle")' <<<"$output"
  [ ! -e "$T/agent-stopped" ]
  [ -d "$SLOT/.git" ]
  [ "$(record .state)" = active ]
}

@test "a trash that fails leaves the slot active, so it can be resumed" {
  finished_task
  stub trash '[ "$1" != --version ] || { echo "trash 0.test"; exit 0; }
exit 1'
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "script-error"' <<<"$stderr"
  [ "$(record .state)" = active ]
}

@test "a slot a dead teardown left tearing-down is judged again and torn down" {
  finished_task
  jaq -c '.state = "tearing-down"' "$SLOT/.git/agent-slot.json" >"$T/record" && mv "$T/record" "$SLOT/.git/agent-slot.json"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
}

@test "a slot path that resolves outside the slot root is refused before anything is trashed" {
  work feat/w
  git -C "$SLOT" push -q origin feat/w
  mv "$SLOT" "$T/outside-clone"
  ln -s "$T/outside-clone" "$SLOT"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "slot-outside-root"' <<<"$stderr"
  [ -d "$T/outside-clone/.git" ]
  [ "$(grep -c '^trash /' "$CALLS")" -eq 0 ]
}

@test "sweep skips a slot whose lock is held and lists it as slot-busy" {
  finished_task
  flock "$AGENT_SLOT_ROOT/repoa/.1.lock" sleep 60 3>&- &
  AGENT=$!
  local n=0
  until [ -n "$(find "/proc/$AGENT/fd" -lname "$AGENT_SLOT_ROOT/repoa/.1.lock" 2>/dev/null)" ] || ((n++ > 50)); do
    sleep 0.1
  done
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and .needs_you[0].needs_you[0].code == "slot-busy"' <<<"$output"
  [ -d "$SLOT/.git" ]
}

@test "a torn-down task's conversation stays resumable: the ledger keeps its session and transcript" {
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  [ "$(jaq -r -s 'map(select(.event == "teardown"))[-1] | "\(.session_id) \(.transcript)"' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl")" = "s1 /t/s1.jsonl" ]
}
