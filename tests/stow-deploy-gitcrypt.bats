#!/usr/bin/env bats
# Tests for scripts/stow-deploy's refusal to deploy git-crypt ciphertext. A package's
# encrypted files come from .gitattributes, so any package that holds one is checked,
# whatever its name.
#
# Run: bats tests/stow-deploy-gitcrypt.bats
#
# Each test runs a copy of the script in a fixture repo (tests/lib/dotfiles-fixture.bash)
# whose .gitattributes marks one file filter=git-crypt. The fixture configures no
# git-crypt filter, so the file is committed as written: ciphertext is simulated with
# git-crypt's own header, which grep -I reads as binary.

EXIT_PRECONDITION=4

setup() {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  export STOW_DEPLOY_TARGET="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STOW_DEPLOY_TARGET"
  load lib/dotfiles-fixture
  REPO="$BATS_TEST_TMPDIR/repo"
  fixture_repo "$REPO"
}

# encrypt_in_repo <path> <ciphertext|plaintext>: mark <path> filter=git-crypt and commit it
# with git-crypt's header (ciphertext) or as plain text.
encrypt_in_repo() {
  printf '%s filter=git-crypt diff=git-crypt\n' "$1" >>"$REPO/.gitattributes"
  if [ "$2" = ciphertext ]; then
    printf '\000GITCRYPT\000\001\002\003' >"$REPO/$1"
  else
    printf 'plain = "text"\n' >"$REPO/$1"
  fi
  fixture_git "$REPO" add -A
  fixture_git "$REPO" commit -q -m "encrypt $1"
}

@test "a package whose git-crypt file is still ciphertext is refused, whatever its name" {
  encrypt_in_repo stow/claude/dot-fixture-token ciphertext
  run "$REPO/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq "$EXIT_PRECONDITION" ]
  [[ "$output" == *"git-crypt is locked"* ]]
  [[ "$output" == *"stow/claude/dot-fixture-token"* ]]
  [ ! -e "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
}

@test "the same file in plain text deploys" {
  encrypt_in_repo stow/claude/dot-fixture-token plaintext
  run "$REPO/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-token" ]
}

@test "a package without git-crypt files deploys while another package's are locked" {
  encrypt_in_repo stow/secrets/dot-secrets ciphertext
  run "$REPO/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$STOW_DEPLOY_TARGET/.fixture-settings.json" ]
}

@test "a package path with a space is checked too" {
  local file="stow/claude/dot-fixture dir/token"
  mkdir -p "$REPO/$(dirname "$file")"
  # A .gitattributes pattern cannot hold a bare space.
  printf 'stow/claude/dot-fixture[[:space:]]dir/token filter=git-crypt\n' >>"$REPO/.gitattributes"
  printf '\000GITCRYPT\000\001\002\003' >"$REPO/$file"
  fixture_git "$REPO" add -A
  fixture_git "$REPO" commit -q -m "encrypt a path with a space"
  [[ "$(git -C "$REPO" check-attr filter -- "$file")" == *": filter: git-crypt" ]]
  run "$REPO/scripts/stow-deploy" --headless --only claude
  echo "$output"
  [ "$status" -eq "$EXIT_PRECONDITION" ]
  [[ "$output" == *"dot-fixture dir/token"* ]]
}
