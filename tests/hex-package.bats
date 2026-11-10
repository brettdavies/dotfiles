#!/usr/bin/env bats
# The hex package stows Hex's settings from ~/Library/Application Support/hex/.
# This repo is public and Hex writes vocabulary terms (people's names), app and
# site rules, device names, and calendar identifiers into that file, so every
# file in the package must be git-crypt encrypted. Its target is also a stowed
# path with a space in it.
#
# Run: bats tests/hex-package.bats

REPO="$BATS_TEST_DIRNAME/.."

setup() {
  export STOW_DEPLOY_TARGET="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STOW_DEPLOY_TARGET"
}

@test "every file in the hex package is git-crypt encrypted" {
  local files
  files=$(cd "$REPO" && find stow/hex -type f)
  [ -n "$files" ]
  while IFS= read -r file; do
    attr=$(git -C "$REPO" check-attr filter -- "$file")
    if [[ "$attr" != *": filter: git-crypt" ]]; then
      echo "not encrypted: $attr"
      return 1
    fi
  done <<<"$files"
}

@test "stow-deploy links and adopts a package file whose path has a space" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  load lib/dotfiles-fixture
  local repo="$BATS_TEST_TMPDIR/repo"
  local rel="Library/Application Support/fixture/settings.json"
  fixture_repo "$repo"
  mkdir -p "$repo/stow/claude/$(dirname "$rel")"
  printf '{}\n' >"$repo/stow/claude/$rel"
  fixture_git "$repo" add -A
  fixture_git "$repo" commit -q -m space
  mkdir -p "$STOW_DEPLOY_TARGET/$(dirname "$rel")"
  printf '{"plain": true}\n' >"$STOW_DEPLOY_TARGET/$rel"
  run "$repo/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/$rel" ]
  [ "$(cat "$STOW_DEPLOY_TARGET/$rel")" = '{}' ]
}
