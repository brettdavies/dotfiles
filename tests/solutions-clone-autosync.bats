#!/usr/bin/env bats
# Tests for solutions-clone-autosync: the SessionStart safety net that
# fast-forwards the shared solutions clone to origin.
# Uses local bare repos as origin so nothing touches the network.

bats_require_minimum_version 1.5.0

setup() {
  # An inherited GIT_DIR outranks `-C`, so every `git -C "$SD"` below would
  # retarget whichever repo the caller was in. Git exports these to hooks, so
  # a hook-invoked run reaches this file with them set.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

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

# Push a new doc and an edit to the tracked seed.md, then leave already-pushed
# copies of both in SD, as a writer whose own fast-forward never ran would.
leave_phantom_new_and_edit() {
  mkdir -p "$PUSHER/workflow-issues"
  echo upstream-new >"$PUSHER/workflow-issues/new.md"
  echo upstream-edit >"$PUSHER/seed.md"
  git -C "$PUSHER" add workflow-issues/new.md seed.md
  git -C "$PUSHER" commit -q -m "upstream new doc and edit"
  git -C "$PUSHER" push -q origin main
  git -C "$SD" fetch -q origin main
  git -C "$SD" show origin/main:workflow-issues/new.md >"$SD/workflow-issues/new.md"
  git -C "$SD" show origin/main:seed.md >"$SD/seed.md"
}

# Put a git wrapper first on PATH that logs each checkout and clean the hook
# runs, with its exit status, to $REVERTS. The hook's output never shows them.
record_reverts() {
  REVERTS="$TMP/reverts.log"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
*" checkout "* | *" clean "*)
  "$(command -v git)" "\$@"
  rc=\$?
  echo "\$rc \$*" >>"$REVERTS"
  exit "\$rc"
  ;;
esac
exec "$(command -v git)" "\$@"
STUB
  chmod +x "$TMP/bin/git"
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
  git -C "$SD" show "origin/main:$name" >"$SD/$name" # phantom worktree copy blocks ff

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "reverts a phantom new doc and a phantom edit in one pass" {
  leave_phantom_new_and_edit
  record_reverts

  PATH="$TMP/bin:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  cat "$REVERTS"

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  # Each copy went to the command that handles it, and neither refused.
  run ! grep -qv '^0 ' "$REVERTS"
  grep -qE '^0 .*checkout.* seed\.md$' "$REVERTS"
  grep -qE '^0 .*clean.* workflow-issues/new\.md$' "$REVERTS"
}

@test "keeps an in-flight edit to a tracked doc while it reverts a phantom copy" {
  name=$(advance_origin new.md)
  git -C "$SD" show "origin/main:$name" >"$SD/$name" # phantom copy blocks ff
  echo wip >"$SD/seed.md"                            # origin never touched seed.md

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ "$(cat "$SD/seed.md")" = wip ]
}

@test "leaves an in-flight new doc that differs from the one origin added" {
  name=$(advance_origin new.md)
  echo "local draft" >"$SD/$name" # same path as the pushed doc, other content

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$SD/$name")" = "local draft" ]
  [ "$(git -C "$SD" rev-parse main)" != "$(git -C "$SD" rev-parse origin/main)" ]
  [[ "$output" == *"left untouched"* ]]
}

@test "exits non-zero when a phantom copy cannot be reverted" {
  leave_phantom_new_and_edit
  # A held index lock is what a concurrent writer in the shared clone looks
  # like; the checkout of the edited copy cannot take it.
  touch "$SD/.git/index.lock"

  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"index.lock"* ]]
  [[ "$output" == *"could not revert"* ]]
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
