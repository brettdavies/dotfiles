#!/usr/bin/env bats
# PATH assembly across every shell invocation shape this repo supports.
#
# The supported set is the cross product of {zsh, bash} x {login, non-login} x
# {interactive, non-interactive}, plus the bare launchers that read no startup
# file at all. Which files each shape reads is documented in AGENTS.md "Shell
# Config Chain" and in the startup-file table in
# docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md.
#
#   shape                            reads                              example
#   zsh   login     interactive      .zshenv .zprofile .zshrc .zlogin   terminal window, tmux pane, `ssh host`
#   zsh   login     non-interactive  .zshenv .zprofile .zlogin          `zsh -lc`
#   zsh   non-login interactive      .zshenv .zshrc                     `zsh -i`
#   zsh   non-login non-interactive  .zshenv                            `ssh host cmd`, cron with SHELL=zsh
#   bash  login     interactive      .bash_profile .profile .bashrc     login console, `bash -l`
#   bash  login     non-interactive  .bash_profile .profile             `bash -lc`
#   bash  non-login interactive      .bashrc .profile                   `bash -i`
#   bash  non-login non-interactive  nothing (or $BASH_ENV)             `bash script.sh`, git hooks, CI, agent Bash tool
#
# Every shape is started from an `env -i` launchd-style environment, so a pass
# means the shape assembles PATH itself rather than inheriting it from a parent.
# That is the distinction that matters: a shell descended from a working shell
# looks correct no matter what its own startup files do.
#
# Run: bats tests/shell-path-matrix.bats

BARE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

_skip_unless_deployed() {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
}

# Run a script in one shape, under a launchd-style environment.
_shape() {
  local shell="$1" flags="$2" script="$3"
  env -i \
    HOME="$HOME" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-$(id -un)}" \
    TERM=xterm-256color \
    PATH="$BARE_PATH" \
    "$shell" "$flags" "$script"
}

_path_in() {
  _shape "$1" "$2" 'printf "%s" "$PATH"'
}

# Position of an exact entry within a colon-separated PATH, or -1 when absent.
_index_of() {
  local path_str="$1" want="$2" i=0 entry
  local IFS=:
  for entry in $path_str; do
    [ "$entry" = "$want" ] && {
      printf '%s' "$i"
      return 0
    }
    i=$((i + 1))
  done
  printf '%s' "-1"
}

_assert_contains() {
  local label="$1" path_str="$2" entry="$3"
  [ "$(_index_of "$path_str" "$entry")" -ge 0 ] || {
    echo "$label: PATH is missing $entry"
    echo "PATH=$path_str"
    false
  }
}

# Everything dot-profile is responsible for putting on PATH, checked together so
# a failure names the specific missing entry rather than just "PATH looks wrong".
_assert_assembled_path() {
  local label="$1" path_str="$2"

  _assert_contains "$label" "$path_str" "$HOME/.local/bin"

  if [ -n "${HOMEBREW_PREFIX:-}" ] && [ -d "$HOMEBREW_PREFIX/bin" ]; then
    _assert_contains "$label" "$path_str" "$HOMEBREW_PREFIX/bin"
  fi
  for bun_bin in "$HOME/.bun/bin" "$HOME/.cache/bun/bin"; do
    [ -d "$bun_bin" ] && _assert_contains "$label" "$path_str" "$bun_bin"
  done
  [ -d "$HOME/.cargo/bin" ] && _assert_contains "$label" "$path_str" "$HOME/.cargo/bin"

  # macOS only: /etc/zprofile runs path_helper, which prepends the system dirs
  # and demotes Homebrew. dot-zprofile repairs login shells and
  # config/shell/local-paths.sh repairs the rest, so Homebrew must win everywhere.
  if [ "$(uname -s)" = "Darwin" ] && [ -n "${HOMEBREW_PREFIX:-}" ]; then
    local hb usr
    hb=$(_index_of "$path_str" "$HOMEBREW_PREFIX/bin")
    usr=$(_index_of "$path_str" "/usr/bin")
    if [ "$usr" -ge 0 ]; then
      if [ "$hb" -lt 0 ] || [ "$hb" -ge "$usr" ]; then
        echo "$label: $HOMEBREW_PREFIX/bin (index $hb) must precede /usr/bin (index $usr)"
        echo "PATH=$path_str"
        false
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# zsh
# ---------------------------------------------------------------------------

@test "zsh login interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "zsh -lic" "$(_path_in zsh -lic)"
}

@test "zsh login non-interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "zsh -lc" "$(_path_in zsh -lc)"
}

@test "zsh non-login interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "zsh -ic" "$(_path_in zsh -ic)"
}

@test "zsh non-login non-interactive assembles PATH" {
  _skip_unless_deployed
  # .zshenv is the only file this shape reads. It is the shape `ssh host cmd`
  # and a cron job with SHELL=zsh get, and the one that had zero environment
  # before .zshenv existed.
  _assert_assembled_path "zsh -c" "$(_path_in zsh -c)"
}

