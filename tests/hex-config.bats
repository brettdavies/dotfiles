#!/usr/bin/env bats
# Tests for scripts/hex-config.sh, which keeps Hex's transform config,
# ~/.config/hex/hex.config.ts, a copy of config/hex/hex.config.ts.
#
# Run: bats tests/hex-config.bats
#
# `uname` is a stub in a PATH-prepended directory, so Linux CI passes the
# Darwin gate. Nothing reads or writes the host's Hex: HEX_CONFIG_DIR and
# HEX_APP point at per-test paths.

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SCRIPT="$REPO_ROOT/scripts/hex-config.sh"
DECLARED_FILE="$REPO_ROOT/config/hex/hex.config.ts"
STOW_DEPLOY="$REPO_ROOT/scripts/stow-deploy"
LINT_SHELL="$REPO_ROOT/scripts/lint-shell"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/usr/bin/env bash\necho "${STUB_UNAME:-Darwin}"\n' >"$STUBS/uname"
  chmod +x "$STUBS/uname"
  PATH="$STUBS:$PATH"
  export HEX_CONFIG_DIR="$BATS_TEST_TMPDIR/hex"
  export HEX_APP="$BATS_TEST_TMPDIR/Hex.app"
  mkdir -p "$HEX_APP"
  TARGET="$HEX_CONFIG_DIR/hex.config.ts"
}

@test "the repo's config defines the dotfiles transform the Coding mode selects" {
  grep -q '^    dotfiles: {$' "$DECLARED_FILE"
}

@test "an installed config that matches the repo's is in sync" {
  mkdir -p "$HEX_CONFIG_DIR"
  cp "$DECLARED_FILE" "$TARGET"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "a missing config is drift, and the report names the fix" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not exist"* ]]
  [[ "$stderr" == *"scripts/hex-config.sh --apply"* ]]
  [ ! -e "$TARGET" ]
}

@test "a config edited in place is drift: the report shows the diff and changes nothing" {
  mkdir -p "$HEX_CONFIG_DIR"
  printf 'edited in place\n' >"$TARGET"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"-edited in place"* ]]
  [ "$(cat "$TARGET")" = "edited in place" ]
}

@test "--apply copies the repo's config into place" {
  run --separate-stderr "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  cmp -s "$DECLARED_FILE" "$TARGET"
  [ ! -L "$TARGET" ]
}

@test "a symlinked config is drift, and --apply replaces the link without writing through it" {
  mkdir -p "$HEX_CONFIG_DIR"
  printf 'link target\n' >"$BATS_TEST_TMPDIR/elsewhere.ts"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.ts" "$TARGET"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"symlink"* ]]
  run --separate-stderr "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ ! -L "$TARGET" ]
  cmp -s "$DECLARED_FILE" "$TARGET"
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere.ts")" = "link target" ]
}

@test "with Hex not installed there is nothing to do" {
  rmdir "$HEX_APP"
  run --separate-stderr "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not installed"* ]]
  [ ! -e "$TARGET" ]
}

@test "off macOS there is nothing to do" {
  STUB_UNAME=Linux run --separate-stderr "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"macOS"* ]]
  [ ! -e "$TARGET" ]
}

@test "an unknown argument is a usage error" {
  run --separate-stderr "$SCRIPT" --force
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage:"* ]]
}

@test "stow-deploy runs the check and never applies it" {
  grep -q 'scripts/hex-config.sh"' "$STOW_DEPLOY"
  run ! bash -c "grep -v '^[[:space:]]*#' '$STOW_DEPLOY' | grep -q 'hex-config.sh.*--apply'"
}

@test "the script is executable and a lint target" {
  [ -x "$SCRIPT" ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run "$LINT_SHELL" scripts/hex-config.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) clean"* ]]
}
