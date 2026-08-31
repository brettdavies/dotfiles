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

# ---------------------------------------------------------------------------
# Toolchain profile
# ---------------------------------------------------------------------------

@test "rustup installs the minimal profile" {
  command -v rustup >/dev/null 2>&1 || skip "rustup not installed on this host"
  # The default profile bundles rust-docs, ~800MB of offline HTML per toolchain
  # that nothing on a headless host reads. Governs new installs; toolchains
  # already on disk keep whatever they have until the component is removed.
  run rustup show profile
  [ "$status" -eq 0 ]
  [ "$output" = "minimal" ] || {
    echo "rustup profile is '$output'; expected minimal (see BOOTSTRAP.md)"
    false
  }
}

@test "no installed toolchain carries rust-docs" {
  command -v rustup >/dev/null 2>&1 || skip "rustup not installed on this host"
  local carrying=""
  while read -r tc; do
    [ -n "$tc" ] || continue
    if rustup component list --toolchain "$tc" --installed 2>/dev/null | grep -q '^rust-docs'; then
      carrying="$carrying $tc"
    fi
  done < <(rustup toolchain list 2>/dev/null | awk '{print $1}')
  [ -z "$carrying" ] || {
    echo "toolchains still carrying rust-docs:$carrying"
    false
  }
}
