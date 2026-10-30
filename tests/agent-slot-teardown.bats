#!/usr/bin/env bats
# agent-slot sweep and finish: deleting only the slots check passes, and nothing written after the verdict.
#
# Run: bats tests/agent-slot-teardown.bats
#
# Fixtures only: the slot root, home, and trash are sandboxed, and the trash is trash-cli writing to a trash under the
# test's directory.

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
  AGENT=
}

teardown() {
  [ ! -d "$TRASH/files" ] || chmod u+w "$TRASH/files"
  stop_spawned
  assert_no_leaks
}

# idle_agent [ON-TERM]: a stand-in for the slot's Claude, idle in claude agents, running ON-TERM when stopped. Its
# working directory is outside the slot, so only claude agents ties it to the slot.
idle_agent() {
  spawn bash -c "trap '${1:-:}; exit 0' TERM; sleep 120 & wait" </dev/null >/dev/null 2>&1 3>&-
  AGENT=$!
  jaq -n -c --arg cwd "$SLOT" --argjson pid "$AGENT" '[{pid: $pid, cwd: $cwd, status: "idle", sessionId: "s1"}]' \
    >"$STUBS/claude-agents.json"
}

record() { jaq -r "$1" "$SLOT/.git/agent-slot.json"; }

# trash_entries: the sandbox trash's entries, one name per line, from both its files and its info directories.
trash_entries() {
  find "$TRASH/files" "$TRASH/info" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sed 's/\.trashinfo$//'
}

# last_event FILE EVENT: the last line of a JSON-lines log whose event is EVENT.
last_event() { jaq -c -s --arg e "$2" 'map(select(.event == $e))[-1]' "$1"; }

