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

# Over 1 MiB of 7-byte lines between a first and a last line, so the 1 MiB cut lands inside a line.
_big_log() {
  { echo first; yes filler | head -n 160000; echo last; } >"$1"
}

@test "cuts a log past 1 MiB down to its last 1 MiB from the first whole line, keeping no other copy" {
  _big_log "$logs/demo.log"
  _big_log "$logs/demo.error.log"
  run "$WRAPPER" demo.log "$job" run
  [ "$status" -eq 0 ]
  [ ! -e "$logs/demo.log.1" ]
  [ ! -e "$logs/demo.error.log.1" ]
  [ "$(wc -c <"$logs/demo.log")" -le $((1048576 + 8)) ]
  [ "$(head -n 1 "$logs/demo.log")" = filler ]
  [ "$(tail -n 2 "$logs/demo.log")" = "$(printf 'last\nout run')" ]
  [ "$(head -n 1 "$logs/demo.error.log")" = filler ]
  [ "$(tail -n 2 "$logs/demo.error.log")" = "$(printf 'last\nerr run')" ]
}

@test "leaves a log of 1 MiB or less in place" {
  head -c 1048576 /dev/zero | tr '\0' x >"$logs/demo.log"
  run "$WRAPPER" demo.log "$job" run
  [ "$status" -eq 0 ]
  [ ! -e "$logs/demo.log.1" ]
  [ "$(wc -c <"$logs/demo.log")" -eq 1048584 ]
}
