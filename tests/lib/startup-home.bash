# shellcheck shell=bash
# A HOME whose startup files are a checkout's, for timing or tracing the shells
# that read them. Both zsh and bash find their startup files through $HOME, and
# dot-profile finds config/shell by following the link its $HOME/.profile is, so
# a shell started with this HOME runs the checkout's startup chain from end to
# end. Everything else in the installed home is linked in, so oh-my-zsh, the
# plugins, and the caches those shells use are the ones a real shell finds.

# startup_home <checkout> <dest> [<home>]: build <dest>, an absent or empty
# directory, from <checkout> and <home> (default: the caller's $HOME).
#
# Each file the checkout holds on SHELL_STARTUP_PATHS under stow/ becomes
# <dest>/.<name> (stow/zsh/dot-zshrc is <dest>/.zshrc). The list names the
# directories, so a startup file added to one replaces the installed file of the
# same name without a second list to keep.
#
# <home>'s own `dotfiles` is left out: config/shell/gogcli.sh runs
# `stow --adopt` on $HOME/dotfiles/stow, and a shell started here must not write
# into a checkout or through a linked directory into the installed home.
startup_home() {
  local root=$1 dest=$2 home=${3:-$HOME} entry file name restore
  # shellcheck source=/dev/null
  . "$root/.githooks/lib/push-scope.sh"
  mkdir -p "$dest"

  for entry in "${SHELL_STARTUP_PATHS[@]}"; do
    case $entry in
      stow/*/) set -- "$root/$entry"dot-* ;;
      stow/*) set -- "$root/$entry" ;;
      *) continue ;;
    esac
    for file in "$@"; do
      [ -e "$file" ] || continue
      # git-crypt leaves a file it has not unlocked as a binary blob, which a
      # shell can only fail on: that startup file stays the installed one.
      if [ -f "$file" ] && [ "$(head -c 10 "$file" | tr -d '\0')" = GITCRYPT ]; then
        continue
      fi
      name=${file##*/}
      ln -s "$file" "$dest/.${name#dot-}"
    done
  done

  restore=$(shopt -p dotglob nullglob || true)
  shopt -s dotglob nullglob
  for file in "$home"/*; do
    name=${file##*/}
    [ "$name" != dotfiles ] || continue
    [ -e "$dest/$name" ] || [ -L "$dest/$name" ] || ln -s "$file" "$dest/$name"
  done
  eval "$restore"
}