@test "AE7: sweep --yes stops a finished, clean, idle slot's agent, kills its sessions, deletes it, and keeps its history" {
  finished_task
  idle_agent "touch '$T/agent-stopped'"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"] and .needs_you == [] and .purge_failed == []
    and .slots[0].purge.purged == true' <<<"$output"
  [ -f "$T/agent-stopped" ]
  [ ! -e "$SLOT" ]
  [ -z "$(trash_entries)" ]
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

@test "finish --yes tears down a finished slot whose only extra file is Claude Code's scheduler lock" {
  finished_task
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/.claude"
  echo '{"sessionId":"s1","pid":1,"acquiredAt":0}' >"$SLOT/.claude/scheduled_tasks.lock"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "finish --yes keeps a slot whose .claude/ holds a file the task wrote beside the scheduler lock" {
  finished_task
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/.claude/commands"
  echo '{"sessionId":"s1","pid":1,"acquiredAt":0}' >"$SLOT/.claude/scheduled_tasks.lock"
  touch "$SLOT/.claude/commands/new.md"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "teardown-blocked" and (.message | endswith(": 1 untracked file: .claude/commands/new.md"))' \
    <<<"$stderr"
  [ -f "$SLOT/.claude/commands/new.md" ]
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

@test "a stash made while the agent stops keeps the slot with the stash-present blocker check reports" {
  finished_task
  idle_agent "echo late >'$SLOT/late.txt' && git -C '$SLOT' stash -q -u"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == [] and any(.needs_you[0].needs_you[];
    . == {code: "stash-present", message: "1 stash entry", count: 1})' <<<"$output"
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

@test "finish --yes purges the clone from the trash and reports it in the result, the ledger, and teardown.log" {
  finished_task
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e --arg e "$TRASH/files/1" '.torn_down == true and .purge.purged == true and .purge.entry == $e
    and (.purge.ms | type == "number")' <<<"$output"
  [ ! -e "$SLOT" ]
  [ -z "$(trash_entries)" ]
  jaq -e --arg e "$TRASH/files/1" '.trash_entry == $e' <<<"$(last_event "$AGENT_SLOT_STATE_DIR/ledger.jsonl" teardown)"
  jaq -e --arg e "$TRASH/files/1" '.repo == "repoa" and .slot == 1 and .purged == true and .entry == $e' \
    <<<"$(last_event "$AGENT_SLOT_STATE_DIR/ledger.jsonl" purge)"
  jaq -e '.result == "torn-down" and .purge.purged == true' \
    <<<"$(last_event "$AGENT_SLOT_STATE_DIR/teardown.log" finish)"
}

@test "a purge deletes only its own entry: an earlier copy of the slot, a same-named entry, and another entry stay" {
  finished_task
  mkdir -p "$T/other/1"
  touch "$T/other/1/kept"
  "$STUBS/trash" "$T/other/1"
  mv "$SLOT" "$T/hold"
  mkdir "$SLOT"
  touch "$SLOT/earlier"
  "$STUBS/trash" "$SLOT"
  mv "$T/hold" "$SLOT"
  echo notes >"$T/notes.md"
  "$STUBS/trash" "$T/notes.md"
  [ "$(trash_entries | sort -u | paste -sd ' ')" = "1 1_1 notes.md" ]
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e --arg e "$TRASH/files/1_2" '.purge.purged == true and .purge.entry == $e' <<<"$output"
  [ "$(trash_entries | sort | paste -sd ' ')" = "1 1 1_1 1_1 notes.md notes.md" ]
  [ -f "$TRASH/files/1/kept" ]
  [ -f "$TRASH/files/1_1/earlier" ]
  grep -qxF "Path=$SLOT" "$TRASH/info/1_1.trashinfo"
  [ "$(cat "$TRASH/files/notes.md")" = notes ]
}

@test "a purge that fails leaves the slot torn down and reports the entry and a next step" {
  finished_task
  trash_stub "chmod 555 '$TRASH/files'"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e --arg e "$TRASH/files/1" --arg cmd "trash-rm $SLOT" '.torn_down == true and .purge.purged == false
    and .purge.code == "purge-failed" and .purge.entry == $e and .purge.next_step.action == "run"
    and .purge.next_step.command == $cmd and (.purge.next_step.docs | endswith("#purge-failures"))
    and (.purge.log | type == "string")' <<<"$output"
  [ ! -e "$SLOT" ]
  [ -f "$TRASH/info/1.trashinfo" ]
  jaq -e '.purged == false and .code == "purge-failed"' <<<"$(last_event "$AGENT_SLOT_STATE_DIR/ledger.jsonl" purge)"
  jaq -e '.result == "torn-down" and .purge.code == "purge-failed"' \
    <<<"$(last_event "$AGENT_SLOT_STATE_DIR/teardown.log" finish)"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots == []' <<<"$output"
}

@test "sweep --yes names a slot whose purge failed, in its text and in teardown.log" {
  finished_task
  trash_stub "chmod 555 '$TRASH/files'"
  run --separate-stderr "$AGENT_SLOT" sweep --yes
  [ "$status" -eq 0 ]
  [[ $output == *"torn down"$'\t'"repoa/1"* ]]
  [[ $output == *"clone left in the trash"$'\t'"repoa/1"$'\t'*"next: trash-rm $SLOT"* ]]
  jaq -e '.torn_down == ["repoa/1"] and .purges[0].key == "repoa/1" and .purges[0].code == "purge-failed"' \
    <<<"$(last_event "$AGENT_SLOT_STATE_DIR/teardown.log" sweep)"
}

@test "a trash that writes no entry for the clone leaves the trash as it was and reports trash-entry-unknown" {
  finished_task
  mkdir -p "$T/other/1"
  "$STUBS/trash" "$T/other/1"
  stub trash '[ "$1" != --version ] || { echo "trash 0.test"; exit 0; }
mv "$1" "$STUBS/moved"'
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true and .purge.purged == false and .purge.code == "trash-entry-unknown"
    and .purge.entry == null' <<<"$output"
  [ "$(trash_entries | paste -sd ' ')" = "1 1" ]
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
  spawn flock "$AGENT_SLOT_ROOT/repoa/.1.lock" sleep 60 3>&-
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

@test "the ledger keeps each branch but the base, with the remote it pushes to and that remote's URL" {
  git clone -q --bare "$ORIGIN" "$T/fork.git"
  git -C "$SLOT" remote add fork "$T/fork.git"
  work feat/f
  git -C "$SLOT" push -q -u fork feat/f
  git -C "$SLOT" push -q origin feat/f
  git -C "$SLOT" branch -q spare main
  operator_finished
  local f main
  f=$(git -C "$SLOT" rev-parse feat/f)
  main=$(git -C "$SLOT" rev-parse main)
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  jaq -e -s --arg f "$f" --arg main "$main" --arg url "$T/fork.git" 'map(select(.event == "teardown"))[-1].branches
    == [{name: "feat/f", oid: $f, remote: "fork", url: $url}, {name: "spare", oid: $main, remote: null, url: null}]' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "sweep --yes tears down an operator-finished task whose only commits are on the fork its branch pushes to" {
  fork_remote
  work feat/f
  git -C "$SLOT" push -q -u fork feat/f
  operator_finished
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "sweep --yes tears down an operator-finished review round whose PR from the fork is still open" {
  fork_remote
  work fix/r 2
  git -C "$SLOT" push -q -u fork fix/r
  pr 887 OPEN fix/r 2025-12-01T00:00:00Z
  operator_finished
  local oid
  oid=$(git -C "$SLOT" rev-parse fix/r)
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  jaq -e -s --arg oid "$oid" 'map(select(.event == "teardown"))[-1]
    | .prs == [887] and .session_id == "s1"
      and .branches == [{name: "fix/r", oid: $oid, remote: "fork", url: "git@github.com:me/repoa.git"}]' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}
