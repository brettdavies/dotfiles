#!/usr/bin/env bats
# The auto-format hook's Rust arm formats a file with the edition of the package
# that owns it, the edition `cargo fmt` passes to rustfmt. Standalone rustfmt
# reads no edition from Cargo.toml and falls back to 2015, whose style sorts a
# mixed-case `use` list differently from 2024's. In an edition-2024 crate with
# no rustfmt.toml, a one-line edit would re-sort `use` lists the edit never
# touched, and `cargo fmt --check` would reject the result.

setup() {
  # An inherited GIT_DIR outranks `-C`, so the hook's work-tree probe would read
  # whichever repo the caller was in. Git exports these to hooks.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v rustfmt >/dev/null 2>&1 || skip "rustfmt not installed"
  echo 'fn main() {}' | rustfmt --edition 2024 >/dev/null 2>&1 \
    || skip "rustfmt predates edition 2024"

  HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/auto-format.sh"

  # A git work tree, so the hook formats it even though it sits under a temp dir.
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
}

# Style edition 2024 keeps this order; every earlier style edition re-sorts it.
MIXED='use std::sync::mpsc::{Sender, channel};'
SORTED_2015='use std::sync::mpsc::{channel, Sender};'

# write_file PATH LINE...: PATH inside the repo, one line per argument.
write_file() {
  local path="$REPO/$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" >"$path"
}

# write_rs PATH: a source file whose first line is the mixed-case `use` list.
write_rs() {
  write_file "$1" "$MIXED" '' 'fn main() {}'
}

# run_hook PATH: feed the hook a PostToolUse payload for that file.
run_hook() {
  jq -n --arg f "$REPO/$1" '{tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1 || true
}

# assert_use PATH EXPECTED: the file's first line equals EXPECTED.
assert_use() {
  local got
  got=$(head -n 1 "$REPO/$1")
  if [ "$got" != "$2" ]; then
    printf 'expected: %s\ngot:      %s\n' "$2" "$got"
    return 1
  fi
}

@test "an edition-2024 crate with no rustfmt.toml keeps the 2024 use order" {
  write_file Cargo.toml '[package]' 'name = "demo"' 'version = "0.1.0"' 'edition = "2024"'
  write_rs tests/flags.rs
  run_hook tests/flags.rs
  assert_use tests/flags.rs "$MIXED"
}

@test "a workspace member with edition.workspace = true takes the workspace's edition" {
  write_file Cargo.toml '[workspace]' 'members = ["crates/*"]' '' \
    '[workspace.package]' 'edition = "2024"'
  write_file crates/member/Cargo.toml '[package]' 'name = "member"' \
    'version = "0.1.0"' 'edition.workspace = true'
  write_rs crates/member/src/lib.rs
  run_hook crates/member/src/lib.rs
  assert_use crates/member/src/lib.rs "$MIXED"
}

@test "an indented, single-quoted edition key is read" {
  write_file Cargo.toml '[package]' 'name = "demo"' 'version = "0.1.0"' \
    "  edition = '2024'  # house style"
  write_rs src/main.rs
  run_hook src/main.rs
  assert_use src/main.rs "$MIXED"
}

@test "a package with no edition key formats as 2015, not as its workspace's edition" {
  # Cargo reads a missing edition as 2015 and inherits the workspace's only on
  # `edition.workspace = true`, so the root's 2024 must not reach this member.
  write_file Cargo.toml '[workspace]' 'members = ["legacy"]' '' \
    '[workspace.package]' 'edition = "2024"'
  write_file legacy/Cargo.toml '[package]' 'name = "legacy"' 'version = "0.1.0"'
  write_rs legacy/src/lib.rs
  run_hook legacy/src/lib.rs
  assert_use legacy/src/lib.rs "$SORTED_2015"
}

@test "a .rs file outside any crate is still formatted, with rustfmt's default edition" {
  write_rs scratch/snippet.rs
  run_hook scratch/snippet.rs
  assert_use scratch/snippet.rs "$SORTED_2015"
}
