#!/usr/bin/env bats
# Integration tests for stow-deploy (actually stows to $HOME)
#
# Run: bats tests/stow-deploy-integration.bats
#
# These tests run the real stow-deploy against $HOME. They are safe to run
# repeatedly (idempotent) but do modify symlinks under $HOME.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

setup() {
  # Integration tests modify $HOME — only run on deployed hosts (where
  # ~/.profile is already a stow-managed symlink). On a fresh CI runner
  # without git-crypt unlock for encrypted packages, the script would
  # fail on preflight; skip cleanly.
  if [ ! -L "$HOME/.profile" ]; then
    skip "dotfiles not deployed (no ~/.profile symlink) — run scripts/stow-deploy first"
  fi
}

# ---------------------------------------------------------------------------
# Full deployment
# ---------------------------------------------------------------------------

@test "--all deploys all expected packages" {
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]

  [[ "$output" == *"Stowing secrets"* ]]
  [[ "$output" == *"Stowing shell"* ]]
  [[ "$output" == *"Stowing claude"* ]]
  [[ "$output" == *"Stowing local"* ]]
  [[ "$output" == *"Stowing brew"* ]]

  if [ "$(uname -s)" = "Darwin" ]; then
    [[ "$output" == *"Stowing ghostty"* ]]
    [[ "$output" == *"Stowing cursor"* ]]
    [[ "$output" == *"Stowing launchagent"* ]]
  fi
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "--all is idempotent (re-run produces no conflicts)" {
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]

  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" != *"Adopting"* ]]
  [[ "$output" != *"ERROR"* ]]
  [[ "$output" != *"FATAL"* ]]
}

# ---------------------------------------------------------------------------
# Post-stow validation
# ---------------------------------------------------------------------------

@test "SSH validation runs and passes" {
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validating SSH config"* ]]
  [[ "$output" == *"SSH config OK"* ]]
}

# ---------------------------------------------------------------------------
# Git local config template
# ---------------------------------------------------------------------------

@test "git local config template is deployed or skipped" {
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking git local config"* ]]

  if [ "$(uname -s)" = "Linux" ]; then
    # On Linux, template should be deployed (or already exist)
    [[ "$output" == *"Deployed git local config"* ]] || \
      [[ "$output" == *"Git local config exists"* ]]
  else
    # On macOS, no template exists — informational message
    [[ "$output" == *"not needed"* ]] || \
      [[ "$output" == *"Git local config exists"* ]]
  fi
}

# ---------------------------------------------------------------------------
# qmd collections config template
# ---------------------------------------------------------------------------

@test "qmd collections config is rendered or skipped, never a dangling symlink" {
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking qmd collections config"* ]]

  # A platform template exists for both darwin and linux, so the live file is
  # either freshly rendered or already present — but never absent.
  [[ "$output" == *"Deployed qmd collections config"* ]] || \
    [[ "$output" == *"qmd collections config exists"* ]]

  # The deployed file must be a real file with absolute paths — never a symlink
  # (the bug this replaced) and never an unexpanded ${HOME} token.
  [ -f "$HOME/.config/qmd/index.yml" ]
  [ ! -L "$HOME/.config/qmd/index.yml" ]
  ! grep -q '${HOME}' "$HOME/.config/qmd/index.yml"
  grep -q "path: $HOME/" "$HOME/.config/qmd/index.yml"
}

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "script passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$SCRIPT"
  [ "$status" -eq 0 ]
}
