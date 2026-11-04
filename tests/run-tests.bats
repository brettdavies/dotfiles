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

load lib/processes

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
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/tests/perf" "$SANDBOX/tests/lib"
  cp "$SCRIPT" "$SANDBOX/scripts/run-tests"
  cp "$BATS_TEST_DIRNAME/lib/processes.bash" "$SANDBOX/tests/lib/"
}

# _probe <path> <name> <assertion>
_probe() {
  printf '%s\n' '#!/usr/bin/env bats' '' "@test \"$2\" {" "  $3" '}' >"$1"
}

# Line number of the first output line matching $1, or empty when absent.
_line_of() {
  printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1
}

# Prints the letters of the "<letter> probe" tests in $output, sorted and joined.
_probes_run() {
  printf '%s\n' "$output" | sed -n 's/^ok [0-9]* \([a-z]\) probe$/\1/p' | sort | tr -d '\n'
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

@test "without perl the runner exits 3 naming it, before any suite runs" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_PERL=/nonexistent/perl "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 3 ]
  [[ "$output" == *"run-tests: perl not installed"* ]]
  [[ "$output" != *"alpha probe"* ]]
}

@test "the git environment is scrubbed for the test run" {
  _require_bats
  # git hands hooks an absolute GIT_DIR that outranks `git -C`, so a fixture
  # built with `git -C "$sandbox"` would drive this repository instead. The
  # dispatcher unsets it; a test spawned through it must see it gone.
  local vars="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE"
  printf '%s\n' '#!/usr/bin/env bats' '' '@test "probe" {' \
    "  for v in $vars; do [ -z \"\${!v:-}\" ] || { echo \"\$v leaked\"; false; }; done" '}' >"$PROBE"
  run env GIT_DIR=/nonexistent/git/dir GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index \
    GIT_COMMON_DIR=/nonexistent GIT_OBJECT_DIRECTORY=/nonexistent/objects \
    GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent/alt GIT_PREFIX=sub/ GIT_NAMESPACE=ns \
    "$SCRIPT" "tests/$(basename "$PROBE")"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Time limit
# ---------------------------------------------------------------------------

@test "a hung test fails at the default time limit, named, and leaves nothing running" {
  _sandbox
  # The sandbox copy's default comes down to 2 s, so the hang costs seconds.
  sed -i.orig 's/^DEFAULT_TEST_TIMEOUT=[0-9]*$/DEFAULT_TEST_TIMEOUT=2/' "$SANDBOX/scripts/run-tests"
  grep -qx 'DEFAULT_TEST_TIMEOUT=2' "$SANDBOX/scripts/run-tests"
  # A passthrough stub that finds itself first on PATH re-executes itself forever, all in one process.
  mkdir "$SANDBOX/stubs"
  printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/env mktemp "$@"' >"$SANDBOX/stubs/mktemp"
  chmod +x "$SANDBOX/stubs/mktemp"
  _probe "$SANDBOX/tests/hang.bats" "hang probe" "PATH=\"$SANDBOX/stubs:\$PATH\" mktemp"
  local started=$SECONDS
  HANG_PROBE=$BATS_TEST_TMPDIR run env -u BATS_TEST_TIMEOUT "$SANDBOX/scripts/run-tests" tests/hang.bats
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 hang probe # timeout after 2s"* ]]
  ((SECONDS - started < 15))
  [ -z "$(processes_with "HANG_PROBE=$BATS_TEST_TMPDIR")" ]
}

@test "a failing test does not hold the run for the rest of its time limit" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "false"
  local started=$SECONDS
  run env BATS_TEST_TIMEOUT=30 "$SANDBOX/scripts/run-tests" tests/a.bats
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 alpha probe"* ]]
  [[ "$output" != *"timeout"* ]]
  ((SECONDS - started < 20))
}

