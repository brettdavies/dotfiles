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

@test "leaves an unrelated uncommitted file in the clone untouched" {
  echo hello >"$SD/workflow-issues/new.md"
  echo scratch >"$SD/other-agent-wip.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ -f "$SD/other-agent-wip.md" ]
  [ "$(cat "$SD/other-agent-wip.md")" = scratch ]
}
