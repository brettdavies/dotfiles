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
