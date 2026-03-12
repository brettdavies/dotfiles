#!/usr/bin/env bats
# Tests for op-ssh-sign-wrapper (cross-platform SSH signing)
#
# Run: bats tests/op-ssh-sign-wrapper.bats

WRAPPER="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/op-ssh-sign-wrapper"

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "op-ssh-sign-wrapper passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$WRAPPER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "op-ssh-sign-wrapper is executable" {
  [ -x "$WRAPPER" ]
}

@test "op-ssh-sign-wrapper uses /bin/sh (POSIX)" {
  head -1 "$WRAPPER" | grep -q "/bin/sh"
}

# ---------------------------------------------------------------------------
# Platform safety: macOS never falls through to ssh-keygen
# ---------------------------------------------------------------------------

@test "Linux guard prevents macOS ssh-keygen fallback" {
  # The wrapper must check uname -s = Linux before falling back to ssh-keygen
  grep -q 'uname -s.*=.*Linux' "$WRAPPER"
}

@test "checks 1Password macOS path first" {
  # First executable check should be the macOS 1Password path
  first_check=$(grep -n '^\(if\|elif\).*-x' "$WRAPPER" | head -1)
  echo "$first_check" | grep -q "1Password.app"
}

@test "checks 1Password Linux path second" {
  second_check=$(grep -n '^\(if\|elif\).*-x' "$WRAPPER" | sed -n '2p')
  echo "$second_check" | grep -q "/opt/1Password"
}

@test "ssh-keygen is last resort (after both 1Password paths)" {
  last_exec=$(grep -n 'exec ssh-keygen' "$WRAPPER")
  linux_check=$(grep -n 'uname -s.*Linux' "$WRAPPER")
  # ssh-keygen exec must appear after the Linux guard
  last_line=$(echo "$last_exec" | cut -d: -f1)
  guard_line=$(echo "$linux_check" | cut -d: -f1)
  [ "$last_line" -gt "$guard_line" ]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "wrapper exits non-zero when no signing method available" {
  # The else branch must exit 1 (error message spans several lines before exit)
  grep -A6 '^else' "$WRAPPER" | grep -q 'exit 1'
}

# ---------------------------------------------------------------------------
# Git config references wrapper
# ---------------------------------------------------------------------------

@test "gitconfig references op-ssh-sign-wrapper" {
  grep -q 'op-ssh-sign-wrapper' "$BATS_TEST_DIRNAME/../stow/git/dot-gitconfig"
}
