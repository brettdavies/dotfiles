#!/usr/bin/env bats
# The cargo package routes git dependency fetches through the git CLI.
#
# Cargo's bundled libgit2 has to satisfy an SSH handshake on its own once
# ~/.gitconfig rewrites an HTTPS dependency URL to git@github.com. It can only do
# that where an agent already holds the key, so every launcher without one fails
# on a dependency the git CLI fetches without trouble.
#
# Run: bats tests/cargo-config.bats

CONFIG="$BATS_TEST_DIRNAME/../stow/cargo/dot-cargo/config.toml"
DEPLOY="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

@test "git fetches are routed through the git CLI, under [net]" {
  # Scoped to the table: a key outside it is silently ignored by cargo rather
  # than rejected, so asserting the bare line would pass on a broken file.
  run bash -c "sed -n '/^\[net\]/,/^\[/p' '$CONFIG' | grep -qE '^git-fetch-with-cli = true$'"
  [ "$status" -eq 0 ]
}

@test "cargo is shared but skipped off Linux" {
  # Listed as shared so the headless hosts get it, and gated so the workstation
  # does not: Rust toolchains are Linux-only here, so on macOS the file would
  # have no reader.
  shared=$(grep '^SHARED_PACKAGES=' "$DEPLOY" | sed 's/.*(\(.*\))/\1/')
  [[ "$shared" == *"cargo"* ]]
  grep -qE '\| *cargo *\)' "$DEPLOY"
}

@test "the deployed config resolves where cargo reads it" {
  [ "$(uname -s)" = "Linux" ] || skip "cargo package is Linux-only"
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
  [ -e "$HOME/.cargo/config.toml" ] || skip "cargo package not deployed on this host"
  run grep -qE '^git-fetch-with-cli = true$' "$HOME/.cargo/config.toml"
  [ "$status" -eq 0 ]
}
