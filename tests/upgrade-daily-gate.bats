#!/usr/bin/env bats
# Tests for scripts/upgrade/daily-gate.sh, which lets an hourly LaunchAgent fire run its job at most once a day and only
# when the network answers. A stub curl stands in for the connectivity probe and UPGRADE_STATE_DIR holds the success
# stamp, so no test reaches the network or ~/.local/state.
#
# Run: bats tests/upgrade-daily-gate.bats

bats_require_minimum_version 1.5.0

GATE="$BATS_TEST_DIRNAME/../scripts/upgrade/daily-gate.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export UPGRADE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  stamp="$UPGRADE_STATE_DIR/demo.last-success"
  ran="$BATS_TEST_TMPDIR/ran"
  # STUB_OFFLINE makes the probe fail the way curl does when no name resolves.
  printf '#!/bin/sh\n[ -z "${STUB_OFFLINE-}" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }\n' >"$STUBS/curl"
  job="$BATS_TEST_TMPDIR/job"
  printf '#!/bin/sh\necho ran >>"%s"\necho "job output"\nexit "${STUB_JOB_EXIT:-0}"\n' "$ran" >"$job"
  chmod +x "$STUBS/curl" "$job"
}

# Sets the stamp's mtime to <hours> ago.
_succeeded_hours_ago() {
  mkdir -p "$UPGRADE_STATE_DIR"
  touch "$stamp"
  perl -e '$t = time - $ARGV[0] * 3600; utime $t, $t, $ARGV[1] or die' "$1" "$stamp"
}

@test "runs the job when it has never succeeded and records the success" {
  run env PATH="$STUBS:$PATH" "$GATE" demo "$job"
  [ "$status" -eq 0 ]
  [ "$output" = "job output" ]
  [ -f "$ran" ]
  [ -f "$stamp" ]
}

@test "a fire within 20 hours of a success exits without running the job or printing anything" {
  _succeeded_hours_ago 19
  run env PATH="$STUBS:$PATH" "$GATE" demo "$job"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ran" ]
}

@test "a success more than 20 hours old lets the job run again and refreshes the record" {
  _succeeded_hours_ago 21
  run env PATH="$STUBS:$PATH" "$GATE" demo "$job"
  [ "$status" -eq 0 ]
  [ -f "$ran" ]
  [ -n "$(find "$stamp" -mmin -5)" ]
}

@test "with the network down the job does not run, nothing is printed, and no success is recorded" {
  run env STUB_OFFLINE=1 PATH="$STUBS:$PATH" "$GATE" demo "$job"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ran" ]
  [ ! -e "$stamp" ]
}

@test "a failed job records no success and passes its exit status through" {
  run env STUB_JOB_EXIT=3 PATH="$STUBS:$PATH" "$GATE" demo "$job"
  [ "$status" -eq 3 ]
  [ -f "$ran" ]
  [ ! -e "$stamp" ]
}
