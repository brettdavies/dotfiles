#!/usr/bin/env bats
# Tests for shell configuration files (profile, zshenv, bashrc, zshrc)
#
# Run: bats tests/shell-config.bats

STOW_DIR="$BATS_TEST_DIRNAME/../stow"
CONFIG_DIR="$BATS_TEST_DIRNAME/../config/shell"

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "dot-profile passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash --exclude=SC1090,SC1091 "$STOW_DIR/shell/dot-profile"
  [ "$status" -eq 0 ]
}

@test "caches.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash "$CONFIG_DIR/caches.sh"
  [ "$status" -eq 0 ]
}

@test "all config/shell/*.sh pass shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash "$CONFIG_DIR"/*.sh
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Syntax validation (both shells)
# ---------------------------------------------------------------------------

@test "dot-bashrc has valid bash syntax" {
  run bash -n "$STOW_DIR/bash/dot-bashrc"
  [ "$status" -eq 0 ]
}

@test "dot-zshrc has valid zsh syntax" {
  run zsh -n "$STOW_DIR/zsh/dot-zshrc"
  [ "$status" -eq 0 ]
}

@test "dot-zshenv has valid zsh syntax" {
  run zsh -n "$STOW_DIR/zsh/dot-zshenv"
  [ "$status" -eq 0 ]
}

@test "dot-zprofile has valid zsh syntax" {
  run zsh -n "$STOW_DIR/zsh/dot-zprofile"
  [ "$status" -eq 0 ]
}

@test "dot-profile has valid bash syntax" {
  run bash -n "$STOW_DIR/shell/dot-profile"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# .zshenv: non-interactive entry point
# ---------------------------------------------------------------------------

@test "zshenv sources .profile" {
  grep -q '\.profile' "$STOW_DIR/zsh/dot-zshenv"
}

@test "zshenv uses DOTFILES_SHELL_DIR sentinel guard" {
  grep -q 'DOTFILES_SHELL_DIR' "$STOW_DIR/zsh/dot-zshenv"
}

# ---------------------------------------------------------------------------
# Interactive guards
# ---------------------------------------------------------------------------

@test "bashrc has interactive guard" {
  # POSIX pattern: case $- in *i*) ;; *) return;; esac
  grep -q 'case \$- in' "$STOW_DIR/bash/dot-bashrc"
}

@test "zshrc has interactive guard" {
  grep -q '\[\[ \$- == \*i\* \]\] || return' "$STOW_DIR/zsh/dot-zshrc"
}

# ---------------------------------------------------------------------------
# .profile: sourcing order (PATH before secrets)
# ---------------------------------------------------------------------------

@test "profile sources Homebrew before secrets" {
  brew_line=$(grep -n 'brew shellenv\|Homebrew\|linuxbrew' "$STOW_DIR/shell/dot-profile" | head -1 | cut -d: -f1)
  secrets_line=$(grep -n '\.secrets' "$STOW_DIR/shell/dot-profile" | head -1 | cut -d: -f1)
  # Homebrew setup must come before secrets sourcing
  [ -n "$brew_line" ] && [ -n "$secrets_line" ] && [ "$brew_line" -lt "$secrets_line" ]
}

# ---------------------------------------------------------------------------
# No hardcoded paths
# ---------------------------------------------------------------------------

@test "no hardcoded /Users/ paths in shell configs" {
  run grep -r "/Users/" "$STOW_DIR/shell/" "$STOW_DIR/bash/" "$STOW_DIR/zsh/" "$CONFIG_DIR/"
  [ "$status" -eq 1 ]  # grep exits 1 when no match
}

# ---------------------------------------------------------------------------
# Cross-platform: Homebrew path detection
# ---------------------------------------------------------------------------

@test "profile handles both macOS and Linux Homebrew paths" {
  grep -q '/opt/homebrew' "$STOW_DIR/shell/dot-profile"
  grep -q 'linuxbrew' "$STOW_DIR/shell/dot-profile"
}

# ---------------------------------------------------------------------------
# config/shell/qmd.sh: QMD_SERVER owned here, not in dot-profile
# ---------------------------------------------------------------------------

@test "qmd.sh exports QMD_SERVER pointing at the sequential-mode daemon" {
  grep -q '^export QMD_SERVER=http://127.0.0.1:7832$' "$CONFIG_DIR/qmd.sh"
}

@test "dot-profile no longer exports QMD_SERVER (owned by config/shell/qmd.sh)" {
  ! grep -q 'QMD_SERVER' "$STOW_DIR/shell/dot-profile"
}

@test "sourcing profile in a fresh shell exports QMD_SERVER" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
  run bash -c 'unset QMD_SERVER; . "$HOME/.profile" >/dev/null 2>&1; echo "$QMD_SERVER"'
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:7832" ]
}

# ---------------------------------------------------------------------------
# Non-interactive environment (functional test)
# ---------------------------------------------------------------------------

@test "non-interactive zsh has DOTFILES_SHELL_DIR set" {
  [ -L "$HOME/.zshenv" ] || skip "dotfiles not deployed (~/.zshenv not a symlink)"
  run zsh -c 'source "$HOME/.zshenv" 2>/dev/null; echo "DIR=${DOTFILES_SHELL_DIR:+SET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIR=SET"* ]]
}

@test "non-interactive bash has DOTFILES_SHELL_DIR set" {
  [ -L "$HOME/.bashrc" ] || skip "dotfiles not deployed (~/.bashrc not a symlink)"
  run bash -c 'source "$HOME/.bashrc" 2>/dev/null; echo "DIR=${DOTFILES_SHELL_DIR:+SET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIR=SET"* ]]
}

# ---------------------------------------------------------------------------
# Startup performance (budget: 500ms interactive, 200ms non-interactive)
# ---------------------------------------------------------------------------

# Helper: measure wall-clock time for a shell invocation (prints ms to stdout)
_measure_ms() {
  local start end
  start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time()')
  eval "$1" >/dev/null 2>&1
  end=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time()')
  /usr/bin/perl -e "printf '%.0f', ($end - $start) * 1000"
}

@test "non-interactive zsh starts under 200ms" {
  ms=$(_measure_ms "zsh -c exit")
  echo "# non-interactive zsh: ${ms}ms" >&3
  [ "$ms" -lt 200 ]
}

@test "non-interactive bash starts under 200ms" {
  ms=$(_measure_ms "bash -c exit")
  echo "# non-interactive bash: ${ms}ms" >&3
  [ "$ms" -lt 200 ]
}

@test "interactive zsh starts under 500ms" {
  ms=$(_measure_ms "zsh -i -c exit")
  echo "# interactive zsh: ${ms}ms" >&3
  [ "$ms" -lt 500 ]
}

@test "interactive bash starts under 500ms" {
  ms=$(_measure_ms "bash -i -c exit")
  echo "# interactive bash: ${ms}ms" >&3
  [ "$ms" -lt 500 ]
}
