#!/usr/bin/env bats
# Tests for shell configuration files (profile, zshenv, bashrc, zshrc)
#
# Run: bats tests/shell-config.bats
#
# `run !` below asserts a command fails. Bats keeps pre-1.5 `run` semantics
# until a suite opts in, so the declaration is what enables the flag form
# rather than a newer bats: 1.14 still warns BW02 without it.
bats_require_minimum_version 1.5.0

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

# Regression: macOS path_helper (run by /etc/zprofile) rebuilds PATH with the
# system dirs first, demoting keg-only Homebrew Ruby behind /usr/bin so Bundler
# falls back to system Ruby 2.6 / Bundler 1.x. dot-zprofile must re-assert the
# keg-only Ruby bin + gem binstubs, not just $HOMEBREW_PREFIX/bin.
@test "dot-zprofile re-asserts keg-only Homebrew Ruby ahead of system Ruby" {
  [ "$(uname -s)" = "Darwin" ] || skip "macOS-only — path_helper is Apple-specific"
  bp="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null)}"
  [ -n "$bp" ] || skip "no Homebrew prefix"
  [ -d "$bp/opt/ruby/bin" ] || skip "keg-only Homebrew Ruby not installed"
  # Reproduce the post-path_helper order (/usr/bin AHEAD of the demoted Ruby
  # dirs), source the repair, and confirm bundle resolves under Homebrew.
  run zsh -c "
    export HOMEBREW_PREFIX='$bp'
    path=(/usr/bin '$bp/opt/ruby/bin' '$bp'/lib/ruby/gems/*/bin(N))
    source '$STOW_DIR/zsh/dot-zprofile'
    command -v bundle
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "$bp"/* ]] || {
    echo "bundle resolved to '$output' (expected under $bp)"
    false
  }
}

# Regression: bash and non-login shells (the pre-push bats run, cron, editor
# shell tools) demote keg-only Homebrew Ruby behind /usr/bin too, but never
# source dot-zprofile. config/shell/local-paths.sh must FORCE the Ruby bin to
# the front (remove-then-prepend); an add-if-absent guard skips when the dir is
# already present-but-demoted, leaving system Ruby 2.6 / Bundler 1.x winning.
@test "local-paths.sh promotes keg-only Homebrew Ruby ahead of system Ruby in bash" {
  [ "$(uname -s)" = "Darwin" ] || skip "macOS-only — path_helper is Apple-specific"
  bp="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null)}"
  [ -n "$bp" ] || skip "no Homebrew prefix"
  [ -d "$bp/opt/ruby/bin" ] || skip "keg-only Homebrew Ruby not installed"
  # Reproduce the demoted order (/usr/bin AHEAD of an already-present Ruby bin),
  # source the repair in bash, and confirm bundle resolves under Homebrew.
  run bash -c "
    export PATH='/usr/bin:/bin:$bp/opt/ruby/bin:/usr/local/bin'
    . '$CONFIG_DIR/local-paths.sh'
    command -v bundle
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "$bp"/* ]] || {
    echo "bundle resolved to '$output' (expected under $bp)"
    false
  }
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
  [ "$status" -eq 1 ] # grep exits 1 when no match
}

# ---------------------------------------------------------------------------
# Cross-platform: Homebrew path detection
# ---------------------------------------------------------------------------

@test "profile handles both macOS and Linux Homebrew paths" {
  grep -q '/opt/homebrew' "$STOW_DIR/shell/dot-profile"
  grep -q 'linuxbrew' "$STOW_DIR/shell/dot-profile"
}

# ---------------------------------------------------------------------------
# config/shell/qmd.sh: QMD_REMOTE_URL owned here, not in dot-profile
# ---------------------------------------------------------------------------

@test "qmd.sh exports QMD_REMOTE_URL unconditionally" {
  grep -q '^export QMD_REMOTE_URL=http://127.0.0.1:7832$' "$CONFIG_DIR/qmd.sh"
}

@test "qmd.sh guards the QMD_LOW_VRAM export to Linux" {
  grep -qE '\[ "\$\(uname\)" = "Linux" \]' "$CONFIG_DIR/qmd.sh"
  grep -qE '^[[:space:]]+export QMD_LOW_VRAM=1$' "$CONFIG_DIR/qmd.sh"
}

@test "dot-profile no longer exports QMD_REMOTE_URL (owned by config/shell/qmd.sh)" {
  run ! grep -q 'QMD_REMOTE_URL' "$STOW_DIR/shell/dot-profile"
}

@test "sourcing profile in a fresh shell exports QMD_REMOTE_URL on all platforms" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
  run bash -c 'unset QMD_REMOTE_URL; . "$HOME/.profile" >/dev/null 2>&1; echo "$QMD_REMOTE_URL"'
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:7832" ]
}

@test "sourcing profile sets QMD_LOW_VRAM on Linux only" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
  run bash -c 'unset QMD_LOW_VRAM; . "$HOME/.profile" >/dev/null 2>&1; echo "${QMD_LOW_VRAM:-unset}"'
  [ "$status" -eq 0 ]
  if [ "$(uname)" = "Linux" ]; then
    [ "$output" = "1" ]
  else
    [ "$output" = "unset" ]
  fi
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

# Startup latency budgets live in tests/perf/shell-startup-perf.bats, outside
# this directory's glob, so they are measured on a quiet machine rather than at
# the tail of the full suite.
