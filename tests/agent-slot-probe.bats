#!/usr/bin/env bats
# agent-slot probe PRs: a draft a slot declares throwaway with `probe` and closes with `close-probe`. check treats a
# closed probe as neither finishing the task nor blocking it, and every other check still holds.
#
# Run: bats tests/agent-slot-probe.bats
#
# repoa/1 is task_slot_setup's slot (tests/lib/agent-slot.bash), whose origin's path reads as origins/repoa, and gh
# answers from stub_gh_items' fixtures.
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
  jaq -c '.name = "t1" | .named_as = "t1"' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# in_slot ARG...: agent-slot ARG... --output json, run from inside the slot as its agent runs it.
in_slot() {
  run --separate-stderr bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$SLOT" "$AGENT_SLOT" "$@"
}

# record_set FILTER: applies FILTER to the slot's record.
record_set() {
  jaq -c "$1" "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
}

record_has() { jaq -e "$1" "$SLOT/.git/agent-slot.json" >/dev/null; }

# pushed BRANCH: a commit on BRANCH in the slot, pushed from the slot to origin.
pushed() {
  work "$1"
  git -C "$SLOT" push -q origin "$1"
}

# draft_pr N BRANCH [STATE] [DRAFT] [OWNER]: PR N on BRANCH's tip in the slot, opened on origin's repo, as `gh pr list`
# and `gh pr view` report it, with its head in OWNER/repoa and the title a probe PR carries.
draft_pr() {
  local n=$1 branch=$2 state=${3:-OPEN} draft=${4:-true} owner=${5:-origins} oid title="test(probe): PR $1"
  oid=$(git -C "$SLOT" rev-parse "$branch")
  pr "$n" "$state" "$branch" "" "$title"
  jaq -c --argjson n "$n" --argjson d "$draft" 'map(if .number == $n then .isDraft = $d else . end)' \
    "$STUBS/gh-prs.json" >"$STUBS/gh-prs.new"
  mv "$STUBS/gh-prs.new" "$STUBS/gh-prs.json"
  gh_item pr "$n" "$title" "$state" "$(jaq -n -c --arg b "$branch" --arg o "$oid" --argjson d "$draft" --arg owner "$owner" \
    '{headRefName: $b, headRefOid: $o, isDraft: $d, headRepository: {id: "R", name: "repoa"},
      headRepositoryOwner: {id: "U", login: $owner}}')"
}

# pr_fields N FILTER: applies FILTER, on gh's field names, to PR N as `gh pr list` and `gh pr view` report it.
pr_fields() {
  jaq -c --argjson n "$1" "map(if .number == \$n then ($2) else . end)" "$STUBS/gh-prs.json" >"$STUBS/gh-prs.new"
  mv "$STUBS/gh-prs.new" "$STUBS/gh-prs.json"
  jaq -c "$2" "$STUBS/gh-pr-$1.json" >"$STUBS/gh-pr.new"
  mv "$STUBS/gh-pr.new" "$STUBS/gh-pr-$1.json"
}

# pr_moved N BRANCH: PR N's head follows BRANCH's tip in the slot, as GitHub moves an open PR's head on a push.
pr_moved() {
  local oid
  oid=$(git -C "$SLOT" rev-parse "$2")
  git -C "$SLOT" push -q --force origin "$oid:refs/pull/$1/head"
  pr_fields "$1" ".headRefOid = \"$oid\""
}

# released: the record of a task its agent released.
released() {
  record_set '.release = {id: "r1", requested_at: "2026-06-02T00:00:00Z", session_id: "s1"}'
}

# closed_probe N BRANCH: a draft the slot pushed and marked, closed unmerged. The mark is written directly, so these
# tests judge check alone.
closed_probe() {
  pushed "$2"
  draft_pr "$1" "$2" CLOSED
  record_set ".prs = ((.prs // []) + [$1] | unique) | .probes = ((.probes // []) + [$1] | unique)"
}