# ---------------------------------------------------------------------------
# bash
# ---------------------------------------------------------------------------

@test "bash login interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "bash -lic" "$(_path_in bash -lic)"
}

@test "bash login non-interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "bash -lc" "$(_path_in bash -lc)"
}

@test "bash non-login interactive assembles PATH" {
  _skip_unless_deployed
  _assert_assembled_path "bash -ic" "$(_path_in bash -ic)"
}

@test "bash non-login non-interactive reads no startup file" {
  _skip_unless_deployed
  # Not a gap: bash has no all-invocations file, so this shape inherits whatever
  # its launcher handed it. AGENTS.md requires scripts in this position to source
  # the helper they need. Pinning the contract keeps a future change from
  # quietly making scripts depend on an environment they do not get.
  run _shape bash -c 'printf "%s|%s" "$PATH" "${DOTFILES_SHELL_DIR:-UNSET}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$BARE_PATH|UNSET" ] || {
    echo "expected the inherited bare PATH and no DOTFILES_SHELL_DIR"
    echo "got: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Every shape that reads a startup file must also get the shell config chain
# ---------------------------------------------------------------------------

@test "every startup-file-reading shape exports DOTFILES_SHELL_DIR" {
  _skip_unless_deployed
  local failures=""
  for shape in "zsh -lic" "zsh -lc" "zsh -ic" "zsh -c" \
    "bash -lic" "bash -lc" "bash -ic"; do
    # Deliberate word split: "zsh -lic" becomes $1=zsh $2=-lic.
    # shellcheck disable=SC2086
    set -- $shape
    out=$(_shape "$1" "$2" 'printf "%s" "${DOTFILES_SHELL_DIR:-UNSET}"')
    [ "$out" = "UNSET" ] && failures="$failures [$shape]"
  done
  [ -z "$failures" ] || {
    echo "shapes reached without the shell config chain:$failures"
    false
  }
}

@test "every startup-file-reading shape gets config/shell exports" {
  _skip_unless_deployed
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  # TMUXINATOR_CONFIG stands in for the whole config/shell layer: it is set by a
  # file gated on `command -v`, so it proves PATH was assembled before the
  # sourcing loop ran, not merely by the end of the file.
  local failures=""
  for shape in "zsh -lic" "zsh -lc" "zsh -ic" "zsh -c" \
    "bash -lic" "bash -lc" "bash -ic"; do
    # Deliberate word split: "zsh -lic" becomes $1=zsh $2=-lic.
    # shellcheck disable=SC2086
    set -- $shape
    out=$(_shape "$1" "$2" 'printf "%s" "${TMUXINATOR_CONFIG:-UNSET}"')
    [ "$out" = "UNSET" ] && failures="$failures [$shape]"
  done
  [ -z "$failures" ] || {
    echo "shapes missing config/shell exports:$failures"
    false
  }
}

# ---------------------------------------------------------------------------
# Bare launchers
# ---------------------------------------------------------------------------

@test "cron-shape zsh assembles PATH" {
  _skip_unless_deployed
  # cron runs a non-login, non-interactive shell with a minimal PATH. With zsh
  # as SHELL, .zshenv carries the environment.
  _assert_assembled_path "cron zsh" "$(_path_in zsh -c)"
}

@test "agent Bash tool shape promotes keg-only Ruby via BASH_ENV wiring" {
  _skip_unless_deployed
  [ "$(uname -s)" = "Darwin" ] || skip "macOS-only — keg-only Ruby demotion is Apple-specific"
  bp="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null)}"
  [ -n "$bp" ] && [ -d "$bp/opt/ruby/bin" ] || skip "keg-only Homebrew Ruby not installed"

  # Non-login non-interactive bash reads no startup file, so Claude Code's Bash
  # tool is wired through CLAUDE_ENV_FILE by
  # stow/claude/dot-claude/bash-env-path.sh. That wiring sources local-paths.sh
  # for one specific job: put keg-only Ruby ahead of /usr/bin so `bundle` does
  # not resolve to macOS system Bundler 1.x, below the cooldown floor.
  #
  # It deliberately does not assemble PATH. The Bash tool is expected to inherit
  # a populated PATH from whatever launched Claude Code, and this wiring only
  # repairs an ordering problem inheritance cannot fix. The generator's own
  # behavior is covered by tests/claude-bash-env-path.bats.
  local hook="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/bash-env-path.sh"
  local env_file
  env_file="$(mktemp)"
  CLAUDE_ENV_FILE="$env_file" bash "$hook"

  # Reproduce the demoted order: ruby present but behind /usr/bin.
  run env -i HOME="$HOME" PATH="/usr/bin:/bin:$bp/opt/ruby/bin" \
    bash -c "source '$env_file'; command -v bundle"
  rm -f "$env_file"

  [ "$status" -eq 0 ]
  [[ "$output" == "$bp"/* ]] || {
    echo "bundle resolved to '$output' (expected under $bp)"
    false
  }
}
