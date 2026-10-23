#!/usr/bin/env bats
# Tests for tests/lib/platform.bash, the gate a suite calls from setup_file when
# its code under test cannot run anywhere but Linux. A gate that skipped on
# Linux would let CI pass while running none of the gated suite.
#
# Run: bats tests/platform.bats

LIB="$BATS_TEST_DIRNAME/lib/platform.bash"

# _gated_suite <os>: run a one-test suite gated through the real helper, with
# uname stubbed to report <os> so both branches run on any host.
_gated_suite() {
  local dir="$BATS_TEST_TMPDIR/suite" stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$dir/lib" "$stubs"
  cp "$LIB" "$dir/lib/platform.bash"
  printf '%s\n' '#!/bin/sh' "echo $1" >"$stubs/uname"
  chmod +x "$stubs/uname"
  printf '%s\n' '#!/usr/bin/env bats' \
    "setup_file() { load lib/platform; require_linux 'probe reason'; }" \
    '@test "gated probe" { true; }' >"$dir/probe.bats"
  PATH="$stubs:$PATH" run bats "$dir/probe.bats"
}

@test "require_linux lets a gated suite run on Linux" {
  _gated_suite Linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe"* ]]
  [[ "$output" != *"# skip"* ]]
}

@test "require_linux skips a gated suite elsewhere, naming the reason" {
  _gated_suite Darwin
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe # skip Linux only: probe reason"* ]]
}
