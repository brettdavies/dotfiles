#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/bash-env-path.sh
#
# Run: bats tests/claude-bash-env-path.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/bash-env-path.sh"
MARKER='config/shell/local-paths.sh'

setup() {
  TMP_ENV="$(mktemp)"
}

teardown() {
  rm -f "$TMP_ENV"
}

@test "bash-env-path.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash "$HOOK"
  [ "$status" -eq 0 ]
}

@test "no-op (exit 0, no output) when CLAUDE_ENV_FILE is unset" {
  run env -u CLAUDE_ENV_FILE bash "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "appends the local-paths source line when CLAUDE_ENV_FILE is set" {
  CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  run cat "$TMP_ENV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$MARKER"* ]]
}

@test "idempotent: the source line appears once after repeated runs" {
  CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  run grep -cF "$MARKER" "$TMP_ENV"
  [ "$output" -eq 1 ]
}

@test "produced env file sources cleanly when the repo file is absent" {
  HOME=/nonexistent-dotfiles-root CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  run env HOME=/nonexistent-dotfiles-root bash -c "source '$TMP_ENV'"
  [ "$status" -eq 0 ]
}

@test "wiring: sourcing the env file runs \$HOME/dotfiles/config/shell/local-paths.sh" {
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/dotfiles/config/shell"
  printf '%s\n' 'export BASH_ENV_PATH_WIRED=yes' > "$fake_home/dotfiles/config/shell/local-paths.sh"
  CLAUDE_ENV_FILE="$TMP_ENV" bash "$HOOK"
  run env HOME="$fake_home" bash -c "source '$TMP_ENV'; printf '%s' \"\${BASH_ENV_PATH_WIRED:-no}\""
  rm -rf "$fake_home"
  [ "$output" = "yes" ]
}