# marked_probe N BRANCH: an open draft the slot pushed and marked through the verb.
marked_probe() {
  pushed "$2"
  draft_pr "$1" "$2"
  in_slot probe "$1"
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

# other_clone_pushes BRANCH: another clone commits to BRANCH and pushes it, and the slot's origin/BRANCH stays as it was.
other_clone_pushes() {
  [ -d "$T/other" ] || git clone -q "$ORIGIN" "$T/other"
  git -C "$T/other" fetch -q origin
  if git -C "$T/other" rev-parse -q --verify "origin/$1" >/dev/null; then
    git -C "$T/other" checkout -q -B "$1" "origin/$1"
  else
    git -C "$T/other" checkout -q -B "$1"
  fi
  git -C "$T/other" commit -q --allow-empty -m "other slot's work on $1"
  git -C "$T/other" push -q origin "$1"
}

# other_slot_pushes BRANCH: other_clone_pushes, and this slot fetches it. Prints nothing; the slot's origin/BRANCH then
# holds what the other clone pushed.
other_slot_pushes() {
  other_clone_pushes "$1"
  git -C "$SLOT" fetch -q origin "+refs/heads/*:refs/remotes/origin/*"
}

check() {
  run --separate-stderr "$AGENT_SLOT" check repoa/1 --output json
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  VERDICT=$(jaq -c '.slots[0]' <<<"$output")
}

has_blocker() { jaq -e --arg c "$1" 'any(.blockers[]; .code == $c)' <<<"$VERDICT" >/dev/null; }

# refused REASON [VALUE]: the last in_slot call failed with REASON and the full error envelope, and closed nothing.
refused() {
  [ "$status" -eq 1 ] || {
    echo "status $status: $stderr"
    false
  }
  assert_error_shape "$stderr"
  jaq -e --arg r "$1" --arg v "${2:-9}" '.reason == $r and .value == $v and .recovery.side_effects == "none"' <<<"$stderr"
  ! grep -q '^gh pr close' "$CALLS" || return 1
}

# ledger EVENT: the last ledger line of that event.
ledger() { jaq -c -s --arg e "$1" 'map(select(.event == $e))[-1]' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"; }

@test "control: a PR closed unmerged and never marked blocks with pr-closed-unmerged" {
  pushed feat/p
  draft_pr 9 feat/p CLOSED
  check
  jaq -e '.finished == false and .teardown == false and (.needs_you[] | select(.code == "pr-closed-unmerged")
    | .message == "PR #9 closed without merging" and .values == ["9"])' <<<"$VERDICT"
}

@test "a marked probe closed unmerged, beside a merged PR, passes check and is reported as a probe" {
  finished_task
  closed_probe 9 feat/p
  check
  jaq -e '.finished == true and .finished_by == "merge" and .blockers == [] and .needs_you == [] and .teardown == true
    and (.prs[] | select(.number == 9) | .probe == true and .draft == true and .state == "CLOSED")
    and (.prs[] | select(.number == 7) | .probe == false)' <<<"$VERDICT"
}

@test "an unmarked PR closed unmerged still blocks beside a closed probe, and only it is named" {
  finished_task
  closed_probe 9 feat/p
  pushed feat/q
  draft_pr 10 feat/q CLOSED
  check
  jaq -e '.finished == false and .teardown == false and (.needs_you[] | select(.code == "pr-closed-unmerged")
    | .message == "PR #10 closed without merging" and .values == ["10"])' <<<"$VERDICT"
}

@test "a marked PR taken out of draft before it closed is a real PR, so it blocks" {
  finished_task
  closed_probe 9 feat/p
  pr_fields 9 '.isDraft = false'
  check
  jaq -e '.teardown == false and (.prs[] | select(.number == 9) | .probe == false)
    and (.needs_you[] | select(.code == "pr-closed-unmerged") | .values == ["9"])' <<<"$VERDICT"
}

@test "a closed probe alone does not finish the task, and blocks nothing, until the agent releases" {
  closed_probe 9 feat/p
  check
  jaq -e '.finished == false and .blockers == [] and .needs_you == [] and .teardown == false' <<<"$VERDICT"
  record_set '.release = {id: "r1", requested_at: "2026-06-02T00:00:00Z", session_id: "s1"}'
  check
  jaq -e '.finished == true and .finished_by == "release" and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "an open marked probe keeps the task open, and finish refuses it as it does any open PR" {
  finished_task
  pushed feat/p
  draft_pr 9 feat/p
  record_set '.prs = [7, 9] | .probes = [9]'
  check
  jaq -e '.finished == false and .teardown == false and (.prs[] | select(.number == 9) | .probe == true)' <<<"$VERDICT"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "task-has-open-pr"' <<<"$stderr"
  [ -d "$SLOT/.git" ]
}

