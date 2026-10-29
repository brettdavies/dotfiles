#!/usr/bin/env bats
# The leftover-process guard in tests/lib/processes.bash, and the suites that use it. Each test runs bats nested, from a
# scratch directory of its own, as a run from inside an agent slot runs from the slot.
#
# Run: bats tests/leak-guard.bats

bats_require_minimum_version 1.5.0

load lib/platform

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

# nested FILE: runs bats on FILE from the scratch directory.
nested() {
  run --separate-stderr bash -c 'cd "$1" && exec bats "$2"' _ "$CWD" "$1"
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

@test "the release suite, run from a scratch directory, leaves no process behind with that directory as its cwd" {
  nested "$BATS_TEST_DIRNAME/agent-slot-release.bats"
  [ "$status" -eq 0 ]
  none_in_cwd
}