@test "a BATS_TEST_TIMEOUT that is not a whole number of seconds above 0 is a usage error" {
  local value
  for value in 0 010 -5 1.5 2s 'x+1'; do
    run env BATS_TEST_TIMEOUT="$value" "$SCRIPT" README.md
    [ "$status" -eq 2 ] || {
      echo "BATS_TEST_TIMEOUT='$value' exited $status"
      false
    }
    [[ "$output" == *"BATS_TEST_TIMEOUT"* ]]
  done
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

# ---------------------------------------------------------------------------
# Sharding
# ---------------------------------------------------------------------------

@test "--shard deals files largest first in a snake, so each file runs in exactly one shard" {
  _sandbox
  local f pad=0
  # a is the smallest file and e the largest, so the deal order is e d c b a: e to shard 1, d to 2, then back from
  # 2, c to 2 and b to 1, then a to 1.
  for f in a b c d e; do
    _probe "$SANDBOX/tests/$f.bats" "$f probe" "[ 1 -eq 1 ]"
    printf '# %*s\n' "$pad" '' >>"$SANDBOX/tests/$f.bats"
    pad=$((pad + 100))
  done
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf --shard 1/2
  [ "$status" -eq 0 ]
  [ "$(_probes_run)" = abe ]
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf --shard 2/2
  [ "$status" -eq 0 ]
  [ "$(_probes_run)" = cd ]
}

@test "only the first shard runs the perf suite" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "a probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "b probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/perf/slow.bats" "perf probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --all --shard 1/2
  [ "$status" -eq 0 ]
  [[ "$output" == *"perf probe"* ]]
  [ "$(_probes_run)" = a ]
  run "$SANDBOX/scripts/run-tests" --all --shard 2/2
  [ "$status" -eq 0 ]
  [[ "$output" != *"perf probe"* ]]
  [ "$(_probes_run)" = b ]
}

@test "a shard left with no files passes" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "a probe" "[ 1 -eq 1 ]"
  run "$SANDBOX/scripts/run-tests" --no-perf --shard 3/3
  [ "$status" -eq 0 ]
  [ -z "$(_probes_run)" ]
}

@test "a --shard that is not I/N with 1 <= I <= N is a usage error" {
  _require_bats
  local spec
  for spec in 0/2 3/2 1/0 2 x/2 1/x 1/2/3 ''; do
    run "$SCRIPT" --no-perf --shard "$spec"
    [ "$status" -eq 2 ] || {
      echo "--shard '$spec' exited $status"
      false
    }
    [[ "$output" == *"--shard"* ]]
  done
  run "$SCRIPT" --all --shard
  [ "$status" -eq 2 ]
}

@test "an option before the mode is a usage error, not a run of no files" {
  _require_bats
  run "$SCRIPT" --shard 1/2 --all
  [ "$status" -eq 2 ]
  [[ "$output" == *"--shard"* ]]
}

# ---------------------------------------------------------------------------
# Tests within a file in parallel
# ---------------------------------------------------------------------------

# _rendezvous <path> [marker]: a two-test file whose tests each wait up to 5 s
# for the other to start, so it passes only when its tests run concurrently.
_rendezvous() {
  local wait='deadline=$((SECONDS + 5)); until [ -e "$BATS_FILE_TMPDIR/$2" ]; do ((SECONDS < deadline)) || return 1; sleep 0.1; done'
  {
    printf '%s\n' '#!/usr/bin/env bats'
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    printf '%s\n' "meet() { touch \"\$BATS_FILE_TMPDIR/\$1\"; $wait; }"
    printf '%s\n' '@test "first" { meet first second; }' '@test "second" { meet second first; }'
  } >"$1"
}

@test "a file that declares run-tests: parallel runs its tests concurrently" {
  _sandbox
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  _rendezvous "$SANDBOX/tests/a.bats" '# run-tests: parallel'
  _probe "$SANDBOX/tests/b.bats" "b probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 first"* ]]
  [[ "$output" == *"ok 2 second"* ]]
}

