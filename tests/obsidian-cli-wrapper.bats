#!/usr/bin/env bats
# Tests for stow/obsidian/dot-local/bin/obsidian, the wrapper around the
# bundled Obsidian CLI. The CLI reaches the running app through
# $XDG_RUNTIME_DIR/.obsidian-cli.sock, so the wrapper has to supply that
# directory when the calling shell did not get one from a login session.
#
# Run: bats tests/obsidian-cli-wrapper.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
WRAPPER="$REPO_ROOT/stow/obsidian/dot-local/bin/obsidian"

setup() {
  WORK="$(mktemp -d)"
  printf '#!/bin/sh\nprintf "%%s\\n" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" "args=$*"\n' > "$WORK/obsidian-cli"
  chmod +x "$WORK/obsidian-cli"
  sed "s#/opt/Obsidian/obsidian-cli#$WORK/obsidian-cli#" "$WRAPPER" > "$WORK/obsidian"
  chmod +x "$WORK/obsidian"
}

teardown() {
  rm -rf "$WORK"
}

@test "an unset XDG_RUNTIME_DIR defaults to the user's runtime directory" {
  run sh -c 'unset XDG_RUNTIME_DIR; exec "$1" vaults' _ "$WORK/obsidian"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "XDG_RUNTIME_DIR=/run/user/$(id -u)" ]
  [ "${lines[1]}" = "args=vaults" ]
}

@test "a caller's XDG_RUNTIME_DIR is left alone" {
  XDG_RUNTIME_DIR="$WORK/runtime" run "$WORK/obsidian" vaults
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "XDG_RUNTIME_DIR=$WORK/runtime" ]
}
