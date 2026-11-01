#!/usr/bin/env bats
# Tests for nightly-autocommit's per-repo mode: a `commit` repo has its changes
# committed and pushed, and a `sync` repo is only fast-forwarded, with every
# change origin lacks logged as a WARNING and left exactly as it was.
# Origins are local bare repos, git reads a test config through
# GIT_CONFIG_GLOBAL, and claude is a stub that fails, so a commit takes the
# script's fallback path.

bats_require_minimum_version 1.5.0

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  SCRIPT="$BATS_TEST_DIRNAME/../scripts/nightly-autocommit.sh"
  T=$BATS_TEST_TMPDIR

  export GIT_CONFIG_GLOBAL=$T/gitconfig
  git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
  git config --file "$GIT_CONFIG_GLOBAL" user.name Test
  git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  STUBS=$T/stubs
  CLAUDE_CALLS=$T/claude.calls
  mkdir -p "$STUBS"
  cat >"$STUBS/claude" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$CLAUDE_CALLS"
exit 1
STUB
  chmod +x "$STUBS/claude"
  export PATH="$STUBS:$PATH"

  export NIGHTLY_AUTOCOMMIT_LOG_DIR=$T/log
  LOG=$NIGHTLY_AUTOCOMMIT_LOG_DIR/nightly-autocommit.log
}

# Usage: make_repo <name>; a bare origin $T/<name>.git with one commit on main,
# and a clone of it at $T/<name>.
make_repo() {
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$T/$1" 2>/dev/null
  echo seed >"$T/$1/seed.md"
  git -C "$T/$1" add seed.md
  git -C "$T/$1" commit -q -m seed
  git -C "$T/$1" push -q -u origin main
}

# Usage: advance_origin <name>; pushes one commit to origin from a second
# clone, so the first clone falls behind without committing anything itself.
advance_origin() {
  git clone -q "$T/$1.git" "$T/$1-pusher"
  echo upstream >"$T/$1-pusher/upstream.md"
  git -C "$T/$1-pusher" add upstream.md
  git -C "$T/$1-pusher" commit -q -m upstream
  git -C "$T/$1-pusher" push -q origin main
}

origin_head() {
  git -C "$T/$1.git" rev-parse main
}

@test "sync fast-forwards a behind clone and logs its strays without committing them" {
  make_repo sd
  advance_origin sd
  echo "draft in progress" >"$T/sd/draft.md"
  echo "operator edit" >"$T/sd/seed.md"
  origin_before=$(origin_head sd)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/sd|main|sync" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$T/sd" rev-parse HEAD)" = "$origin_before" ]
  [ "$(origin_head sd)" = "$origin_before" ]
  [ "$(cat "$T/sd/draft.md")" = "draft in progress" ]
  [ "$(cat "$T/sd/seed.md")" = "operator edit" ]
  git -C "$T/sd" diff --cached --quiet
  [ ! -e "$CLAUDE_CALLS" ]

  grep -E '^[^ ]+ WARNING: sd .*not committed.*draft\.md$' "$LOG"
  grep -E '^[^ ]+ WARNING: sd .*not committed.*seed\.md$' "$LOG"
  grep -E 'Summary: .*synced=1' "$LOG"
}

@test "a commit repo still commits and pushes beside a sync repo" {
  make_repo vault
  make_repo sd
  echo "new note" >"$T/vault/note.md"
  echo "draft in progress" >"$T/sd/draft.md"
  sd_before=$(origin_head sd)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/vault|main
$T/sd|main|sync" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$T/vault.git" show main:note.md)" = "new note" ]
  [ -z "$(git -C "$T/vault" status --porcelain)" ]
  [ "$(origin_head sd)" = "$sd_before" ]
  [ -f "$T/sd/draft.md" ]
  grep -E 'Summary: committed=1 .*synced=1' "$LOG"
}

@test "sync logs no WARNING for a clone with nothing origin lacks" {
  make_repo sd
  advance_origin sd

  NIGHTLY_AUTOCOMMIT_REPOS="$T/sd|main|sync" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$T/sd" rev-parse HEAD)" = "$(origin_head sd)" ]
  run ! grep WARNING "$LOG"
  grep -E 'Summary: .*synced=1' "$LOG"
}

@test "skips a repo whose mode is unknown rather than committing in it" {
  make_repo sd
  echo "draft in progress" >"$T/sd/draft.md"
  before=$(origin_head sd)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/sd|main|synk" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(origin_head sd)" = "$before" ]
  [ "$(git -C "$T/sd" rev-parse HEAD)" = "$before" ]
  [ -f "$T/sd/draft.md" ]
  grep -E "ERROR: sd .*unknown mode 'synk'" "$LOG"
  grep -E 'Summary: .*failed=1' "$LOG"
}
