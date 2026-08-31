#!/usr/bin/env bats
# Tests for scripts/run-tests, the shared bats dispatcher.
#
# .githooks/pre-commit, .githooks/pre-push, and .github/workflows/bats.yml all
# route through this script, so a gap here silently weakens every gate.
#
# Nothing here invokes `--all`: this file is part of what `--all` runs, so doing
# so would recurse. The `--all` path is exercised by the gates themselves.
#
# Run: bats tests/run-tests.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/run-tests"
PROBE="$BATS_TEST_DIRNAME/.run-probe.bats"

teardown() {
  rm -f "$PROBE"
}

_require_bats() {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
}

@test "run-tests is executable" {
  [ -x "$SCRIPT" ]
}

@test "no arguments is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "--all rejects extra arguments" {
  _require_bats
  run "$SCRIPT" --all tests/run-tests.bats
  [ "$status" -eq 2 ]
}

@test "non-bats paths are ignored" {
  _require_bats
  run "$SCRIPT" README.md scripts/lint-shell
  [ "$status" -eq 0 ]
}

@test "a passing test file exits 0" {
  _require_bats
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' '  [ 1 -eq 1 ]' '}' >"$PROBE"
  run "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 0 ]
}

@test "a failing test file exits 1" {
  _require_bats
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' '  [ 1 -eq 2 ]' '}' >"$PROBE"
  run "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 1 ]
}

@test "the git environment is scrubbed for the test run" {
  _require_bats
  # git hands hooks an absolute GIT_DIR that outranks `git -C`, so a fixture
  # built with `git -C "$sandbox"` would drive this repository instead. The
  # dispatcher unsets it; a test spawned through it must see it gone.
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' \
    '  [ -z "${GIT_DIR:-}" ]' '}' >"$PROBE"
  run env GIT_DIR=/nonexistent/git/dir "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 0 ]
}
