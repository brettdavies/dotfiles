#!/usr/bin/env bats
# Tests for stow-deploy argument parsing, flags, and error paths
#
# Run: bats tests/stow-deploy-args.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

EXIT_USAGE=2

# The --all and --headless cases reach the deploy loop on an unlocked checkout;
# a per-test sandbox target keeps them off the live $HOME from any checkout.
setup() {
  export STOW_DEPLOY_TARGET="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STOW_DEPLOY_TARGET"
}

# ---------------------------------------------------------------------------
# Flag validation
# ---------------------------------------------------------------------------

@test "--all with explicit packages errors out (exit 2)" {
  run "$SCRIPT" --all git
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"--all cannot be combined"* ]]
}

@test "unknown flag errors out (exit 2)" {
  run "$SCRIPT" --bogus
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "--headless flag is accepted" {
  run "$SCRIPT" --headless
  [ "$status" -ne "$EXIT_USAGE" ]
}

@test "--all flag is accepted" {
  run "$SCRIPT" --all
  [ "$status" -ne "$EXIT_USAGE" ]
}

# ---------------------------------------------------------------------------
# --only: exactly the named packages
#
# The post-merge and post-checkout hooks restow one package at a time, and a
# positional package name only extends SHARED_PACKAGES. These run a copy of the
# script inside a fixture repo whose only packages are claude and secrets.
# ---------------------------------------------------------------------------

@test "--only deploys the named package and no other" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  fixture_repo "$BATS_TEST_TMPDIR/repo"
  run "$BATS_TEST_TMPDIR/repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-guard.sh" ]
  [ ! -e "$STOW_DEPLOY_TARGET/.secrets" ]
}

@test "--only with no package exits 2 and names a working form" {
  run "$SCRIPT" --only
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"--only needs at least one package"* ]]
  [[ "$output" == *"scripts/stow-deploy --only claude"* ]]
}

@test "--only with --all exits 2 in either order" {
  run "$SCRIPT" --only --all claude
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"--only and --all cannot be combined"* ]]
  run "$SCRIPT" --all --only claude
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"--only and --all cannot be combined"* ]]
}

# ---------------------------------------------------------------------------
# Uncommitted changes under stow/
#
# A deployed checkout is routinely dirty there: Claude Code writes settings back
# into stow/claude, and gh rewrites its hosts file. Only --adopt followed by the
# headless checkout can overwrite those edits, so headless mode refuses a
# package at that step instead of refusing the whole run up front.
# ---------------------------------------------------------------------------

@test "headless deploys a package whose own files have uncommitted edits when nothing needs adopting" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$repo"
  printf '#!/bin/sh\nexit 0\n' >"$repo/stow/claude/dot-fixture-new.sh"
  fixture_git "$repo" add -A
  fixture_git "$repo" commit -q -m new
  printf '{"edited": true}\n' >"$repo/stow/claude/dot-fixture-settings.json"
  run "$repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-new.sh" ]
  [ "$(cat "$repo/stow/claude/dot-fixture-settings.json")" = '{"edited": true}' ]
}

@test "headless deploys a package while another package has uncommitted edits" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$repo"
  printf 'export FIXTURE=2\n' >"$repo/stow/secrets/dot-secrets"
  run "$repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
}

@test "headless refuses to adopt over a package's uncommitted edits and names the fix" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$repo"
  printf '{"plain": true}\n' >"$STOW_DEPLOY_TARGET/.fixture-settings.json"
  printf '{"edited": true}\n' >"$repo/stow/claude/dot-fixture-settings.json"
  run "$repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 5 ]
  [[ "$output" == *"ERROR: claude: --adopt would overwrite uncommitted changes in stow/claude/"* ]]
  [[ "$output" == *"stow/claude/dot-fixture-settings.json"* ]]
  [[ "$output" == *"commit or stash them, then rerun: scripts/stow-deploy --headless --only claude"* ]]
  [ "$(cat "$repo/stow/claude/dot-fixture-settings.json")" = '{"edited": true}' ]
  [ ! -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
}

@test "headless adopts a plain file over a clean package and restores the repo version" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$repo"
  printf '{"plain": true}\n' >"$STOW_DEPLOY_TARGET/.fixture-settings.json"
  run "$repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
  [ "$(cat "$repo/stow/claude/dot-fixture-settings.json")" = '{}' ]
}

@test "an interactive run still warns about uncommitted changes and deploys" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$repo"
  printf 'export FIXTURE=2\n' >"$repo/stow/secrets/dot-secrets"
  run "$repo/scripts/stow-deploy" --only claude </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: stow/ has uncommitted changes"* ]]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
}

# ---------------------------------------------------------------------------
# Package name validation
# ---------------------------------------------------------------------------

@test "path traversal is rejected (exit 2)" {
  run "$SCRIPT" ../etc
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"Invalid package name"* ]]
}

@test "nonexistent package is rejected (exit 2)" {
  run "$SCRIPT" nonexistent_pkg_xyz
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"Invalid package name"* ]]
}

@test "package name with dot is rejected (exit 2)" {
  run "$SCRIPT" some.pkg
  [ "$status" -eq "$EXIT_USAGE" ]
  [[ "$output" == *"Invalid package name"* ]]
}

# ---------------------------------------------------------------------------
# Exit code constants
# ---------------------------------------------------------------------------

@test "exit codes are distinct non-zero values" {
  codes=$(grep '^EXIT_' "$SCRIPT" | awk -F= '{print $2}' | sed 's/#.*//' | tr -d ' ')
  unique_count=$(echo "$codes" | sort -u | wc -l | tr -d ' ')
  total_count=$(echo "$codes" | wc -l | tr -d ' ')
  [ "$unique_count" -eq "$total_count" ]
  while read -r code; do
    [ "$code" -ne 0 ]
    [ "$code" -ne 1 ]
  done <<<"$codes"
}
