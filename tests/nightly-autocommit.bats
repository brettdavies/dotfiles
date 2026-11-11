#!/usr/bin/env bats
# Tests for nightly-autocommit's per-repo mode: a `commit` repo has its changes
# committed and pushed, and a `sync` repo is only fast-forwarded, with every
# change origin lacks logged as a WARNING and left exactly as it was.
# Origins are local bare repos, git reads a test config through
# GIT_CONFIG_GLOBAL, and claude is a stub that records its working directory
# and its arguments, one per line, then fails, so a commit takes the script's
# fallback path.

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
  CLAUDE_CWD=$T/claude.cwd
  mkdir -p "$STUBS"
  cat >"$STUBS/claude" <<STUB
#!/usr/bin/env bash
printf '%q\\n' "\$@" >>"$CLAUDE_CALLS"
printf '%s\\n' "\$PWD" >>"$CLAUDE_CWD"
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

# Usage: make_split_repo <name>; like make_repo, but the clone's .git is a file
# naming a git directory at $T/<name>-gitdir, as `git clone --separate-git-dir`
# leaves it.
make_split_repo() {
  git init -q --bare "$T/$1.git"
  git clone -q --separate-git-dir "$T/$1-gitdir" "$T/$1.git" "$T/$1" 2>/dev/null
  echo seed >"$T/$1/seed.md"
  git -C "$T/$1" add seed.md
  git -C "$T/$1" commit -q -m seed
  git -C "$T/$1" push -q -u origin main
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

@test "sync leaves a draft of a doc origin also changed as it was, and still logs it" {
  make_repo sd
  git clone -q "$T/sd.git" "$T/sd-other"
  echo upstream-edit >"$T/sd-other/seed.md"
  git -C "$T/sd-other" commit -q -am "upstream edit"
  git -C "$T/sd-other" push -q origin main
  echo "prime draft" >"$T/sd/seed.md"

  NIGHTLY_AUTOCOMMIT_REPOS="$T/sd|main|sync" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$T/sd/seed.md")" = "prime draft" ]
  [ -z "$(git -C "$T/sd" stash list)" ]
  [ "$(git -C "$T/sd" status --porcelain)" = " M seed.md" ]
  grep -E '^[^ ]+ WARNING: sd .*not committed.*seed\.md$' "$LOG"
}

@test "a commit repo still commits and pushes beside a sync repo" {
  make_repo skills
  make_repo sd
  echo "new note" >"$T/skills/note.md"
  echo "draft in progress" >"$T/sd/draft.md"
  sd_before=$(origin_head sd)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/skills|main
$T/sd|main|sync" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$T/skills.git" show main:note.md)" = "new note" ]
  [ -z "$(git -C "$T/skills" status --porcelain)" ]
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

@test "a clone whose .git file names a separate git directory is committed and pushed" {
  make_split_repo skills
  [ -f "$T/skills/.git" ]
  echo "new note" >"$T/skills/note.md"

  NIGHTLY_AUTOCOMMIT_REPOS="$T/skills|main" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git -C "$T/skills.git" show main:note.md)" = "new note" ]
  [ -z "$(git -C "$T/skills" status --porcelain)" ]
  grep -E 'Summary: committed=1 ' "$LOG"
}

@test "an index.lock in a separate git directory skips the repo" {
  make_split_repo skills
  echo "new note" >"$T/skills/note.md"
  : >"$T/skills-gitdir/index.lock"
  before=$(origin_head skills)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/skills|main" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(origin_head skills)" = "$before" ]
  grep -E 'SKIP: skills .*index\.lock exists' "$LOG"
}

@test "a directory inside a repo but not at its top is skipped as not a git repo" {
  make_repo skills
  mkdir "$T/skills/sub"
  echo "new note" >"$T/skills/sub/note.md"
  before=$(origin_head skills)

  NIGHTLY_AUTOCOMMIT_REPOS="$T/skills/sub|main" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(origin_head skills)" = "$before" ]
  grep -E 'SKIP: sub .*not a git repo' "$LOG"
}

@test "the default list leaves the Obsidian vault out" {
  cat >"$STUBS/git" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUBS/git"

  unset NIGHTLY_AUTOCOMMIT_REPOS
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  grep -F -- '--- solutions-docs ---' "$LOG"
  grep -F -- '--- agent-skills ---' "$LOG"
  run ! grep -F obsidian-vault "$LOG"
}

@test "claude runs from inside the repo it commits in, with no -d, which claude reads as --debug" {
  make_repo skills
  echo "new note" >"$T/skills/note.md"

  NIGHTLY_AUTOCOMMIT_REPOS="$T/skills|main" run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$CLAUDE_CWD")" = "$T/skills" ]
  run ! grep -xE -- '-d|--debug(=.*)?' "$CLAUDE_CALLS"
  grep -x -- -p "$CLAUDE_CALLS"
}
