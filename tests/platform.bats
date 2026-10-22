#!/usr/bin/env bats
# Tests for tests/lib/platform.bash, the gate a suite calls from setup_file
# when its code under test cannot run on the other OS. A gate that skipped on
# its own OS would let CI pass while running none of the gated suite.
#
# Run: bats tests/platform.bats

LIB="$BATS_TEST_DIRNAME/lib/platform.bash"

# _gated_suite <os>: a one-test suite gated to <os> through the real helper.
_gated_suite() {
  local dir="$BATS_TEST_TMPDIR/suite"
  mkdir -p "$dir/lib"
  cp "$LIB" "$dir/lib/platform.bash"
  printf '%s\n' '#!/usr/bin/env bats' \
    "setup_file() { load lib/platform; require_os $1 'probe reason'; }" \
    '@test "gated probe" { true; }' >"$dir/probe.bats"
  run bats "$dir/probe.bats"
}

@test "require_os lets a suite gated to this OS run" {
  _gated_suite "$(uname -s)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe"* ]]
  [[ "$output" != *"# skip"* ]]
}

@test "require_os skips a suite gated to another OS, naming the reason" {
  _gated_suite NotThisOS
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe # skip NotThisOS only: probe reason"* ]]
}
