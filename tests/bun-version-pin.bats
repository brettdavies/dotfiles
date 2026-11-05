#!/usr/bin/env bats
# .bun-version is the one Bun version CI installs, and the local Bun the gates run must match it.
#
# CI's setup-bun reads the file, so no workflow or action names a version of its own. Locally, Bun comes from Homebrew
# and moves with `brew upgrade`, so the last test fails the day the machine's Bun moves past the pin: that is the cue
# to bump .bun-version in its own PR. Never install an older Bun to satisfy the pin.
#
# Run: bats tests/bun-version-pin.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."

@test ".bun-version names one exact version" {
  [ -f "$ROOT/.bun-version" ]
  run cat "$ROOT/.bun-version"
  [[ $output =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "every setup-bun step reads .bun-version, and no workflow or action names a Bun version of its own" {
  local steps literal
  steps=$(grep -rl 'oven-sh/setup-bun@' "$ROOT/.github")
  [ -n "$steps" ]
  for file in $steps; do
    grep -q 'bun-version-file: \.bun-version' "$file"
  done
  literal=$(grep -rn 'bun-version:' "$ROOT/.github" || true)
  echo "literal: $literal"
  [ -z "$literal" ]
}

@test "the local Bun is the pinned version" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local pinned local_version
  pinned=$(cat "$ROOT/.bun-version")
  local_version=$(bun --version)
  echo "local bun $local_version, .bun-version $pinned: bump .bun-version to $local_version in its own PR"
  [ "$local_version" = "$pinned" ]
}
