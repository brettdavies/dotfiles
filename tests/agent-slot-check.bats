#!/usr/bin/env bats
# agent-slot check: the fail-closed teardown verdict.
#
# Run: bats tests/agent-slot-check.bats
#
# Each test builds a real slot clone of a bare origin (task_slot_setup in tests/lib/agent-slot.bash).

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  SLEEPERS=()
}

teardown() {
  local pid
  for pid in "${SLEEPERS[@]}"; do kill "$pid" 2>/dev/null || true; done
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
lacks_blocker() { jaq -e --arg c "$1" 'all(.blockers[]; .code != $c)' <<<"$VERDICT" >/dev/null; }

@test "control: a finished, clean, fully pushed slot with no agent passes" {
  finished_task
  check
  jaq -e '.finished == true and .finished_by == "merge" and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "AE5: a merged PR plus one unpushed commit blocks with unpushed-commits, count 1" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'after the merge'
  check
  jaq -e '.finished == true and .teardown == false
    and (.needs_you[] | select(.code == "unpushed-commits") | .count == 1 and .message == "1 unpushed commit")' \
    <<<"$VERDICT"
}

@test "AE6: an agent reported busy or waiting blocks with agent-not-idle" {
  finished_task
  local status_value
  for status_value in busy waiting; do
    jaq -n -c --arg cwd "$SLOT" --arg s "$status_value" '[{pid: 1, cwd: $cwd, status: $s}]' >"$STUBS/claude-agents.json"
    check
    has_blocker agent-not-idle
    jaq -e '.teardown == false' <<<"$VERDICT"
  done
}

@test "an idle agent passes" {
  finished_task
  jaq -n -c --arg cwd "$SLOT" '[{pid: 1, cwd: $cwd, status: "idle"}]' >"$STUBS/claude-agents.json"
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
}

@test "a shell outside the slot's panes with its working directory in the slot blocks with agent-state-unknown" {
  finished_task
  (cd "$SLOT" && exec setsid sleep 120 </dev/null >/dev/null 2>&1) &
  SLEEPERS+=($!)
  local n=0
  until [ "$(readlink "/proc/${SLEEPERS[0]}/cwd" 2>/dev/null)" = "$SLOT" ] || ((n++ > 50)); do sleep 0.1; done
  check
  has_blocker agent-state-unknown
}

@test "a failed claude agents lookup blocks with agent-state-unknown" {
  finished_task
  stub claude 'exit 1'
  check
  has_blocker agent-state-unknown
  jaq -e '.teardown == false' <<<"$VERDICT"
}

@test "AE9: a PR closed without merging blocks with pr-closed-unmerged naming it, though the task has not finished" {
  work feat/y
  git -C "$SLOT" push -q origin feat/y
  pr 9 CLOSED feat/y
  check
  jaq -e '.finished == false and (.needs_you[] | select(.code == "pr-closed-unmerged")
    | .message == "PR #9 closed without merging" and .values == ["9"])' <<<"$VERDICT"
}

@test "AE10: a commit pushed after the merge, onto a recreated branch with no PR, blocks with commits-without-pr" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'one more'
  git -C "$SLOT" push -q origin feat/x
  check
  jaq -e '.needs_you[] | select(.code == "commits-without-pr") | .count == 1
    and .message == "1 commit on a branch with no PR"' <<<"$VERDICT"
  lacks_blocker unpushed-commits
}

@test "AE11: two PRs, one merged and one open, is not finished" {
  finished_task
  git -C "$SLOT" checkout -q -B feat/second main
  git -C "$SLOT" commit -q --allow-empty -m second
  git -C "$SLOT" push -q origin feat/second
  pr 8 OPEN feat/second
  check
  jaq -e '.finished == false and .teardown == false and .needs_you == []' <<<"$VERDICT"
}

@test "a stale remote-tracking ref for a deleted branch does not count once fetch prunes it" {
  work feat/z
  git -C "$SLOT" push -q origin feat/z
  git --git-dir="$ORIGIN" update-ref -d refs/heads/feat/z
  jaq '.finished_by_operator = true' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  git -C "$SLOT" rev-parse -q --verify refs/remotes/origin/feat/z
  check
  jaq -e '.needs_you[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "a task with no PR whose commits are on an origin branch passes once the operator finished it" {
  work feat/w
  git -C "$SLOT" push -q origin feat/w
  jaq '.finished_by_operator = true' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  check
  jaq -e '.finished == true and .finished_by == "operator" and .teardown == true' <<<"$VERDICT"
}

