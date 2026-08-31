#!/usr/bin/env bats
# Startup-shape coverage for ~/.profile.
#
# config/shell/*.sh files gate their contents on `command -v <tool>`. That guard
# is evaluated at source time, so it only sees the PATH that exists at that
# moment. dot-profile assembles PATH itself (Homebrew, ~/.local/bin, bun, cargo);
# if the sourcing loop runs before that assembly, every guarded file no-ops in
# any shell that did not inherit a populated PATH.
#
# A GUI-launched shell (Ghostty/Terminal.app spawned by launchd) is exactly that
# case: it starts from the system default PATH. A shell descended from one
# inherits the fully-assembled PATH and works, which is what makes the failure
# look like stale environment rather than ordering.
#
# Run: bats tests/shell-startup-shapes.bats

STOW_DIR="$BATS_TEST_DIRNAME/../stow"
CONFIG_DIR="$BATS_TEST_DIRNAME/../config/shell"
PROFILE="$STOW_DIR/shell/dot-profile"

# Line number of the first match, or empty when absent.
_line_of() {
  grep -nE "$1" "$PROFILE" | head -1 | cut -d: -f1
}

# A launchd-spawned shell: system default PATH, none of the vars a parent shell
# would have exported. `env -i` is the only faithful way to model it.
_gui_shell() {
  env -i \
    HOME="$HOME" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-$(id -un)}" \
    TERM=xterm-256color \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$@"
}

# A shell descended from a GUI shell: inherits the assembled PATH and exports.
_descended_shell() {
  env TMUXINATOR_CONFIG= DOTFILES_SHELL_DIR= "$@"
}

_skip_unless_deployed() {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
}

# ---------------------------------------------------------------------------
# Structural: the sourcing loop must run after PATH is fully assembled
# ---------------------------------------------------------------------------

@test "profile sources config/shell after Homebrew is on PATH" {
  brew_line=$(_line_of '^ +export PATH="\$HOMEBREW_PREFIX/bin')
  loop_line=$(_line_of '\$_CONFIG_DIR"/\*\.sh')
  [ -n "$brew_line" ] && [ -n "$loop_line" ]
  [ "$brew_line" -lt "$loop_line" ] || {
    echo "config/shell sourced at line $loop_line, before Homebrew PATH at line $brew_line"
    echo "every config/shell file gated on a Homebrew binary no-ops in a GUI shell"
    false
  }
}

@test "profile sources config/shell after ~/.local/bin is on PATH" {
  local_line=$(_line_of 'HOME/\.local/bin:\$PATH')
  loop_line=$(_line_of '\$_CONFIG_DIR"/\*\.sh')
  [ -n "$local_line" ] && [ -n "$loop_line" ]
  [ "$local_line" -lt "$loop_line" ]
}

@test "profile sources config/shell after bun paths are on PATH" {
  bun_line=$(_line_of '_bun_bin:\$PATH')
  loop_line=$(_line_of '\$_CONFIG_DIR"/\*\.sh')
  [ -n "$bun_line" ] && [ -n "$loop_line" ]
  [ "$bun_line" -lt "$loop_line" ]
}

@test "profile sources config/shell after cargo env" {
  cargo_line=$(_line_of 'HOME/\.cargo/env')
  loop_line=$(_line_of '\$_CONFIG_DIR"/\*\.sh')
  [ -n "$cargo_line" ] && [ -n "$loop_line" ]
  [ "$cargo_line" -lt "$loop_line" ]
}

@test "profile still sources Homebrew before secrets" {
  brew_line=$(_line_of '^ +export PATH="\$HOMEBREW_PREFIX/bin')
  secrets_line=$(_line_of '\. ~/\.secrets')
  [ -n "$brew_line" ] && [ -n "$secrets_line" ]
  [ "$brew_line" -lt "$secrets_line" ]
}

@test "DOTFILES_SHELL_DIR is assigned before the sourcing loop" {
  sentinel_line=$(_line_of '^DOTFILES_SHELL_DIR=')
  loop_line=$(_line_of '\$_CONFIG_DIR"/\*\.sh')
  [ -n "$sentinel_line" ] && [ -n "$loop_line" ]
  [ "$sentinel_line" -lt "$loop_line" ]
}

# ---------------------------------------------------------------------------
# Functional: GUI-launched shells (the regression)
# ---------------------------------------------------------------------------

@test "GUI-launched login zsh exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  run _gui_shell zsh -l -c 'echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]] || {
    echo "output: $output"
    false
  }
}