@test "beside a closed probe, unpushed commits, untracked files, and a busy agent each still block" {
  finished_task
  closed_probe 9 feat/p
  git -C "$SLOT" commit -q --allow-empty -m 'after the close'
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["unpushed-commits"])' <<<"$VERDICT"
  git -C "$SLOT" reset -q --hard HEAD~1
  touch "$SLOT/stray"
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["untracked-files"])' <<<"$VERDICT"
  rm "$SLOT/stray"
  jaq -n -c --arg cwd "$SLOT" '[{pid: 1, cwd: $cwd, status: "busy", sessionId: "s1"}]' >"$STUBS/claude-agents.json"
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["agent-not-idle"])' <<<"$VERDICT"
}

@test "sweep --yes tears down a slot whose PRs are one merged and one closed probe" {
  finished_task
  closed_probe 9 feat/p
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"] and .needs_you == []' <<<"$output"
  [ ! -e "$SLOT" ]
  ledger teardown | jaq -e '.prs == [7, 9]'
}

@test "a closed probe is no PR to the commit checks: a pushed branch with no PR beside it passes once released" {
  closed_probe 9 feat/p
  pushed feat/r
  released
  check
  jaq -e '.finished == true and .finished_by == "release" and .blockers == [] and .teardown == true' <<<"$VERDICT"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
}

@test "a closed probe's head counts as pushed after its branch is gone" {
  closed_probe 9 feat/p
  git -C "$SLOT" push -q origin --delete feat/p
  released
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "an unmarked PR closed unmerged stays a PR to the commit checks, so a pushed branch beside it has no PR" {
  pushed feat/p
  draft_pr 9 feat/p CLOSED
  pushed feat/r
  operator_finished
  check
  has_blocker commits-without-pr
}

@test "an open probe stays a PR to the commit checks, so a pushed branch beside it has no PR" {
  pushed feat/p
  draft_pr 9 feat/p
  record_set '.prs = [9] | .probes = [9]'
  pushed feat/r
  operator_finished
  check
  has_blocker commits-without-pr
}

@test "unpushed work beneath a closed probe's head still blocks, whether or not origin keeps the probe's branch" {
  finished_task
  work feat/real 3
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  check
  jaq -e '.finished == true and .teardown == false and ([.blockers[].code] == ["unpushed-commits"])
    and .blockers[0].count == 3' <<<"$VERDICT"
  git -C "$SLOT" push -q origin --delete feat/p
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["unpushed-commits"]) and .blockers[0].count == 3' <<<"$VERDICT"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == []' <<<"$output"
  [ -d "$SLOT/.git" ]
}

@test "unpushed work beneath a closed probe's head blocks a released task with no merged PR" {
  work feat/real 3
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  git -C "$SLOT" push -q origin --delete feat/p
  released
  check
  jaq -e '.finished == true and .teardown == false and ([.blockers[].code] == ["unpushed-commits"])
    and .blockers[0].count == 3' <<<"$VERDICT"
}

@test "a work branch that shares a closed probe's tip is not the probe's, so its commit still blocks" {
  finished_task
  marked_probe 9 feat/p
  git -C "$SLOT" branch feat/shared feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["unpushed-commits"]) and .blockers[0].count == 1' <<<"$VERDICT"
}

@test "a slot whose only branch is a closed probe's passes once released" {
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  git -C "$SLOT" branch -q -D main
  released
  check
  jaq -e '.finished == true and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "beside a closed probe, a PR ref that names no PR of this task counts as nothing pushed" {
  closed_probe 9 feat/p
  work feat/s
  git -C "$SLOT" update-ref refs/agent-slot/pr/7 feat/s
  released
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["unpushed-commits"])' <<<"$VERDICT"
}

@test "beside a merged PR, a commit pushed to a probe's branch after its close blocks with commits-without-pr" {
  finished_task
  closed_probe 9 feat/p
  git -C "$SLOT" commit -q --allow-empty -m 'follow-up work'
  git -C "$SLOT" push -q origin feat/p
  check
  jaq -e '.teardown == false and ([.blockers[].code] == ["commits-without-pr"])' <<<"$VERDICT"
}

