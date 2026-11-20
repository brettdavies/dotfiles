#!/usr/bin/env bats
# Tests for tests/lib/platform.bash: the gates a suite or a test calls when its
# code under test needs one platform, and the uname stub every suite fakes the
# platform with. A gate that skipped on Linux would let CI pass while running
# none of the gated suite.
#
# Run: bats tests/platform.bats

LIB="$BATS_TEST_DIRNAME/lib/platform.bash"

setup_file() {
  load lib/platform
  export UNAME_STUBS="$BATS_FILE_TMPDIR/stubs"
  stub_uname "$UNAME_STUBS"
}

setup() {
  load lib/platform
  load lib/processes
  PATH="$UNAME_STUBS:$PATH"
  unset STUB_UNAME STUB_UNAME_R STUB_UNAME_M
}

# _probe <os> <gate> [setup_file command]: run a one-test suite whose test calls
# <gate> through the real helper, with the stub reporting <os>.
_probe() {
  local dir="$BATS_TEST_TMPDIR/suite"
  mkdir -p "$dir/lib"
  cp "$LIB" "$dir/lib/platform.bash"
  printf '%s\n' '#!/usr/bin/env bats' \
    "setup_file() { load lib/platform; ${3:-true}; }" \
    "@test \"gated probe\" { load lib/platform; $2 'probe reason'; }" >"$dir/probe.bats"
  STUB_UNAME=$1 run env BATS_killer_pid="$BATS_WATCHDOG_JOB" bats "$dir/probe.bats"
}

@test "require_linux lets a gated suite run on Linux" {
  _probe Linux true "require_linux 'probe reason'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe"* ]]
  [[ "$output" != *"# skip"* ]]
}

@test "require_linux skips a gated suite elsewhere, naming the reason" {
  _probe Darwin true "require_linux 'probe reason'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 gated probe # skip Linux only: probe reason"* ]]
}

@test "require_linux in a test skips that test alone" {
  _probe Darwin require_linux
  [[ "$output" == *"ok 1 gated probe # skip Linux only: probe reason"* ]]
  _probe Linux require_linux
  [[ "$output" == *"ok 1 gated probe"* && "$output" != *"# skip"* ]]
}

@test "require_macos runs its test on macOS and skips it elsewhere, naming the reason" {
  _probe Darwin require_macos
  [[ "$output" == *"ok 1 gated probe"* && "$output" != *"# skip"* ]]
  _probe Linux require_macos
  [[ "$output" == *"ok 1 gated probe # skip macOS only: probe reason"* ]]
}

@test "the stub answers -s, -r and -m from its variables, and bare uname as -s" {
  STUB_UNAME=Darwin STUB_UNAME_R=25.1.0 STUB_UNAME_M=arm64 run uname -s -r -m
  [ "$output" = "Darwin 25.1.0 arm64" ]
  STUB_UNAME=Darwin run uname
  [ "$output" = Darwin ]
}

@test "the stub answers as the real uname for a variable left unset and for any other option" {
  [ "$(uname -s)" = "$(command -p uname -s)" ]
  [ "$(uname -m)" = "$(command -p uname -m)" ]
  [ "$(STUB_UNAME=Darwin uname -n)" = "$(command -p uname -n)" ]
}

@test "stub_uname writes a read-only stub and keeps it on a second call" {
  local dir="$BATS_TEST_TMPDIR/again"
  stub_uname "$dir"
  [ ! -w "$dir/uname" ] || [ "$(id -u)" -eq 0 ]
  [ -x "$dir/uname" ]
  run stub_uname "$dir"
  [ "$status" -eq 0 ]
}

# A suite that writes its own uname stub, or skips on the host's OS name inline,
# decides the platform outside lib/platform.bash.
@test "no suite but platform.bash writes a uname stub or skips on the host's OS name" {
  cd "$BATS_TEST_DIRNAME"
  local f files=()
  for f in *.bats perf/*.bats lib/*.bash; do
    [ "$f" = lib/platform.bash ] || files+=("$f")
  done
  run grep -nE \
    -e '>[[:space:]]*"?[^[:space:]]*/uname"?([[:space:]]|$)' \
    -e '(^|[[:space:]])_?stub[[:space:]]+uname([[:space:]]|$)' \
    -- "${files[@]}"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  # An OS-name test that skips on its own line (`|| skip`) or the next (`then` / `skip`).
  run awk '
    FNR == 1 { held = "" }
    held != "" && /(^|[[:space:]])skip([[:space:]]|$)/ { print held }
    { held = "" }
    /uname( -s)?\)"?[[:space:]]*[!=]?=[[:space:]]*"?(Darwin|Linux)/ {
      if (/(^|[[:space:]])skip([[:space:]]|$)/) print FILENAME ":" FNR; else held = FILENAME ":" FNR
    }' "${files[@]}"
  [ -z "$output" ] || { printf '%s\n' "$output"; false; }
}