@test "a file without the declaration runs its tests one at a time" {
  _sandbox
  _rendezvous "$SANDBOX/tests/a.bats"
  _probe "$SANDBOX/tests/b.bats" "b probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 first"* ]]
}

@test "a shard left with one declared file still runs its tests concurrently" {
  _sandbox
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  _rendezvous "$SANDBOX/tests/a.bats" '# run-tests: parallel'
  _probe "$SANDBOX/tests/b.bats" "b probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf --shard 1/2
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 2 second"* ]]
}

@test "a suite that declares run-tests: parallel and interrupts the code under test resets the signal first" {
  # bats starts each concurrent test as a background job, and bash 5.3 starts those with SIGINT and SIGQUIT ignored,
  # so code under test that traps either must be started with the signal at its default, as perl's $SIG{...} = "DEFAULT"
  # does before an exec.
  local f bad=()
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    grep -qx '# run-tests: parallel' "$f" || continue
    grep -qE 'kill -(INT|QUIT|2|3)\b' "$f" || continue
    grep -qF '$SIG{' "$f" || bad+=("${f##*/}")
  done
  [ "${#bad[@]}" -eq 0 ] || {
    printf 'declares run-tests: parallel and sends SIGINT or SIGQUIT without resetting it: %s\n' "${bad[@]}"
    false
  }
}

@test "named files run one process each, behind their markers, as the main suite's do" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "a probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "b probe" "[ 1 -eq 1 ]"
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" tests/a.bats tests/b.bats
  [ "$status" -eq 0 ]
  [[ "$output" == *"# tests/a.bats ("* ]]
  [[ "$output" == *"# tests/b.bats ("* ]]
}

@test "a declared file named alone still runs its tests concurrently" {
  _sandbox
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  _rendezvous "$SANDBOX/tests/a.bats" '# run-tests: parallel'
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" tests/a.bats
  [ "$status" -eq 0 ]
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

@test "each file's marker says how long that file ran" {
  _sandbox
  _probe "$SANDBOX/tests/a.bats" "alpha probe" "[ 1 -eq 1 ]"
  _probe "$SANDBOX/tests/b.bats" "bravo probe" "sleep 0.3"
  run env RUN_TESTS_JOBS=2 "$SANDBOX/scripts/run-tests" --no-perf
  [ "$status" -eq 0 ]
  local a b
  a=$(sed -n 's|^# tests/a\.bats (\([0-9]*\.[0-9]\) s)$|\1|p' <<<"$output")
  b=$(sed -n 's|^# tests/b\.bats (\([0-9]*\.[0-9]\) s)$|\1|p' <<<"$output")
  [ -n "$a" ]
  [ -n "$b" ]
  ((10#${b/./} >= 3))
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

@test "tests get a SIGINT and SIGQUIT they can trap even when run-tests starts in the background" {
  # The hooks start run-tests as a background job, which hands it SIGINT and
  # SIGQUIT ignored. A test that interrupts the code under test needs them
  # trappable, and a bash that starts with one ignored can neither trap nor reset it.
  _sandbox
  local sigint sigquit
  sigint="run bash -c 'trap \"exit 7\" INT; kill -INT \$\$; exit 0'; [ \"\$status\" -eq 7 ]"
  sigquit="run bash -c 'trap \"exit 8\" QUIT; kill -QUIT \$\$; exit 0'; [ \"\$status\" -eq 8 ]"
  _probe "$SANDBOX/tests/a.bats" "sigint probe" "$sigint"
  _probe "$SANDBOX/tests/b.bats" "sigquit probe" "$sigquit"
  run env RUN_TESTS_JOBS=2 bash -c '"$1" --no-perf & wait "$!"' _ "$SANDBOX/scripts/run-tests"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 sigint probe"* ]]
  [[ "$output" == *"ok 1 sigquit probe"* ]]
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
