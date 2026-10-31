# shellcheck shell=bash
# A throwaway dotfiles checkout for suites that run scripts/stow-deploy or the
# post-merge and post-checkout hooks: a test can dirty it, pull into it, and
# stow it into a sandbox target without touching this checkout or the real home.
#
# The fixture's package files sit at the top of each package (dot-fixture-*),
# never under a nested dot- directory: CI installs Stow from apt, and Stow 2.3.x
# mishandles nested dot- directories under --dotfiles.

FIXTURE_SRC="$BATS_TEST_DIRNAME/.."

# fixture_git <dir> <git args>...: git in <dir> with a fixture identity and no
# signing, so commits work on a host whose global config signs them.
fixture_git() {
  local dir=$1
  shift
  git -C "$dir" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

# fixture_repo <dir>: a repository on dev with one commit holding a copy of
# scripts/stow-deploy and two packages, claude and secrets. Its hooks stay off
# (core.hooksPath=/dev/null) until a test turns them on.
fixture_repo() {
  local dir=$1
  mkdir -p "$dir/scripts" "$dir/stow/claude" "$dir/stow/secrets"
  git init -q -b dev "$dir"
  git -C "$dir" config core.hooksPath /dev/null
  cp "$FIXTURE_SRC/scripts/stow-deploy" "$dir/scripts/stow-deploy"
  printf '{}\n' >"$dir/stow/claude/dot-fixture-settings.json"
  printf '#!/bin/sh\nexit 0\n' >"$dir/stow/claude/dot-fixture-guard.sh"
  chmod +x "$dir/stow/claude/dot-fixture-guard.sh"
  printf 'export FIXTURE=1\n' >"$dir/stow/secrets/dot-secrets"
  fixture_git "$dir" add -A
  fixture_git "$dir" commit -q -m seed
}
