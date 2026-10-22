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

@test "every shell script under scripts/ is a lint target" {
  _require_shellcheck
  # A script missing from the target rule is skipped by every gate at once:
  # pre-commit, pre-push, and CI all report it as zero files rather than fail.
  cd "$BATS_TEST_DIRNAME/.."
  local f missed=()
  while IFS= read -r f; do
    head -n1 "$f" | grep -qE '^#!.*\b(sh|bash)\b' || continue
    run "$SCRIPT" "$f"
    [[ "$output" == *"0 file(s) clean"* ]] && missed+=("$f")
  done < <(git ls-files scripts)
  if [ "${#missed[@]}" -gt 0 ]; then
    printf 'not linted: %s\n' "${missed[@]}"
    false
  fi
}

@test "a new script under scripts/ is linted without being registered" {
  _require_shellcheck
  # Runs a copy of the dispatcher from a scratch tree, so the probe never sits
  # in the real scripts/ where a parallel --all run would pick it up.
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root/scripts/sub"
  cp "$SCRIPT" "$root/scripts/lint-shell"
  printf '%s\n' '#!/usr/bin/env bash' 'echo $1' >"$root/scripts/sub/new-tool"
  printf '%s\n' '#!/usr/bin/env python3' 'print(1)' >"$root/scripts/sub/tool.py"
  run "$root/scripts/lint-shell" scripts/sub/new-tool
  [ "$status" -eq 1 ]
  [[ "$output" == *"SC2086"* ]]
  run "$root/scripts/lint-shell" scripts/sub/tool.py
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) clean"* ]]
}

@test "a library under scripts/*/lib/ is linted on its own without a shebang" {
  _require_shellcheck
  # Following a source with -x reads the library for its definitions but reports
  # nothing inside it, so the library has to be a target in its own right.
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root/scripts/tool/lib"
  cp "$SCRIPT" "$root/scripts/lint-shell"
  printf '%s\n' '# shellcheck shell=bash' 'helper() { echo $1; }' >"$root/scripts/tool/lib/helper.sh"
  run "$root/scripts/lint-shell" scripts/tool/lib/helper.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"SC2086"* ]]
}

@test "a shared test helper under tests/lib/ is linted" {
  _require_shellcheck
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root/scripts" "$root/tests/lib"
  cp "$SCRIPT" "$root/scripts/lint-shell"
  printf '%s\n' '# shellcheck shell=bash' 'helper() { echo $1; }' >"$root/tests/lib/helper.bash"
  run "$root/scripts/lint-shell" tests/lib/helper.bash
  [ "$status" -eq 1 ]
  [[ "$output" == *"SC2086"* ]]
}

@test "tools-atime is linted together with the libraries it sources" {
  _require_shellcheck
  # Without -x the lib/ sources are SC1091 notes and their contents go unread.
  run "$SCRIPT" scripts/tools-atime/tools-atime.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) clean"* ]]
}