@test "a mark seen out of draft is dropped, so a return to draft does not make it a probe again" {
  finished_task
  marked_probe 9 feat/p
  pr_fields 9 '.isDraft = false'
  check
  record_has '.probes == []'
  pr_fields 9 '.isDraft = true'
  check
  jaq -e '.prs[] | select(.number == 9) | .probe == false' <<<"$VERDICT"
  in_slot close-probe 9
  refused pr-not-probe
  pr_fields 9 '.state = "CLOSED"'
  check
  jaq -e '.teardown == false and (.needs_you[] | select(.code == "pr-closed-unmerged") | .values == ["9"])' <<<"$VERDICT"
}

@test "probe and close-probe drop the mark of a PR they read out of draft" {
  marked_probe 9 feat/p
  pr_fields 9 '.isDraft = false'
  in_slot probe 9
  refused pr-not-draft
  record_has '.probes == []'
  marked_probe 10 feat/q
  pr_fields 10 '.isDraft = false'
  in_slot close-probe 10
  refused pr-not-draft 10
  record_has '.probes == []'
}

@test "a PR whose title lacks the probe marker is refused by both verbs, and nothing is marked or closed" {
  local title
  pushed feat/p
  draft_pr 9 feat/p
  for title in 'feat: real work' 'test(probe):' 'test(probe): ' 'test(probes): nearly' 'Test(probe): cased' \
    'fix: test(probe): inside'; do
    record_set 'del(.probes) | .prs = []'
    pr_fields 9 ".title = \"$title\""
    in_slot probe 9
    refused pr-title-not-probe
    jaq -e --arg t "$title" '.next_step.action == "run" and .next_step.command == "agent-slot probe --help"
      and (.message | contains($t)) and (.message | contains("test(probe): "))' <<<"$stderr"
    record_has '.probes == null and .prs == []'
    record_set '.prs = [9] | .probes = [9]'
    in_slot close-probe 9
    refused pr-title-not-probe
    jaq -e '.next_step.action == "run" and .next_step.command == "agent-slot close-probe --help"' <<<"$stderr"
  done
}

@test "probe marks an open draft this slot pushed, attaches it as a work item, and logs it" {
  pushed feat/p
  draft_pr 9 feat/p
  in_slot probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  local oid
  oid=$(git -C "$SLOT" rev-parse feat/p)
  jaq -e --arg oid "$oid" '.verb == "probe" and .key == "repoa/1" and .already_marked == false and .probes == [9]
    and .pr.number == 9 and .pr.repo == "origins/repoa" and .pr.head == "feat/p" and .pr.oid == $oid' <<<"$output"
  record_has '.probes == [9] and .prs == [9] and ([.items[].number] == [9]) and .items[0].kind == "pr"'
  ledger probe | jaq -e --arg oid "$oid" '.repo == "repoa" and .slot == 1 and .session_id == "s1" and .number == 9
    and .head == "feat/p" and .oid == $oid'
}

@test "probe on a PR already marked succeeds and changes nothing" {
  marked_probe 9 feat/p
  in_slot probe 9
  [ "$status" -eq 0 ]
  jaq -e '.already_marked == true and .probes == [9]' <<<"$output"
  record_has '.probes == [9]'
  [ "$(jaq -s 'map(select(.event == "probe")) | length' "$AGENT_SLOT_STATE_DIR/ledger.jsonl")" = 1 ]
}

@test "probe on a marked draft already closed succeeds and changes nothing, as close-probe's rerun does" {
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  in_slot probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.already_marked == true and .probes == [9]' <<<"$output"
  [ "$(jaq -s 'map(select(.event == "probe")) | length' "$AGENT_SLOT_STATE_DIR/ledger.jsonl")" = 1 ]
}

@test "probe refuses a PR that is not a draft" {
  pushed feat/p
  draft_pr 9 feat/p OPEN false
  in_slot probe 9
  refused pr-not-draft
  jaq -e '.next_step.action == "none" and .next_step.command == null' <<<"$stderr"
  record_has '.probes == null and .prs == []'
}

