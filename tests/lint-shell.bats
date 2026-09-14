#!/usr/bin/env bats
# Tests for scripts/lint-shell, the shared shellcheck dispatcher.
#
# .githooks/pre-commit, .githooks/pre-push, and .github/workflows/shellcheck.yml
# all route through this script, so a gap here silently weakens every gate.
#
# Run: bats tests/lint-shell.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/lint-shell"
# Leading dot keeps the probe out of the tests/*.bats glob that the hooks and
# the bats workflow use, so a stray probe cannot join the real suite.
PROBE="$BATS_TEST_DIRNAME/.lint-probe.bats"

teardown() {
  rm -f "$PROBE"
}

_require_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
}

@test "lint-shell is executable" {
  [ -x "$SCRIPT" ]
}

@test "no arguments is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "--all rejects extra arguments" {
  _require_shellcheck
  run "$SCRIPT" --all tests/lint-shell.bats
  [ "$status" -eq 2 ]
}

@test "--all passes over the current tree" {
  _require_shellcheck
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"file(s) clean"* ]]
}

@test "--all covers every category" {
  _require_shellcheck
  # A category silently dropping out of _all_targets would shrink this count
  # without failing anything else.
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  count=$(printf '%s' "$output" | sed -n 's/^lint-shell: \([0-9]*\) file.*/\1/p')
  if [ -z "$count" ] || [ "$count" -le 40 ]; then
    echo "expected >40 covered files, got '$count'"
    false
  fi
}

@test "uncovered paths are skipped rather than linted" {
  _require_shellcheck
  run "$SCRIPT" README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) clean"* ]]
}

@test "a staged bats file with a dead assertion fails" {
  _require_shellcheck
  # `!` anywhere but the last command does not fail a bats test, so without
  # SC2314 this assertion would pass no matter what it asserted.
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' '  ! true' '  [ -n "$HOME" ]' '}' >"$PROBE"
  run "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SC2314"* ]]
}

@test "bats files do not trip SC2016 on single-quoted child scripts" {
  _require_shellcheck
  # Handing a single-quoted script to a child shell is the core idiom of these
  # tests; the dispatcher excludes SC2016 so it is not flagged.
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' \
    '  run bash -c '"'"'printf "%s" "$PATH"'"'"'' '  [ "$status" -eq 0 ]' '}' >"$PROBE"
  run "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 0 ]
}

@test "dot-profile is linted with its source-following exclusions" {
  _require_shellcheck
  # Without --exclude=SC1090,SC1091 this file fails on sources shellcheck
  # cannot follow, so a dropped exclusion would surface here.
  run "$SCRIPT" stow/shell/dot-profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) clean"* ]]
}