@test "GUI-launched login bash exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  run _gui_shell bash -l -c 'echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]]
}

@test "GUI-launched login zsh resolves tmuxinator projects" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  run _gui_shell zsh -l -c 'tmuxinator list'
  [ "$status" -eq 0 ]
  # `list` prints a bare header and exits 0 when it finds no projects, so assert
  # on a project name rather than on exit status.
  [[ "$output" == *"dotfiles"* ]] || {
    echo "tmuxinator found no projects in a GUI-launched shell: $output"
    false
  }
}

@test "GUI-launched interactive zsh aliases xurl to xr" {
  _skip_unless_deployed
  command -v xr >/dev/null 2>&1 || skip "xurl-rs (xr) not installed"
  run _gui_shell zsh -ic 'alias xurl'
  [ "$status" -eq 0 ]
  [[ "$output" == *"xr"* ]]
}

@test "GUI-launched login zsh defines the gog wrapper" {
  _skip_unless_deployed
  command -v gog >/dev/null 2>&1 || skip "gogcli not installed"
  run _gui_shell zsh -l -c 'typeset -f gog >/dev/null && echo DEFINED'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEFINED"* ]]
}

# ---------------------------------------------------------------------------
# Functional: shells descended from a GUI shell (must keep working)
# ---------------------------------------------------------------------------

@test "descended zsh exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  run _descended_shell zsh -l -c 'echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]]
}

@test "descended non-interactive zsh exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  run _descended_shell zsh -c 'echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]]
}

# ---------------------------------------------------------------------------
# Functional: other shapes — cron, ssh command, non-login
# ---------------------------------------------------------------------------

@test "cron-shape zsh (no login, bare PATH) exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  # cron gives a minimal PATH and a non-login, non-interactive shell; .zshenv is
  # the only startup file that runs.
  run _gui_shell zsh -c 'echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]]
}

@test "ssh-command-shape bash (non-login, bare PATH) exports TMUXINATOR_CONFIG" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  # `ssh host cmd` runs a non-login, non-interactive bash; ~/.bashrc is sourced
  # via the dotfiles BASH_ENV/rc wiring.
  run _gui_shell bash -c 'source "$HOME/.bashrc" 2>/dev/null; echo "CFG=${TMUXINATOR_CONFIG:-UNSET}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CFG=$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"* ]]
}

@test "GUI-launched shells still get a fully assembled PATH" {
  _skip_unless_deployed
  run _gui_shell zsh -l -c 'echo "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin"* ]]
  if [ -d /opt/homebrew/bin ]; then
    [[ "$output" == *"/opt/homebrew/bin"* ]]
  fi
}

# ---------------------------------------------------------------------------
# Guard: dot-profile must PATH every tool that config/shell gates on
# ---------------------------------------------------------------------------

@test "dot-profile PATHes every tool config/shell gates on" {
  _skip_unless_deployed
  # Top-level `command -v X` guards only — guards inside functions are evaluated
  # at call time. A tool installed here but unreachable from a GUI-launched
  # login shell means dot-profile never adds the directory that provides it.
  guarded=$(grep -hE '^[[:space:]]*if command -v [a-zA-Z0-9_-]+ ' "$CONFIG_DIR"/*.sh |
    sed -E 's/^[[:space:]]*if command -v ([a-zA-Z0-9_-]+) .*/\1/' | sort -u)
  [ -n "$guarded" ] || skip "no top-level command -v guards found"

  missing=""
  for tool in $guarded; do
    command -v "$tool" >/dev/null 2>&1 || continue # not installed here
    _gui_shell zsh -l -c "command -v $tool >/dev/null 2>&1" ||
      missing="$missing $tool"
  done
  [ -z "$missing" ] || {
    echo "installed but unreachable from a GUI-launched login shell:$missing"
    echo "dot-profile does not add the directory providing them"
    false
  }
}

@test "no config/shell file is sourced before the PATH it depends on" {
  # The ordering tests above pin the loop below each PATH block. This asserts the
  # complement: dot-profile contains exactly one sourcing loop, so a second copy
  # cannot reintroduce an early one.
  count=$(grep -cE '\$_CONFIG_DIR"/\*\.sh' "$PROFILE")
  [ "$count" -eq 1 ] || {
    echo "expected 1 config/shell sourcing loop in dot-profile, found $count"
    false
  }
}