@test "probe refuses a PR already closed or merged, so a closed PR cannot be marked after the fact" {
  pushed feat/p
  draft_pr 9 feat/p CLOSED
  in_slot probe 9
  refused pr-not-open
  jaq -e '.next_step.action == "ask-operator" and .next_step.command == "gh pr view 9 --repo origins/repoa"
    and (.message | contains("pr-closed-unmerged"))' <<<"$stderr"
  record_has '.probes == null'
  pr_fields 9 '.state = "MERGED"'
  in_slot probe 9
  refused pr-not-open
  jaq -e '.next_step.action == "none" and .next_step.command == null and (.message | contains("MERGED"))' <<<"$stderr"
  record_has '.probes == null'
}

@test "a marked probe never lets a branch it did not create qualify: another slot's branch with this slot's fixup" {
  other_slot_pushes feat/o
  git -C "$SLOT" checkout -q -b feat/o origin/feat/o
  git -C "$SLOT" commit -q --allow-empty -m 'a review fixup'
  git -C "$SLOT" push -q origin feat/o
  draft_pr 9 feat/o
  in_slot probe 9
  refused pr-not-from-this-slot
  jaq -e '(.message | contains("push a new commit") | not) and .next_step.action == "ask-operator"
    and .next_step.command == "gh pr view 9 --repo origins/repoa"' <<<"$stderr"
  record_set '.prs = [9] | .probes = [9]'
  in_slot close-probe 9
  refused pr-not-from-this-slot
}

