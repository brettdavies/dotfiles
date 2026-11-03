#!/usr/bin/env bats
# The leftover-process guards in tests/lib/processes.bash: the one a suite runs after each test, and the one
# scripts/run-tests runs after each suite, which covers every suite. Each test runs bats nested, as a run from inside an
# agent slot does, and checks what that run left running.
#
# Run: bats tests/leak-guard.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/processes

setup_file() {
  require_linux "the guard reads /proc"
}

setup() {
  CWD=$BATS_TEST_TMPDIR/cwd
  mkdir -p "$CWD"
}

teardown() {
  local pid
  for pid in $(in_cwd); do kill -KILL "$pid" 2>/dev/null || true; done
}

# in_cwd: prints the pid of each process whose working directory is the scratch directory or below it.
in_cwd() {
  find /proc/[0-9]*/cwd -maxdepth 0 \( -lname "$CWD" -o -lname "$CWD/*" \) 2>/dev/null | cut -d/ -f3
}

# none_in_cwd: true once no process has its working directory under the scratch directory, giving the last ones 3 s.
none_in_cwd() {
  local i left pid
  for ((i = 0; i < 30; i++)); do
    left=$(in_cwd)
    [ -n "$left" ] || return 0
    sleep 0.1
  done
  for pid in $left; do echo "still running from $CWD: $pid $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" >&2; done
  return 1
}

# nested FILE [FLAG...]: runs bats on FILE from the scratch directory, with any flags given ahead of it, and with the
# BATS_killer_pid scripts/run-tests gives bats.
nested() {
  run --separate-stderr env BATS_killer_pid="$BATS_WATCHDOG_JOB" \
    bash -c 'cd "$1" && exec bats "${@:3}" "$2"' _ "$CWD" "$1" "${@:2}"
}

# probe BODY: a one-test suite under the scratch directory whose test runs BODY and whose teardown runs the guard.
probe() {
  printf '%s\n' "source '$BATS_TEST_DIRNAME/lib/processes.bash'" \
    'teardown() { stop_spawned; assert_no_leaks; }' "@test \"probe\" { $1; }" >"$BATS_TEST_TMPDIR/probe.bats"
}

@test "the guard fails a test that leaves a grandchild running, names it, and stops it" {
  probe "bash -c 'sleep 30 & exit 0'"
  nested "$BATS_TEST_TMPDIR/probe.bats"
  [ "$status" -eq 1 ]
  [[ $output == *"processes this test started were still running after teardown, and were killed:"*"sleep 30"* ]]
  none_in_cwd
}

@test "a spawned process is stopped with what it started, even once that has a new parent" {
  probe "spawn bash -c '(sleep 30 &); exec sleep 31'; until [ \"\$(pgrep -c -x -s \$! sleep)\" -ge 2 ]; do sleep 0.1; done"
  nested "$BATS_TEST_TMPDIR/probe.bats"
  [ "$status" -eq 0 ]
  none_in_cwd
}

@test "run-tests fails a suite that leaves a process running once bats exits, names it, and stops it" {
  printf '%s\n' '@test "leak" { sleep 31 </dev/null >/dev/null 2>&1 3>&- & }' >"$CWD/leaky.bats"
  LEAK_GUARD_PROBE=$BATS_TEST_TMPDIR run --separate-stderr "$BATS_TEST_DIRNAME/../scripts/run-tests" "$CWD/leaky.bats"
  [ "$status" -eq 1 ]
  [[ $stderr == *"processes $CWD/leaky.bats started were still running after bats exited, and were killed:"*"sleep 31"* ]]
  [ -z "$(processes_with "LEAK_GUARD_PROBE=$BATS_TEST_TMPDIR")" ]
}

@test "under a time limit, the guard passes a passing test and fails a failing one only for its failure" {
  probe "true"
  BATS_TEST_TIMEOUT=60 nested "$BATS_TEST_TMPDIR/probe.bats"
  [ "$status" -eq 0 ]
  probe "false"
  BATS_TEST_TIMEOUT=60 nested "$BATS_TEST_TMPDIR/probe.bats"
  [ "$status" -eq 1 ]
  [[ $output != *timeout* ]]
  [[ $output != *"were killed"* ]]
  none_in_cwd
}

@test "a test stopped at the time limit is named, and teardown stops what it left, even what ignores SIGTERM" {
  probe "spawn bash -c 'trap \"\" TERM; exec sleep 30'; bash -c 'trap \"\" TERM; exec sleep 31' & sleep 32"
  BATS_TEST_TIMEOUT=2 nested "$BATS_TEST_TMPDIR/probe.bats"
  [ "$status" -eq 1 ]
  [[ $output == *"not ok 1 probe # timeout after 2s"* ]]
  [[ $output == *"processes this test started were still running after teardown, and were killed:"*"sleep 31"* ]]
  none_in_cwd
}

@test "run-tests names and stops what a test stopped at the time limit left running, even what ignores SIGTERM" {
  printf '%s\n' "@test \"hang\" { bash -c 'trap \"\" TERM; exec sleep 31' </dev/null >/dev/null 2>&1 3>&- & sleep 32; }" \
    >"$CWD/hung.bats"
  LEAK_GUARD_PROBE=$BATS_TEST_TMPDIR BATS_TEST_TIMEOUT=2 \
    run --separate-stderr "$BATS_TEST_DIRNAME/../scripts/run-tests" "$CWD/hung.bats"
  [ "$status" -eq 1 ]
  [[ $output == *"not ok 1 hang # timeout after 2s"* ]]
  [[ $stderr == *"processes $CWD/hung.bats started were still running after bats exited, and were killed:"*"sleep 31"* ]]
  [ -z "$(processes_with "LEAK_GUARD_PROBE=$BATS_TEST_TMPDIR")" ]
}

@test "the release suite, run from a scratch directory, leaves no process behind with that directory as its cwd" {
  # Its tests run concurrently, as scripts/run-tests runs a suite that declares `# run-tests: parallel`.
  local flags=()
  if command -v flock >/dev/null 2>&1; then flags=(--jobs "$(nproc)" --no-parallelize-across-files); fi
  nested "$BATS_TEST_DIRNAME/agent-slot-release.bats" "${flags[@]}"
  [ "$status" -eq 0 ]
  none_in_cwd
}
