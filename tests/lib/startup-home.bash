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
# same name without a second list to keep. A file the checkout no longer holds
# is absent from <dest> too: the installed home links such a file into the same
# stow package, and a shell started here must not read it.
#
# Three things in <home> are not linked through:
# - `dotfiles`: config/shell/gogcli.sh runs `stow --adopt` on
#   $HOME/dotfiles/stow, and a shell started here must not write into a checkout
#   or through a linked directory into the installed home.
# - `.zsh`: oh-my-zsh keys its completion dump to the directories it was built
#   from, so a dump shared with the installed home is deleted and rebuilt by every
#   shell started here, and the installed home is left with one for paths that
#   exist only in <dest>. <dest> gets its own `.zsh/cache`.
# - a startup file still encrypted by git-crypt, which a shell can only fail on:
#   the installed one is linked in its place.
startup_home() {
  local root=$1 dest=$2 home=${3:-$HOME} entry file name dname target pattern restore
  local -a owned=()
  # shellcheck source=/dev/null
  . "$root/.githooks/lib/push-scope.sh"
  mkdir -p "$dest/.zsh/cache"

  for entry in "${SHELL_STARTUP_PATHS[@]}"; do
    case $entry in
      stow/*/)
        set -- "$root/$entry"dot-*
        owned+=("*/${entry}dot-*")
        ;;
      stow/*)
        set -- "$root/$entry"
        owned+=("*/$entry")
        ;;
      *) continue ;;
    esac
    for file in "$@"; do
      [ -f "$file" ] || continue
      name=${file##*/}
      dname=.${name#dot-}
      if [ "$(head -c 10 "$file" | tr -d '\0')" = GITCRYPT ]; then
        if [ -e "$home/$dname" ] || [ -L "$home/$dname" ]; then
          ln -s "$home/$dname" "$dest/$dname"
        fi
        continue
      fi
      ln -s "$file" "$dest/$dname"
    done
  done

  restore=$(shopt -p dotglob nullglob || true)
  shopt -s dotglob nullglob
  for file in "$home"/*; do
    name=${file##*/}
    [ "$name" != dotfiles ] || continue
    [ -e "$dest/$name" ] || [ -L "$dest/$name" ] || {
      if [ -L "$file" ]; then
        target=$(readlink "$file")
        for pattern in "${owned[@]}"; do
          # shellcheck disable=SC2254 # the pattern is a glob on purpose
          case $target in $pattern) continue 2 ;; esac
        done
      fi
      ln -s "$file" "$dest/$name"
    }
  done
  eval "$restore"
}
