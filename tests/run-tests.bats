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
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  return 0
}

_require_bats() {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
}

# A throwaway repo with its own copy of the dispatcher and its own tests tree.
# The suite-wide modes glob `tests/*.bats`, which in this repository includes
# this file, so exercising them here directly would recurse. The script derives
# its root from its own location, so a copy parked in a sandbox drives the
# sandbox instead.
_sandbox() {
  _require_bats
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/tests/perf"
  cp "$SCRIPT" "$SANDBOX/scripts/run-tests"
}

# _probe <path> <name> <assertion>
_probe() {
  printf '%s\n' '#!/usr/bin/env bats' '' "@test \"$2\" {" "  $3" '}' >"$1"
}

# Line number of the first output line matching $1, or empty when absent.
_line_of() {
  printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1
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

@test "--perf-only rejects extra arguments" {
  _require_bats
  run "$SCRIPT" --perf-only tests/run-tests.bats
  [ "$status" -eq 2 ]
}

@test "--no-perf rejects extra arguments" {
  _require_bats
  run "$SCRIPT" --no-perf tests/run-tests.bats
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

# ---------------------------------------------------------------------------
# Suite selection
# ---------------------------------------------------------------------------

@test "--no-perf runs the main suite and leaves the perf suite alone" {
  _sandbox
  _probe "$SANDBOX/tests/main.bats" "main probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/perf/slow.bats" "perf probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  [[ "$output" == *"main probe"* ]]
  [[ "$output" != *"perf probe"* ]]
}

@test "--perf-only runs the perf suite and leaves the main suite alone" {
  _sandbox
  _probe "$SANDBOX/tests/main.bats" "main probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/perf/slow.bats" "perf probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --perf-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"perf probe"* ]]
  [[ "$output" != *"main probe"* ]]
}

@test "--all runs the perf suite before the main suite" {
  _sandbox
  _probe "$SANDBOX/tests/main.bats" "main probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/perf/slow.bats" "perf probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --all
  [ "$status" -eq 0 ]
  [ "$(_line_of 'perf probe')" -lt "$(_line_of 'main probe')" ]
}

@test "a mode still succeeds when the suite it names is empty" {
  _sandbox
  _probe "$SANDBOX/tests/main.bats" "main probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --perf-only
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Parallel execution
# ---------------------------------------------------------------------------

@test "each file's output is replayed whole, in argument order, behind its name" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "bravo probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/c.bats" "charlie probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=3 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  # The marker precedes its own file's result and every later file's.
  [ "$(_line_of '# tests/a.bats')" -lt "$(_line_of 'alpha probe')" ]
  [ "$(_line_of 'alpha probe')" -lt "$(_line_of '# tests/b.bats')" ]
  [ "$(_line_of 'bravo probe')" -lt "$(_line_of '# tests/c.bats')" ]
}

@test "one failing file fails the run without suppressing the others" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "bravo probe" "[ 1 -eq 2 ]"
  _probe "$SANDBOX/tests/c.bats" "charlie probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=3 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 bravo probe"* ]]
  [[ "$output" == *"ok 1 alpha probe"* ]]
  [[ "$output" == *"ok 1 charlie probe"* ]]
}

@test "RUN_TESTS_JOBS=1 restores the single combined stream" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "bravo probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=1 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
  [[ "$output" == *"ok 2 bravo probe"* ]]
  [[ "$output" != *"# tests/a.bats"* ]]
}

@test "a RUN_TESTS_JOBS that is not a count falls back to one job" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "bravo probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=banana "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
}

@test "the perf suite is never parallelized" {
  _sandbox
  _probe "$SANDBOX/tests/perf/one.bats" "first perf probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/perf/two.bats" "second perf probe" "[ 1 -eq 1 ]"
  # Two files, jobs to spare: a parallelized perf run would emit a plan and a
  # marker per file. One combined plan and no markers is the proof it did not.
  run env RUN_TESTS_JOBS=4 "$SANDBOX/scripts/run-tests" --perf-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
  [[ "$output" != *"# tests/perf/"* ]]
}
