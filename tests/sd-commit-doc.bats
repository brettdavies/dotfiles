#!/usr/bin/env bats
# Tests for sd-commit-doc: isolated-worktree commit + push + shared-clone fast-forward.
# Uses a local bare repo as origin so nothing touches the network.

setup() {
  # An inherited GIT_DIR outranks `-C`, so every `git -C "$SD"` below would
  # retarget whichever repo the caller was in. Git exports these to hooks, so
  # a hook-invoked run reaches this file with them set.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/sd-commit-doc"
  TMP=$(mktemp -d)
  ORIGIN="$TMP/origin.git"
  SD="$TMP/sd"

  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$SD"
  git -C "$SD" symbolic-ref HEAD refs/heads/main # land the first commit on main, whatever init.defaultBranch is
  git -C "$SD" config user.email test@example.com
  git -C "$SD" config user.name Test
  git -C "$SD" config commit.gpgsign false

  # Seed origin/main with an initial commit.
  mkdir -p "$SD/workflow-issues"
  echo seed >"$SD/seed.md"
  git -C "$SD" add seed.md
  git -C "$SD" commit -q -m seed
  git -C "$SD" push -q -u origin main

  MSG="$TMP/msg.md"
  printf 'docs(x): add a thing\n' >"$MSG"
  export SD_DIR="$SD"
}

teardown() {
  rm -rf "$TMP"
}

@test "errors without enough arguments" {
  run "$SCRIPT" "$MSG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "errors when the message file is missing" {
  run "$SCRIPT" "$TMP/nope.md" workflow-issues/a.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"message file not found"* ]]
}

@test "errors when a doc file is missing under the solutions repo" {
  run "$SCRIPT" "$MSG" workflow-issues/missing.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"file not found under"* ]]
}

@test "rejects an absolute path" {
  run "$SCRIPT" "$MSG" /etc/hosts
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-relative"* ]]
}

@test "commits and pushes a new file, then fast-forwards the clone" {
  echo hello >"$SD/workflow-issues/new.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]

  git -C "$SD" cat-file -e "origin/main:workflow-issues/new.md"
  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main)" = "docs(x): add a thing" ]

  run git -C "$SD" show --format= --name-only origin/main
  [ "$output" = "workflow-issues/new.md" ]
}

# The commit runs under `git -C <worktree>`, so a message path is only usable
# there once it no longer depends on the caller's directory.
@test "accepts a message file given relative to the caller's directory" {
  mkdir -p "$TMP/notes"
  cp "$MSG" "$TMP/notes/msg.md"
  echo hello >"$SD/workflow-issues/new.md"
  cd "$TMP"
  run "$SCRIPT" notes/msg.md workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main)" = "docs(x): add a thing" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "commits multiple files in one commit" {
  echo a >"$SD/workflow-issues/a.md"
  echo b >"$SD/workflow-issues/b.md"
  run "$SCRIPT" "$MSG" workflow-issues/a.md workflow-issues/b.md
  [ "$status" -eq 0 ]

  git -C "$SD" cat-file -e "origin/main:workflow-issues/a.md"
  git -C "$SD" cat-file -e "origin/main:workflow-issues/b.md"
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "commits a modification to an existing tracked file and reconciles the checkout" {
  echo changed >"$SD/seed.md"
  run "$SCRIPT" "$MSG" seed.md
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
}

# One pathspec git does not know makes `git checkout -- <paths>` refuse every
# path, so a single revert over a new file and a tracked one leaves the tracked
# copy modified and the fast-forward blocked behind it.
@test "reconciles the checkout when one call commits a new file and a modified one" {
  echo hello >"$SD/workflow-issues/new.md"
  echo changed >"$SD/seed.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md seed.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"not fast-forwarded"* ]]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
  git -C "$SD" cat-file -e "origin/main:workflow-issues/new.md"
}

@test "fails loudly when the shared clone's copies cannot be reverted" {
  echo changed >"$SD/seed.md"
  # A held index lock is what a concurrent writer in the shared clone looks
  # like; the push lands, but the revert and the fast-forward cannot.
  local stub="$TMP/bin"
  mkdir -p "$stub"
  cat >"$stub/git" <<STUB
#!/usr/bin/env bash
[[ " \$* " == *" fetch "* && -e "$TMP/pushed" ]] && touch "$SD/.git/index.lock"
[[ " \$* " == *" push "* ]] && touch "$TMP/pushed"
exec "$(command -v git)" "\$@"
STUB
  chmod +x "$stub/git"

  PATH="$stub:$PATH" run "$SCRIPT" "$MSG" seed.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"index.lock"* ]]
  [[ "$output" == *"FAILED during reverting the shared clone's copies (the push already landed)"* ]]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
}

@test "leaves an unrelated uncommitted file in the clone untouched" {
  echo hello >"$SD/workflow-issues/new.md"
  echo scratch >"$SD/other-agent-wip.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ -f "$SD/other-agent-wip.md" ]
  [ "$(cat "$SD/other-agent-wip.md")" = scratch ]
}

# The corpus schema check lives in the solutions repo's own hook library, so the
# same rejection the pre-commit hook would raise is available before any work
# happens. Running it up front turns a mid-commit hook abort — after a fetch, a
# worktree, and a staged copy — into a named failure that costs a second. The
# stub stands in for the real validator so the suite stays hermetic.
@test "rejects a doc the repo's own validator fails, before committing" {
  mkdir -p "$SD/.githooks"
  cat >"$SD/.githooks/lib-validate.sh" <<'LIB'
validate_files() {
  printf 'FAIL: %s: missing required field: module\n' "$1"
  return 1
}
LIB
  echo hello >"$SD/workflow-issues/new.md"
  local before
  before=$(git -C "$SD" rev-parse origin/main)

  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field: module"* ]]

  # Nothing reached origin, and the clone is untouched apart from the doc itself.
  [ "$(git -C "$SD" rev-parse origin/main)" = "$before" ]
  run git -C "$SD" worktree list
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

# A failure anywhere in the sequence has to name itself. Hook output can fill the
# tail of a transcript, and a caller that reads the status through a pipe sees
# only the last command's. A marker line on stderr is the signal that survives
# both.
@test "announces its own failure with a marker line" {
  mkdir -p "$SD/.githooks"
  cat >"$SD/.githooks/lib-validate.sh" <<'LIB'
validate_files() { return 1; }
LIB
  echo hello >"$SD/workflow-issues/new.md"

  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"sd-commit-doc: FAILED"* ]]
}
