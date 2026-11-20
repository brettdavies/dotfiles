#!/usr/bin/env bats
# Tests for config/shell/caches.sh, which points tool caches under XDG_CACHE_HOME.
#
# uname is stub_uname's stub, so the macOS branch runs on Linux CI. Each test
# points XDG_CACHE_HOME at its own directory, so the caches the file creates
# never reach the host's.
#
# Run: bats tests/caches.bats

CACHES="$BATS_TEST_DIRNAME/../config/shell/caches.sh"

setup_file() {
  load lib/platform
  export UNAME_STUBS="$BATS_FILE_TMPDIR/stubs"
  stub_uname "$UNAME_STUBS"
}

# source_caches <os>: source caches.sh in bash with uname reporting <os>, then
# print HOMEBREW_CACHE and the file's own OS variable, each "unset" when unset.
source_caches() {
  STUB_UNAME=$1 XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" run bash -c '
    unset HOMEBREW_CACHE
    PATH="$1:$PATH"
    . "$2" || exit
    echo "${HOMEBREW_CACHE-unset} ${_caches_os-unset}"' _ "$UNAME_STUBS" "$CACHES"
}

@test "on macOS caches.sh puts the Homebrew cache under XDG_CACHE_HOME and creates it" {
  source_caches Darwin
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/cache/homebrew unset" ]
  [ -d "$BATS_TEST_TMPDIR/cache/homebrew" ]
}

@test "on Linux caches.sh sets no Homebrew cache and creates none" {
  source_caches Linux
  [ "$status" -eq 0 ]
  [ "$output" = "unset unset" ]
  [ ! -e "$BATS_TEST_TMPDIR/cache/homebrew" ]
}
