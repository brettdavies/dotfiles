#!/usr/bin/env bats
# Tests that config/shell/caches.sh leaves install roots at their stock defaults
#
# Run: bats tests/install-roots.bats
#
# An install root holds installed tools, not a cache. Relocating one through the
# shell chain takes effect only in contexts that source it: installers, systemd
# user units, git hooks and the agent Bash tool resolve the stock paths
# regardless, so a relocated install root splits one host into two views of its
# tools.
#
# `bats_test_function` generates one test per install root below, and needs
# bats >= 1.11.0. That version also covers the `run !` flag form.
bats_require_minimum_version 1.11.0

STOW_DIR="$BATS_TEST_DIRNAME/../stow"
CONFIG_DIR="$BATS_TEST_DIRNAME/../config/shell"
# The profile under test is this checkout's, not the deployed ~/.profile, so a
# run from a linked worktree checks the worktree's files. Under bash, dot-profile
# resolves the dotfiles root from its own path.
PROFILE="$STOW_DIR/shell/dot-profile"

INSTALL_ROOTS=(CARGO_HOME RUSTUP_HOME BUN_INSTALL)

assert_caches_does_not_assign() {
  run ! grep -qE "^[[:space:]]*(export[[:space:]]+)?$1=" "$CONFIG_DIR/caches.sh"
}

# The `unset` prefix is load-bearing: the suite is often run from a shell that
# still carries the old exported value, and without it these report on the
# inherited environment rather than on the file.
assert_profile_leaves_unset() {
  run bash -c "unset $1; . '$PROFILE' >/dev/null 2>&1; echo \"\${$1:-unset}\""
  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
}

for root in "${INSTALL_ROOTS[@]}"; do
  bats_test_function --description "caches.sh does not assign $root" -- assert_caches_does_not_assign "$root"
  bats_test_function --description "sourcing profile in a fresh shell leaves $root unset" -- assert_profile_leaves_unset "$root"
done

# The ~/.cargo/env block in dot-profile is the only thing that puts cargo on
# PATH, since caches.sh exports neither install root. Hosts carrying no toolchain
# have no env file to source, so this is scoped to hosts that have one.
@test "sourcing profile puts stock ~/.cargo/bin on PATH where a toolchain exists" {
  [ -f "$HOME/.cargo/env" ] || skip "no Rust toolchain on this host (~/.cargo/env absent)"
  run bash -c "unset CARGO_HOME; . '$PROFILE' >/dev/null 2>&1; case \":\$PATH:\" in *\":\$HOME/.cargo/bin:\"*) echo found ;; *) echo missing ;; esac"
  [ "$status" -eq 0 ]
  [ "$output" = "found" ]
}

# Nothing exports the bun root, so the stock bin dir is what has to reach PATH.
# Scoped to hosts that have one, since a host with no bun globals has no dir.
@test "sourcing profile puts stock ~/.bun/bin on PATH where it exists" {
  [ -d "$HOME/.bun/bin" ] || skip "no bun global bin dir on this host (~/.bun/bin absent)"
  run bash -c "unset BUN_INSTALL; . '$PROFILE' >/dev/null 2>&1; case \":\$PATH:\" in *\":\$HOME/.bun/bin:\"*) echo found ;; *) echo missing ;; esac"
  [ "$status" -eq 0 ]
  [ "$output" = "found" ]
}

# The relocated bin dir must not survive in the PATH chain. Leaving it there
# keeps a split host working by accident, which is what hid the divergence.
@test "dot-profile does not put the relocated bun bin dir on PATH" {
  run ! grep -q '\.cache/bun/bin' "$PROFILE"
}
