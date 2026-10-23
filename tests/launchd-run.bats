#!/usr/bin/env bats
# Tests for scripts/launchd-run.sh, which a LaunchAgent runs its job through so the job's output lands in a rotated log.
#
# Run: bats tests/launchd-run.bats

bats_require_minimum_version 1.5.0

WRAPPER="$BATS_TEST_DIRNAME/../scripts/launchd-run.sh"

setup() {
  export LAUNCHD_LOG_DIR="$BATS_TEST_TMPDIR/Logs"
  logs=$LAUNCHD_LOG_DIR
  mkdir -p "$logs"
  job="$BATS_TEST_TMPDIR/job"
  printf '#!/bin/sh\necho "out $*"\necho "err $*" >&2\n' >"$job"
  chmod +x "$job"
}

@test "appends the job's stdout to the named log and its stderr to the log's .error.log" {
  run "$WRAPPER" demo.jsonl "$job" a b
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$WRAPPER" demo.jsonl "$job" c
  [ "$(cat "$logs/demo.jsonl")" = "$(printf 'out a b\nout c')" ]
  [ "$(cat "$logs/demo.error.log")" = "$(printf 'err a b\nerr c')" ]
}

@test "moves a log past 1 MiB to <log>.1 before the run, replacing the one before" {
  head -c 1048577 /dev/zero | tr '\0' x >"$logs/demo.log"
  head -c 1048577 /dev/zero | tr '\0' y >"$logs/demo.error.log"
  echo older >"$logs/demo.log.1"
  run "$WRAPPER" demo.log "$job" run
  [ "$status" -eq 0 ]
  [ "$(wc -c <"$logs/demo.log.1")" -eq 1048577 ]
  [ "$(wc -c <"$logs/demo.error.log.1")" -eq 1048577 ]
  [ "$(cat "$logs/demo.log")" = "out run" ]
  [ "$(cat "$logs/demo.error.log")" = "err run" ]
}

@test "leaves a log of 1 MiB or less in place" {
  head -c 1048576 /dev/zero | tr '\0' x >"$logs/demo.log"
  run "$WRAPPER" demo.log "$job" run
  [ "$status" -eq 0 ]
  [ ! -e "$logs/demo.log.1" ]
  [ "$(wc -c <"$logs/demo.log")" -eq 1048584 ]
}