@test "a branch this slot created still qualifies once this slot pushes over another writer's commit" {
  pushed feat/p
  other_slot_pushes feat/p
  git -C "$SLOT" checkout -q -B feat/p origin/feat/p
  git -C "$SLOT" commit -q --allow-empty -m 'this slot again'
  git -C "$SLOT" push -q origin feat/p
  draft_pr 9 feat/p
  in_slot probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

@test "the proof's limit: any push from a missing tracking ref reads as this clone creating the branch" {
  git clone -q "$ORIGIN" "$T/other"
  git -C "$T/other" checkout -q -b feat/o
  git -C "$T/other" commit -q --allow-empty -m "other slot's work"
  git -C "$T/other" push -q origin feat/o HEAD:refs/pull/9/head
  git -C "$SLOT" fetch -q origin refs/pull/9/head
  git -C "$SLOT" checkout -q -b feat/o FETCH_HEAD
  git -C "$SLOT" push -q origin feat/o
  draft_pr 9 feat/o
  in_slot probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  git -C "$T/other" checkout -q -b feat/f
  git -C "$T/other" commit -q --allow-empty -m "other slot's work on feat/f"
  git -C "$T/other" push -q origin feat/f HEAD:refs/pull/10/head
  git -C "$SLOT" fetch -q origin refs/pull/10/head
  git -C "$SLOT" checkout -q -b feat/f FETCH_HEAD
  git -C "$SLOT" commit -q --allow-empty -m 'a fixup on what the pull ref held'
  git -C "$SLOT" push -q origin feat/f
  draft_pr 10 feat/f
  in_slot probe 10
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  in_slot close-probe 10
  [ "$status" -eq 0 ]
  jaq -e '.closed == true and .already_closed == false' <<<"$output"
}

@test "the proof's limit: a no-op push over a stale tracking ref records a head this clone did not write" {
  pushed feat/s
  other_clone_pushes feat/s
  git -C "$T/other" push -q origin feat/s:refs/pull/10/head
  git -C "$SLOT" fetch -q origin refs/pull/10/head
  git -C "$SLOT" checkout -q -B feat/s FETCH_HEAD
  git -C "$SLOT" push -q origin feat/s
  draft_pr 10 feat/s
  in_slot probe 10
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  in_slot close-probe 10
  [ "$status" -eq 0 ]
  jaq -e '.closed == true and .already_closed == false' <<<"$output"
}

@test "a no-op push over a stale tracking ref is refused on a branch this clone did not create" {
  other_slot_pushes feat/s
  git -C "$T/other" commit -q --allow-empty -m 'moved past the fetch'
  git -C "$T/other" push -q origin feat/s HEAD:refs/pull/10/head
  git -C "$SLOT" fetch -q origin refs/pull/10/head
  git -C "$SLOT" checkout -q -b feat/s FETCH_HEAD
  git -C "$SLOT" push -q origin feat/s
  draft_pr 10 feat/s
  in_slot probe 10
  refused pr-not-from-this-slot 10
}

@test "probe refuses a head whose repository is gone, and a branch this slot never pushed" {
  pushed feat/p
  draft_pr 9 feat/p
  pr_fields 9 '.headRepository = null | .headRepositoryOwner = null'
  in_slot probe 9
  refused pr-not-from-this-slot
  jaq -e '.message | contains("(repository gone)")' <<<"$stderr"
  work feat/n
  draft_pr 10 feat/n
  in_slot probe 10
  refused pr-not-from-this-slot 10
}

@test "repo names compare in any case, as GitHub's do" {
  pushed feat/p
  draft_pr 9 feat/p OPEN true ORIGINS
  in_slot probe ORIGINS/REPOA#9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

@test "probe reports slot-busy and marks nothing while another process holds the record's lock" {
  pushed feat/p
  draft_pr 9 feat/p
  local lock=$AGENT_SLOT_ROOT/repoa/.1.lock
  spawn flock "$lock" sleep 30
  until ! flock -n "$lock" true; do sleep 0.1; done
  in_slot probe 9
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "slot-busy" and .value == "repoa/1" and .recovery.retryable == true
    and .next_step.command == "agent-slot probe 9 --output json"' <<<"$stderr"
  record_has '.probes == null'
}

@test "a verb that takes only a PR points an issue's number at its help, not at the same command" {
  local verb
  gh_item issue 12 "An issue"
  for verb in probe close-probe; do
    in_slot "$verb" 12
    [ "$status" -eq 2 ]
    assert_error_shape "$stderr"
    jaq -e --arg help "agent-slot $verb --help" '.reason == "item-kind-mismatch" and .value == "12"
      and .next_step.action == "run" and .next_step.command == $help' <<<"$stderr"
  done
}

@test "both gh calls ask for the fields the verdict and the verbs read" {
  marked_probe 9 feat/p
  check
  grep -q '^gh pr view 9 --repo origins/repoa --json .*headRefOid.*isDraft' "$CALLS"
  grep -q '^gh pr list .*--json .*headRefOid.*isDraft' "$CALLS"
}

@test "probe refuses a branch another slot pushed and this one only fetched and checked out" {
  other_slot_pushes feat/o
  git -C "$SLOT" checkout -q -b feat/o origin/feat/o
  draft_pr 9 feat/o
  in_slot probe 9
  refused pr-not-from-this-slot
  jaq -e '.next_step.action == "ask-operator" and (.message | contains("feat/o"))' <<<"$stderr"
  record_has '.probes == null'
}

@test "probe refuses a head another writer moved past what this slot pushed, and says what restores the proof" {
  pushed feat/p
  other_slot_pushes feat/p
  git -C "$SLOT" checkout -q -B feat/p origin/feat/p
  draft_pr 9 feat/p
  in_slot probe 9
  refused pr-not-from-this-slot
  jaq -e '(.message | contains("push a new commit")) and .next_step.action == "run"
    and (.next_step.command | startswith("git log")) and (.next_step.command | contains("refs/remotes/origin/feat/p"))' \
    <<<"$stderr"
}

@test "a branch present at clone does not qualify, even after this slot pushes a fixup to it" {
  git clone -q "$ORIGIN" "$T/other"
  git -C "$T/other" checkout -q -b feat/o
  git -C "$T/other" commit -q --allow-empty -m "another writer's work"
  git -C "$T/other" push -q origin feat/o
  local record
  record=$(cat "$SLOT/.git/agent-slot.json")
  find "$SLOT" -delete
  git clone -q "$ORIGIN" "$SLOT"
  printf '%s\n' "$record" >"$SLOT/.git/agent-slot.json"
  git -C "$SLOT" checkout -q -b feat/o origin/feat/o
  git -C "$SLOT" commit -q --allow-empty -m 'a review fixup'
  git -C "$SLOT" push -q origin feat/o
  draft_pr 9 feat/o
  in_slot probe 9
  refused pr-not-from-this-slot
  record_set '.prs = [9] | .probes = [9]'
  in_slot close-probe 9
  refused pr-not-from-this-slot
}

@test "probe refuses a head in another repository that shares a branch name this slot pushed to origin" {
  pushed feat/p
  draft_pr 9 feat/p OPEN true somebody
  in_slot probe 9
  refused pr-not-from-this-slot
}

@test "probe accepts a head this slot pushed to a fork" {
  fork_remote
  work feat/f
  git -C "$SLOT" push -q fork feat/f
  draft_pr 9 feat/f OPEN true me
  in_slot probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.pr.repo == "up/repoa" and .pr.head == "feat/f"' <<<"$output"
}

@test "probe refuses a PR of another repo than origin's" {
  pushed feat/p
  draft_pr 9 feat/p
  in_slot probe other/repo#9
  refused pr-not-from-this-slot other/repo#9
  jaq -e '.next_step.action == "run" and .next_step.command == "agent-slot probe --help"' <<<"$stderr"
}

@test "probe and close-probe run only from inside a slot" {
  local verb
  pushed feat/p
  draft_pr 9 feat/p
  for verb in probe close-probe; do
    run --separate-stderr bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$T" "$AGENT_SLOT" "$verb" 9
    [ "$status" -eq 1 ]
    assert_error_shape "$stderr"
    jaq -e --arg t "$T" '.reason == "not-in-slot" and .value == $t and .next_step.action == "none"
      and .next_step.command == null' <<<"$stderr"
  done
  run ! grep -q '^gh ' "$CALLS"
}

@test "probe and close-probe take exactly one well-formed ref, or fail with usage before gh is called" {
  local verb
  for verb in probe close-probe; do
    in_slot "$verb"
    [ "$status" -eq 2 ]
    jaq -e '.reason == "usage" and .value == null' <<<"$stderr"
    in_slot "$verb" 9 10
    [ "$status" -eq 2 ]
    in_slot "$verb" feat/p
    [ "$status" -eq 2 ]
    jaq -e '.reason == "usage" and .value == "feat/p"' <<<"$stderr"
  done
  run ! grep -q '^gh ' "$CALLS"
}

@test "close-probe closes a marked draft this slot pushed, with a comment that says why, and logs it" {
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.verb == "close-probe" and .key == "repoa/1" and .closed == true and .already_closed == false
    and .pr.number == 9 and .pr.head == "feat/p"' <<<"$output"
  grep -q '^gh pr close 9 --repo origins/repoa --comment .*probe.*repoa/1' "$CALLS"
  run ! grep -q 'delete-branch' "$CALLS"
  git -C "$ORIGIN" rev-parse -q --verify refs/heads/feat/p
  ledger close-probe | jaq -e '.repo == "repoa" and .slot == 1 and .number == 9 and .head == "feat/p"'
}

@test "the whole flow: mark, close, and check passes beside a merged PR, and the teardown goes through" {
  finished_task
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  check
  jaq -e '.finished == true and .blockers == [] and .teardown == true' <<<"$VERDICT"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "close-probe succeeds with a check between marking and closing" {
  marked_probe 9 feat/p
  check
  in_slot close-probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

@test "a probe pushed again after it was marked closes, and check passes beside a merged PR" {
  finished_task
  marked_probe 9 feat/p
  git -C "$SLOT" commit -q --allow-empty -m 'a second try at the workflow'
  git -C "$SLOT" push -q origin feat/p
  pr_moved 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  check
  jaq -e '.finished == true and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "close-probe refuses a marked PR closed out of draft" {
  marked_probe 9 feat/p
  pr_fields 9 '.state = "CLOSED" | .isDraft = false'
  in_slot close-probe 9
  refused pr-not-draft
  jaq -e '.next_step.action == "ask-operator"' <<<"$stderr"
}

@test "close-probe refuses an unmarked PR and points at probe" {
  pushed feat/p
  draft_pr 9 feat/p
  in_slot close-probe 9
  refused pr-not-probe
  jaq -e '.next_step.action == "run" and .next_step.command == "agent-slot probe 9"' <<<"$stderr"
  grep -q '"state":"OPEN"' "$STUBS/gh-pr-9.json"
}

@test "close-probe refuses a marked PR that is no longer a draft" {
  marked_probe 9 feat/p
  pr_fields 9 '.isDraft = false'
  in_slot close-probe 9
  refused pr-not-draft
}

@test "close-probe refuses a PR on another slot's branch, even with the mark written by hand" {
  other_slot_pushes feat/o
  git -C "$SLOT" checkout -q -b feat/o origin/feat/o
  draft_pr 9 feat/o
  record_set '.prs = [9] | .probes = [9]'
  in_slot close-probe 9
  refused pr-not-from-this-slot
}

@test "close-probe refuses a probe whose head another writer has moved since it was marked" {
  marked_probe 9 feat/p
  other_slot_pushes feat/p
  pr_fields 9 ".headRefOid = \"$(git -C "$SLOT" rev-parse origin/feat/p)\""
  in_slot close-probe 9
  refused pr-not-from-this-slot
}

@test "close-probe refuses a marked PR that merged" {
  marked_probe 9 feat/p
  pr_fields 9 '.state = "MERGED"'
  in_slot close-probe 9
  refused pr-not-open
}

@test "close-probe on a marked PR already closed succeeds without calling gh pr close again" {
  marked_probe 9 feat/p
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  in_slot close-probe 9
  [ "$status" -eq 0 ]
  jaq -e '.closed == true and .already_closed == true' <<<"$output"
  [ "$(grep -c '^gh pr close' "$CALLS")" = 1 ]
}

@test "a gh pr close that fails reports pr-close-failed with an unknown outcome and a safe rerun" {
  marked_probe 9 feat/p
  touch "$STUBS/gh-close-fails"
  in_slot close-probe 9
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "pr-close-failed" and .value == "9" and .recovery.retryable == true
    and .recovery.side_effects == "unknown" and .recovery.reconcile == "agent-slot close-probe 9 --output json"
    and .next_step.action == "retry" and .next_step.command == "agent-slot close-probe 9 --output json"
    and .log != null' <<<"$stderr"
  [ "$(jaq -s 'map(select(.event == "close-probe")) | length' "$AGENT_SLOT_STATE_DIR/ledger.jsonl")" = 0 ]
}

@test "a PR gh cannot find fails with item-not-found, and its next step is this verb's help" {
  in_slot close-probe 999
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-not-found" and .value == "999" and .next_step.command == "agent-slot close-probe --help"' \
    <<<"$stderr"
}

@test "both verbs' help states what qualifies a PR, and probe's says when to mark it" {
  run "$AGENT_SLOT" probe --help
  [ "$status" -eq 0 ]
  [[ $output == *"on a branch this clone created"* ]]
  [[ $output == *"gh pr create --draft"* ]]
  [[ $output == *"test(probe): <what it probes>"* ]]
  run "$AGENT_SLOT" close-probe --help
  [ "$status" -eq 0 ]
  [[ $output == *"on a branch this clone created"* ]]
  [[ $output == *"test(probe): <what it probes>"* ]]
  grep -qF 'test(probe): <what it probes>' "$BATS_TEST_DIRNAME/../README.md"
}

@test "the probe docs start from a push and name the slot's base, which whoami reports" {
  local readme=$BATS_TEST_DIRNAME/../README.md
  in_slot whoami
  [ "$status" -eq 0 ]
  jaq -e '.slot.base == "main"' <<<"$output"
  run "$AGENT_SLOT" probe --help
  [ "$status" -eq 0 ]
  [[ $output == *"git push -u origin HEAD"* ]]
  [[ $output == *"--base"* ]]
  [[ $output == *".slot.base"* ]]
  grep -qF 'git switch -c test/probe-<what>' "$readme"
  grep -qF 'git push -u origin HEAD' "$readme"
  grep -qF "gh pr create --draft --base <the slot's base> --title 'test(probe): <what it probes>' --fill" "$readme"
  grep -qF '.slot.base' "$readme"
}

@test "text mode says what happened and what comes next" {
  pushed feat/p
  draft_pr 9 feat/p
  run --separate-stderr bash -c 'cd "$1" && shift && exec "$@"' _ "$SLOT" "$AGENT_SLOT" probe 9
  [ "$status" -eq 0 ]
  [ "$output" = "repoa/1: PR #9 (test(probe): PR 9) is marked a probe; close it with agent-slot close-probe 9" ]
  run --separate-stderr bash -c 'cd "$1" && shift && exec "$@"' _ "$SLOT" "$AGENT_SLOT" close-probe 9
  [ "$status" -eq 0 ]
  [ "$output" = "repoa/1: PR #9 closed as a probe" ]
}
