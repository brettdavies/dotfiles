#!/usr/bin/env bats
# Tests for solutions-clone-autosync: the SessionStart safety net that
# fast-forwards the shared solutions clone to origin.
# Uses local bare repos as origin so nothing touches the network.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/solutions-clone-autosync.sh"
  TMP=$(mktemp -d)
  ORIGIN="$TMP/origin.git"
  SD="$TMP/sd"
  # A second, independent clone that pushes to origin so the shared clone (SD)
  # falls behind without SD itself committing.
  PUSHER="$TMP/pusher"

  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$SD"
  git -C "$SD" symbolic-ref HEAD refs/heads/main # land the first commit on main
  git -C "$SD" config user.email test@example.com
  git -C "$SD" config user.name Test
  git -C "$SD" config commit.gpgsign false

  mkdir -p "$SD/workflow-issues"
  echo seed >"$SD/seed.md"
  git -C "$SD" add seed.md
  git -C "$SD" commit -q -m seed
  git -C "$SD" push -q -u origin main

  git clone -q "$ORIGIN" "$PUSHER"
  git -C "$PUSHER" config user.email pusher@example.com
  git -C "$PUSHER" config user.name Pusher
  git -C "$PUSHER" config commit.gpgsign false
  git -C "$PUSHER" fetch -q origin main
  git -C "$PUSHER" checkout -q -b main origin/main

  export SD_DIR="$SD"
}

teardown() {
  rm -rf "$TMP"
}

# Advance origin/main by one commit via the independent PUSHER clone, so SD is
# behind without ever having committed. Echoes the file path it added.
advance_origin() {
  local name="${1:-adv.md}"
  echo "upstream-$name" >"$PUSHER/$name"
  git -C "$PUSHER" add "$name"
  git -C "$PUSHER" commit -q -m "upstream $name"
  git -C "$PUSHER" push -q origin main
  git -C "$SD" fetch -q origin main
  printf '%s' "$name"
}

@test "no-ops a clone already current with origin" {
  before=$(git -C "$SD" rev-parse main)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" rev-parse main)" = "$before" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ -z "$output" ] # silent on the common already-current path
}

@test "exits cleanly when the solutions repo is absent" {
  SD_DIR="$TMP/does-not-exist" run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fast-forwards a behind-but-clean clone" {
  advance_origin
  [ "$(git -C "$SD" rev-parse main)" != "$(git -C "$SD" rev-parse origin/main)" ]

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [[ "$output" == *"fast-forwarded"* ]]
}

@test "fast-forwards past a phantom copy of an already-pushed file" {
  # Simulate the manual-flow failure: origin has a new file, and the shared
  # clone holds an untracked copy of that same already-pushed file, which blocks
  # a plain --ff-only. The hook reconciles the phantom copy, then fast-forwards.
  name=$(advance_origin new.md)
  git -C "$SD" cat-file -e "origin/main:$name" # origin has it
  printf 'upstream-%s' "$name" >"$SD/$name"    # phantom worktree copy blocks ff

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "skips a diverged clone without resetting it" {
  # SD commits a local-only change; origin advances independently -> divergence.
  echo local-only >"$SD/local.md"
  git -C "$SD" add local.md
  git -C "$SD" commit -q -m "local divergent commit"
  local_head=$(git -C "$SD" rev-parse main)
  advance_origin
  [ "$local_head" != "$(git -C "$SD" rev-parse origin/main)" ]

  run "$SCRIPT"
  [ "$status" -eq 0 ] # fail-open: the hook never breaks the session

  # The diverged clone is NOT reset: its local commit and file survive.
  [ "$(git -C "$SD" rev-parse main)" = "$local_head" ]
  [ -f "$SD/local.md" ]
  [ "$(git -C "$SD" log -1 --format=%s main)" = "local divergent commit" ]
  [[ "$output" == *"diverged"* ]]
}

@test "leaves a diverged clone's uncommitted local work untouched" {
  # A concurrent writer has genuine in-flight uncommitted work while the clone
  # is also diverged. The hook must never destroy it (never hard-reset).
  echo local-only >"$SD/local.md"
  git -C "$SD" add local.md
  git -C "$SD" commit -q -m "local divergent commit"
  advance_origin
  echo wip >"$SD/other-agent-wip.md" # untracked in-flight work

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ -f "$SD/other-agent-wip.md" ]
  [ "$(cat "$SD/other-agent-wip.md")" = wip ]
}
