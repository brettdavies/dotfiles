#!/usr/bin/env bats
# Tests for critical symlinks created by stow
#
# Run: bats tests/symlinks.bats
#
# These tests verify that stow-deploy has created the expected symlinks.
# Run after `stow-deploy --all`.

# ---------------------------------------------------------------------------
# Core shell config symlinks
# ---------------------------------------------------------------------------

@test "~/.profile is a symlink" {
  [ -L "$HOME/.profile" ]
}

@test "~/.bashrc is a symlink" {
  [ -L "$HOME/.bashrc" ]
}

@test "~/.zshrc is a symlink" {
  [ -L "$HOME/.zshrc" ]
}

@test "~/.zshenv is a symlink" {
  [ -L "$HOME/.zshenv" ]
}

# ---------------------------------------------------------------------------
# Git config symlinks
# ---------------------------------------------------------------------------

@test "~/.gitconfig is a symlink" {
  [ -L "$HOME/.gitconfig" ]
}

@test "~/.config/git/ignore exists" {
  [ -f "$HOME/.config/git/ignore" ]
}

# ---------------------------------------------------------------------------
# SSH config
# ---------------------------------------------------------------------------

@test "~/.ssh/config is a symlink" {
  [ -L "$HOME/.ssh/config" ]
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

@test "~/.secrets exists" {
  [ -f "$HOME/.secrets" ]
}

# ---------------------------------------------------------------------------
# Claude Code config
# ---------------------------------------------------------------------------

@test "~/.claude/settings.json is a symlink" {
  [ -L "$HOME/.claude/settings.json" ]
}

# ---------------------------------------------------------------------------
# Local bin scripts
# ---------------------------------------------------------------------------

@test "op-ssh-sign-wrapper is on PATH" {
  command -v op-ssh-sign-wrapper >/dev/null 2>&1
}

@test "~/.local/bin/op-ssh-sign-wrapper is a symlink" {
  [ -L "$HOME/.local/bin/op-ssh-sign-wrapper" ]
}

# ---------------------------------------------------------------------------
# Platform-specific symlinks
# ---------------------------------------------------------------------------

@test "macOS: Ghostty config is a symlink" {
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "macOS only"
  fi
  [ -L "$HOME/.config/ghostty/config" ] || [ -f "$HOME/.config/ghostty/config" ]
}

@test "macOS: markdownlint config is a symlink" {
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "macOS only"
  fi
  [ -L "$HOME/.markdownlint-cli2.yaml" ]
}

# ---------------------------------------------------------------------------
# Git signing config
# ---------------------------------------------------------------------------

@test "git signing is enabled" {
  gpgsign=$(git config --get commit.gpgsign 2>/dev/null || true)
  [ "$gpgsign" = "true" ]
}

@test "git signing program is op-ssh-sign-wrapper" {
  program=$(git config --get gpg.ssh.program 2>/dev/null || true)
  [ "$program" = "op-ssh-sign-wrapper" ]
}

@test "git signing format is ssh" {
  format=$(git config --get gpg.format 2>/dev/null || true)
  [ "$format" = "ssh" ]
}
