#!/usr/bin/env bats
# 1Password shell plugins in the zshrc, and DATADOG_HOST from config/shell/datadog.sh.
#
# Run: bats tests/shell-op-datadog.bats
#
# Each shell runs under a HOME whose startup files are this checkout's
# (tests/lib/startup-home.bash), so the tests read the files under change, not
# the deployed ones. The installed home behind that HOME is a scratch directory,
# so the plugins.sh a test writes never reaches the real ~/.config/op.
bats_require_minimum_version 1.5.0

load lib/startup-home

REPO="$BATS_TEST_DIRNAME/.."
ZSHRC="$REPO/stow/zsh/dot-zshrc"

# _checkout_home [plugins]: sets CHECKOUT_HOME to a HOME built from this
# checkout. With an argument, its ~/.config/op/plugins.sh defines a dog wrapper,
# here an alias; without one, it has no ~/.config at all.
_checkout_home() {
  local installed="$BATS_TEST_TMPDIR/installed"
  mkdir -p "$installed"
  if [ -d "$HOME/.oh-my-zsh" ]; then
    ln -s "$HOME/.oh-my-zsh" "$installed/.oh-my-zsh"
  fi
  if [ "${1:-}" = plugins ]; then
    mkdir -p "$installed/.config/op"
    printf 'alias dog="op plugin run -- dog"\n' >"$installed/.config/op/plugins.sh"
  fi
  startup_home "$REPO" "$BATS_TEST_TMPDIR/home" "$installed"
  CHECKOUT_HOME="$BATS_TEST_TMPDIR/home"
}

# _in_checkout_home <command...>: runs the command from env -i under
# CHECKOUT_HOME with stdin closed, so nothing it reads comes from the host's
# environment or from a socket on stdin that would make bash read .bashrc.
_in_checkout_home() {
  env -i \
    HOME="$CHECKOUT_HOME" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-$(id -un)}" \
    TERM=xterm-256color \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$@" </dev/null
}

_skip_unless_zsh_with_omz() {
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  [ -d "$HOME/.oh-my-zsh" ] || skip "oh-my-zsh is not installed"
}

@test "sourcing the profile in a fresh bash exports DATADOG_HOST" {
  _checkout_home
  run _in_checkout_home bash -c '. "$HOME/.profile" >/dev/null 2>&1; printf "%s" "${DATADOG_HOST-UNSET}"'
  [ "$status" -eq 0 ]
  [ "$output" = "https://api.us3.datadoghq.com" ]
}

@test "dot-zshrc sources op's plugins.sh behind an existence check, ahead of the Homebrew plugins" {
  local guard_line highlight_line
  guard_line=$(grep -nF '[[ -f "$HOME/.config/op/plugins.sh" ]] && source "$HOME/.config/op/plugins.sh"' "$ZSHRC" | head -1 | cut -d: -f1)
  highlight_line=$(grep -n 'source .*zsh-syntax-highlighting\.zsh' "$ZSHRC" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$highlight_line" ]
  [ "$guard_line" -lt "$highlight_line" ]
}

@test "an interactive zsh defines dog when ~/.config/op/plugins.sh exists" {
  _skip_unless_zsh_with_omz
  _checkout_home plugins
  run --separate-stderr _in_checkout_home "$(command -v zsh)" -ic 'printf "DOG=%s\n" "$(whence -w dog)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOG=dog: alias"* ]] || {
    echo "dog line: $(grep '^DOG=' <<<"$output")"
    echo "stderr: $stderr"
    false
  }
}

@test "an interactive zsh starts cleanly when ~/.config/op/plugins.sh does not exist" {
  _skip_unless_zsh_with_omz
  _checkout_home
  [ ! -e "$CHECKOUT_HOME/.config/op/plugins.sh" ]
  run --separate-stderr _in_checkout_home "$(command -v zsh)" -ic 'printf "DOG=%s\n" "$(whence -w dog)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOG="* ]]
  [[ "$output" != *"dog: alias"* ]]
  [ -z "$stderr" ] || {
    echo "stderr: $stderr"
    false
  }
}
