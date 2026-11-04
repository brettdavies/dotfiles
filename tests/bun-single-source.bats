#!/usr/bin/env bats
# Bun comes from Homebrew's official tap, and from nowhere else.
#
# Bun ships two install paths: the curl script, which drops a self-updating
# binary in ~/.bun/bin, and `oven-sh/bun`, the tap the Bun team maintain. The
# usual reason to avoid a package manager, that its formula trails upstream,
# does not apply to a first-party tap: it tracks the same releases.
#
# Installing both is the failure this file guards. ~/.bun/bin precedes the
# Homebrew prefix on the assembled PATH, so the curl copy wins every lookup
# while `brew upgrade` maintains the copy nothing runs. Each updates through a
# mechanism blind to the other, and `bun --version` is the only place the drift
# shows. Bun's own docs say to upgrade with whatever installed it and not to mix
# the two.
#
# ~/.bun/bin itself stays on PATH: `bun add -g` installs there whichever binary
# is in charge, and ~/.bun/install is bun's package cache. Only the bun and bunx
# executables in that directory are the duplicate.
#
# Run: bats tests/bun-single-source.bats

bats_require_minimum_version 1.5.0

BREWFILE="$BATS_TEST_DIRNAME/../stow/brew/Brewfile"

@test "the Brewfile declares the official bun tap" {
  grep -qE '^tap "oven-sh/bun"$' "$BREWFILE"
}

@test "the Brewfile installs bun from that tap, not a third-party formula" {
  grep -qE '^brew "oven-sh/bun/bun"$' "$BREWFILE"
}

@test "no curl-installed bun executable shadows the Homebrew one" {
  local found=""
  for exe in bun bunx; do
    [ -e "$HOME/.bun/bin/$exe" ] && found="$found $exe"
  done
  [ -z "$found" ] || {
    echo "curl-installed executables present in ~/.bun/bin:$found" >&2
    echo "They precede the Homebrew prefix on PATH, so brew upgrade maintains" >&2
    echo "a bun nothing runs. Remove just these:  trash ~/.bun/bin/{bun,bunx}" >&2
    echo "Keep the directory itself: bun add -g installs into it." >&2
    return 1
  }
}

@test "bun resolves from the Homebrew prefix on a host that has both" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed on this host"
  command -v brew >/dev/null 2>&1 || skip "Homebrew not installed on this host"
  local prefix resolved
  prefix=$(brew --prefix)
  resolved=$(command -v bun)
  case "$resolved" in
    "$prefix"/*) ;;
    *)
      echo "bun resolved to '$resolved', outside the Homebrew prefix '$prefix'" >&2
      return 1
      ;;
  esac
}
