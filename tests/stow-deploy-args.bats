#!/usr/bin/env bats
# Tests for stow-deploy argument parsing, flags, and error paths
#
# Run: bats tests/stow-deploy-args.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

EXIT_USAGE=2

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
