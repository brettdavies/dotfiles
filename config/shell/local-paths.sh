# shellcheck shell=bash
# Local tool paths — adds directories to PATH/LD_LIBRARY_PATH if they exist
# This covers tools installed outside of Homebrew (CUDA, npm, Bun, etc.)
#
# All prepends are dedupe-guarded so re-sourcing (e.g., from .zshrc after
# .zshenv) doesn't multiply entries. A directory whose binaries must shadow
# Homebrew's or the system's goes through _lp_to_front, which moves it to the
# front even when PATH already holds it: an add-if-absent guard leaves a present
# entry wherever the inherited PATH had it, which can be behind Homebrew or
# /usr/bin.
#
# The agent Bash tool sources this file before every command, after its shell
# snapshot restores the PATH captured when the session started
# (stow/claude/dot-claude/bash-env-path.sh), so the moves below also repair a
# snapshot taken in a shell whose order was wrong.

# Moves $1 to the front of PATH, dropping every copy already on it. PATH is
# walked by parameter expansion rather than an IFS=: word split, which zsh does
# not perform on an unquoted $PATH. POSIX, no awk/sed.
_lp_to_front() {
  _lp_new=
  _lp_rest="${PATH-}:"
  while [ -n "$_lp_rest" ]; do
    _lp_dir=${_lp_rest%%:*}
    _lp_rest=${_lp_rest#*:}
    [ "$_lp_dir" = "$1" ] || _lp_new="${_lp_new:+$_lp_new:}$_lp_dir"
  done
  export PATH="$1${_lp_new:+:$_lp_new}"
  unset _lp_new _lp_rest _lp_dir
}

# CUDA toolkit
if [ -d /usr/local/cuda/bin ]; then
  case ":${PATH}:" in
    *:/usr/local/cuda/bin:*) ;;
    *) export PATH="/usr/local/cuda/bin:$PATH" ;;
  esac
  if [ -d /usr/local/cuda/lib64 ]; then
    case ":${LD_LIBRARY_PATH:-}:" in
      *:/usr/local/cuda/lib64:*) ;;
      *) export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}" ;;
    esac
  fi
fi

# npm global packages (Linux convention). Its npm and npx shadow the copies
# Homebrew's node formula installs.
if [ -d "$HOME/.npm-global/bin" ]; then
  _lp_to_front "$HOME/.npm-global/bin"
fi

# Bun
if [ -d "$HOME/.bun/bin" ]; then
  case ":${PATH}:" in
    *:"$HOME/.bun/bin":*) ;;
    *) export PATH="$HOME/.bun/bin:$PATH" ;;
  esac
fi

# Homebrew Ruby (keg-only). Puts a modern Ruby/Bundler ahead of the macOS
# system Ruby 2.6 (whose Bundler 1.x predates the supply-chain cooldown
# policy). Ruby's own bin carries the `bundle` binstub, which RubyGems resolves
# to the newest installed Bundler (>= 4.0.13 after `gem install bundler`), so a
# gem-binstub glob is unnecessary - and a bare `*/bin` glob aborts shell startup
# under zsh when it matches nothing. Guarded by -d, so a host without keg-only
# Homebrew Ruby is untouched.
#
# macOS /etc/profile path_helper (and earlier PATH steps) can leave /usr/bin
# ahead of an already-present ruby/bin, so it is moved rather than skipped.
# zsh re-asserts the order in stow/zsh/dot-zprofile after path_helper; this is
# the cross-shell equivalent for every .profile-sourcing context.
for _brew_prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
  [ -d "$_brew_prefix/opt/ruby/bin" ] || continue
  _lp_to_front "$_brew_prefix/opt/ruby/bin"
  break
done
unset _brew_prefix

# ~/.local/bin holds wrappers that shadow Homebrew binaries of the same name
# (gh carries the merge guard), so it goes in front of everything. .profile
# places it too; this copy is the one the agent Bash tool reaches.
_lp_to_front "$HOME/.local/bin"

unset -f _lp_to_front
