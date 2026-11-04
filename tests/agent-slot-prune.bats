#!/usr/bin/env bats
# agent-slot resume prunes the slot's local branches whose PRs merged or closed, deleting origin's branch of the same
# name with each, and leaves every other branch alone.
#
# Run: bats tests/agent-slot-prune.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  # The slot's sessions already run, so resume starts none and only prunes.
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
}

resume() { run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json; }

# here BRANCH, there BRANCH: print yes when the slot, or origin, has the branch, else no.
here() { git -C "$SLOT" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }
there() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }

@test "resume deletes a branch whose PR merged or closed, here and on origin, and keeps the rest" {
  work merged-one
  git -C "$SLOT" push -q origin merged-one
  pr 1 MERGED merged-one
  squash_merge merged-one
  work closed-one
  git -C "$SLOT" push -q origin closed-one
  pr 2 CLOSED closed-one
  work open-one
  git -C "$SLOT" push -q origin open-one
  pr 3 OPEN open-one
  work no-pr
  work current
  git -C "$SLOT" push -q origin current
  pr 4 MERGED current
  resume
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.pruned_branches == ["closed-one", "merged-one"]' <<<"$output"
  [ "$(here merged-one)" = no ]
  [ "$(here closed-one)" = no ]
  [ "$(there closed-one)" = no ]
  [ "$(here open-one)" = yes ]
  [ "$(there open-one)" = yes ]
  [ "$(here no-pr)" = yes ]
  [ "$(here current)" = yes ]
  [ "$(there current)" = yes ]
  [ "$(here main)" = yes ]
}

@test "a branch with work its closed PR never had, or one named like a fork's PR, is kept" {
  work extra
  git -C "$SLOT" push -q origin extra
  pr 5 CLOSED extra
  git -C "$SLOT" commit -q --allow-empty -m 'work after the PR closed'
  work forked
  pr_listed 6 MERGED forked "$(git -C "$SLOT" rev-parse forked)" 2026-06-01T00:00:00Z
  jaq '(.[] | select(.number == 6)).isCrossRepository = true' "$STUBS/gh-prs.json" >"$STUBS/gh-prs.new"
  mv "$STUBS/gh-prs.new" "$STUBS/gh-prs.json"
  git -C "$SLOT" checkout -q main
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here extra)" = yes ]
  [ "$(there extra)" = yes ]
  [ "$(here forked)" = yes ]
}

@test "a commit pushed after its PR merged is kept, here and on origin" {
  work after-merge
  git -C "$SLOT" push -q origin after-merge
  pr 8 MERGED after-merge
  git -C "$SLOT" commit -q --allow-empty -m 'work after the PR merged'
  git -C "$SLOT" push -q origin after-merge
  git -C "$SLOT" checkout -q main
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here after-merge)" = yes ]
  [ "$(there after-merge)" = yes ]
}

@test "a branch another clone moved on origin after its PR merged is kept on both sides" {
  work moved
  git -C "$SLOT" push -q origin moved
  pr 9 MERGED moved
  git clone -q --branch moved "$ORIGIN" "$T/other"
  git -C "$T/other" commit -q --allow-empty -m 'work from another clone'
  git -C "$T/other" push -q origin moved
  git -C "$SLOT" checkout -q main
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here moved)" = yes ]
  [ "$(there moved)" = yes ]
}

@test "with origin out of reach, resume keeps a merged PR's branch" {
  work unreachable
  git -C "$SLOT" push -q origin unreachable
  pr 10 MERGED unreachable
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" remote set-url origin "$T/no-such-origin.git"
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here unreachable)" = yes ]
}

@test "a branch another PR targets is kept on both sides, even after its own PR merged" {
  work lower
  git -C "$SLOT" push -q origin lower
  pr 11 MERGED lower
  pr_listed 12 OPEN upper "$(git -C "$SLOT" rev-parse lower)" 2026-06-01T00:00:00Z
  jaq '(.[] | select(.number == 12)).baseRefName = "lower"' "$STUBS/gh-prs.json" >"$STUBS/gh-prs.new"
  mv "$STUBS/gh-prs.new" "$STUBS/gh-prs.json"
  git -C "$SLOT" checkout -q main
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here lower)" = yes ]
  [ "$(there lower)" = yes ]
}

@test "origin's default branch is kept on both sides when it is not the slot's base" {
  pr 13 MERGED main
  jq_record='.base = "release"'
  jaq "$jq_record" "$SLOT/.git/agent-slot.json" >"$T/rec.json" && mv "$T/rec.json" "$SLOT/.git/agent-slot.json"
  git -C "$SLOT" checkout -q -b elsewhere
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here main)" = yes ]
  [ "$(there main)" = yes ]
}

@test "a branch git cannot delete here is reported in prune_failed, and resume still finishes" {
  work held
  git -C "$SLOT" push -q origin held
  pr 14 MERGED held
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" worktree add -q "$T/held-wt" held
  resume
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.pruned_branches == [] and (.prune_failed | map(.branch)) == ["held"] and .prune_checked == true' <<<"$output"
  [ "$(here held)" = yes ]
}

@test "a delete origin refuses keeps the branch here too, and is reported in prune_failed and the ledger" {
  work guarded
  git -C "$SLOT" push -q origin guarded
  pr 15 MERGED guarded
  git -C "$SLOT" checkout -q main
  printf '#!/bin/sh\nwhile read -r old new ref; do [ "$ref" = refs/heads/guarded ] && exit 1; done\nexit 0\n' \
    >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == [] and (.prune_failed | map(.branch)) == ["guarded"]' <<<"$output"
  [ "$(here guarded)" = yes ]
  [ "$(there guarded)" = yes ]
  jaq -e -s 'map(select(.event == "prune" and .branch == "guarded" and .result == "failed")) | length == 1' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "a pruned branch gets a ledger line, and a resume with no PR list from GitHub says it checked nothing" {
  work done-one
  git -C "$SLOT" push -q origin done-one
  pr 16 MERGED done-one
  git -C "$SLOT" checkout -q main
  resume
  jaq -e '.pruned_branches == ["done-one"] and .prune_failed == [] and .prune_checked == true' <<<"$output"
  jaq -e -s 'map(select(.event == "prune" and .branch == "done-one" and .result == "pruned")) | length == 1' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  stub gh 'exit 1'
  resume
  jaq -e '.prune_checked == false' <<<"$output"
}

@test "with no PR list from GitHub, resume prunes nothing" {
  work merged-two
  pr 7 MERGED merged-two
  git -C "$SLOT" checkout -q main
  stub gh 'exit 1'
  resume
  [ "$status" -eq 0 ]
  jaq -e '.pruned_branches == []' <<<"$output"
  [ "$(here merged-two)" = yes ]
}
