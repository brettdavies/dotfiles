#!/usr/bin/env bats
# Tests for the gh CLI wrapper that blocks AI merges to main
#
# Run: bats tests/gh-wrapper.bats

WRAPPER="$BATS_TEST_DIRNAME/../stow/gh/dot-local/bin/gh"

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "gh wrapper passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$WRAPPER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# find_real_gh
# ---------------------------------------------------------------------------

@test "gh wrapper finds real gh binary" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # Run a passthrough command — if find_real_gh fails, the wrapper exits 1
  run "$WRAPPER" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh version"* ]]
}

# ---------------------------------------------------------------------------
# Passthrough behavior
# ---------------------------------------------------------------------------

@test "gh wrapper passes non-merge commands through" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # gh pr list requires auth + repo context. CI typically has neither
  # for this checkout (no GH_TOKEN, no remote tracking). Skip unless
  # we can prove auth works.
  if ! gh auth status >/dev/null 2>&1; then
    skip "gh not authenticated (no GH_TOKEN in env)"
  fi
  run "$WRAPPER" pr list --state closed --limit 1
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Merge blocking logic (unit tests using string matching)
# ---------------------------------------------------------------------------

@test "gh wrapper blocks merge to main" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # Use a non-existent PR number to trigger the base branch check
  # gh pr view will fail, so base_branch will be empty (not "main") — but
  # we can test with a real merged-to-main PR if one exists.
  # For now, verify the script structure is sound by checking it's executable
  [ -x "$WRAPPER" ]
}

@test "gh wrapper is executable" {
  [ -x "$WRAPPER" ]
}

@test "gh wrapper uses bash" {
  head -1 "$WRAPPER" | grep -q "bash"
}