@test "a gh failure blocks with pr-state-unknown and never finishes" {
  finished_task
  stub gh 'echo boom >&2; exit 1'
  check
  jaq -e '.finished == false and .teardown == false
    and any(.needs_you[]; .code == "pr-state-unknown")' <<<"$VERDICT"
}

@test "local-only files block; dependency output, the docs/solutions link, and the slot's Claude settings do not" {
  finished_task
  printf 'node_modules/\n.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/node_modules/pkg" "$SLOT/.claude" "$SLOT/docs" "$T/shared/notes"
  touch "$SLOT/node_modules/pkg/index.js" "$T/shared/notes/a.md"
  echo '{}' >"$SLOT/.claude/settings.local.json"
  ln -s "$T/shared" "$SLOT/docs/solutions"
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
  mkdir -p "$SLOT/.context/handoffs"
  touch "$SLOT/.context/handoffs/next.md"
  check
  jaq -e '.needs_you[] | select(.code == "local-only-files") | .values == [".context/handoffs/next.md"]' <<<"$VERDICT"
}

@test "an untracked file blocks with untracked-files, and a stray file in the slot's .claude/ blocks too" {
  finished_task
  touch "$SLOT/notes.txt"
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/.claude"
  touch "$SLOT/.claude/scratch.md"
  check
  jaq -e '.needs_you[] | select(.code == "untracked-files") | .values == [".claude/scratch.md", "notes.txt"]
    or .values == ["notes.txt", ".claude/scratch.md"]' <<<"$VERDICT"
}

@test "an uncommitted change and a stash each block" {
  finished_task
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" pull -q origin main
  echo change >"$SLOT/tracked.txt"
  git -C "$SLOT" add tracked.txt
  check
  has_blocker uncommitted-changes
  git -C "$SLOT" stash -q
  check
  has_blocker stash-present
  lacks_blocker uncommitted-changes
}

@test "a symlink in the home directory into the slot blocks with home-symlink-into-slot" {
  finished_task
  mkdir -p "$T/home/.local/bin"
  ln -s "$SLOT/tool" "$T/home/.local/bin/tool"
  check
  jaq -e --arg l "$T/home/.local/bin/tool" '.needs_you[] | select(.code == "home-symlink-into-slot")
    | .values == [$l]' <<<"$VERDICT"
}

@test "a home scan that times out, or finds nothing to judge, blocks with home-scan-incomplete" {
  finished_task
  local i
  for i in $(seq 1 3000); do ln -s "$T/elsewhere" "$T/home/l$i"; done
  AGENT_SLOT_HOME_SCAN_TIMEOUT=0.05 check
  has_blocker home-scan-incomplete
  AGENT_SLOT_HOME_SCAN_ROOTS="$T/elsewhere:1" check
  has_blocker home-scan-incomplete
}

@test "a linked worktree inside the slot holding an unpushed commit blocks teardown" {
  finished_task
  git -C "$SLOT" worktree add -q --detach "$SLOT/wt" main
  git -C "$SLOT/wt" commit -q --allow-empty -m 'in the worktree'
  printf 'wt/\n' >>"$SLOT/.git/info/exclude"
  check
  jaq -e '.needs_you[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "check records the task's PRs and its needs-you list, which list then shows" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'after the merge'
  check
  jaq -e '.prs == [7] and .last_check.finished == true and .last_check.blockers[0].code == "unpushed-commits"' \
    "$SLOT/.git/agent-slot.json"
  echo repoa-1 >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0].needs_you[0].message == "1 unpushed commit"' <<<"$output"
}

@test "a PR opened before the slot existed does not count as the task's" {
  work feat/x
  git -C "$SLOT" push -q origin feat/x
  pr 3 MERGED feat/x
  jaq '(.[0].createdAt) = "2025-01-01T00:00:00Z"' "$STUBS/gh-prs.json" >"$T/p" && mv "$T/p" "$STUBS/gh-prs.json"
  check
  jaq -e '.prs == [] and .finished == false' <<<"$VERDICT"
}

@test "a slot that is still setting up is reported busy and never finished" {
  jaq '.state = "setting-up"' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  check
  jaq -e '.finished == false and .blockers[0].code == "slot-busy"' <<<"$VERDICT"
}

@test "check of a slot that does not exist exits 1 with slot-not-found" {
  run --separate-stderr "$AGENT_SLOT" check repoa/9 --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-not-found"' <<<"$stderr"
}
