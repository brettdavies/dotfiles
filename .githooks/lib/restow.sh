#!/usr/bin/env bash
# Restow on pull: relink each stow package that a merge or checkout changed, so
# a hook script the new settings.json names is linked before git returns rather
# than whenever someone next runs scripts/stow-deploy.
#
# Usage, from .githooks/post-merge and .githooks/post-checkout:
#   restow.sh <old-rev> <new-rev>
#
# A package restows only from the checkout its links in the deploy target
# already resolve into. Agent slots and scratch clones run these same hooks, and
# a restow from one would re-point the live links into a tree that is about to
# be deleted; a package the host never deployed stays undeployed.
#
# The hooks run this as its own process because bash ignores errexit and the
# ERR trap inside anything called from an `||` list. Every failure is reported
# and the script still exits 0: post-checkout's status becomes the status of
# git checkout and git clone, and the update cannot be undone.

set -eEuo pipefail

RESTOW_PACKAGES=(claude secrets)

# shellcheck source=.githooks/lib/git-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-env.sh"

# Git starts every hook at the worktree root.
repo=$PWD
target=${STOW_DEPLOY_TARGET:-$HOME}

# rerun_command <package>: the command that redoes one package's restow by hand.
rerun_command() {
  local env=""
  [ "$target" = "$HOME" ] || env="STOW_DEPLOY_TARGET=$(printf '%q' "$target") "
  printf 'cd %q && %sscripts/stow-deploy --headless --only %s' "$repo" "$env" "$1"
}

# internal_error <line> <command>
internal_error() {
  trap - ERR
  printf 'WARNING: restow-internal-error: %s line %s: %s failed. The update itself completed, but a hook script the new settings.json names may not be linked yet, so Claude Code tool calls can be blocked until a restow succeeds.\n' \
    "${BASH_SOURCE[0]}" "$1" "$2" >&2
  printf '  Run: %s\n' "$(rerun_command claude)" >&2
  exit 0
}
trap 'internal_error "$LINENO" "$BASH_COMMAND"' ERR

# owned <package>: a tracked file of the package is linked in the target to
# this checkout's copy. --dotfiles turns every dot- path component into a dot.
owned() {
  local pkg=$1 files file rel
  files=$(git -c core.quotePath=false ls-files -- "stow/$pkg") \
    || internal_error "$LINENO" "git ls-files -- stow/$pkg"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel=/${file#stow/"$pkg"/}
    rel=${rel//\/dot-//.}
    if [ "$target$rel" -ef "$repo/$file" ]; then
      return 0
    fi
  done <<<"$files"
  return 1
}

old=$1
new=$2
for pkg in "${RESTOW_PACKAGES[@]}"; do
  rc=0
  git diff-tree -r --quiet "$old" "$new" -- "stow/$pkg" || rc=$?
  case $rc in
    0) continue ;;
    1) ;;
    *) internal_error "$LINENO" "git diff-tree $old $new -- stow/$pkg" ;;
  esac
  owned "$pkg" || continue

  rc=0
  out=$(git_env_isolated "$repo/scripts/stow-deploy" --headless --only "$pkg" </dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "restow: $pkg relinked (stow/$pkg changed)"
    continue
  fi
  printf 'WARNING: restow-failed: scripts/stow-deploy exit %s relinking %s. The update itself completed, but a hook script the new settings.json names may not be linked yet, so Claude Code tool calls can be blocked until this succeeds:\n' \
    "$rc" "$pkg" >&2
  # shellcheck disable=SC2001
  sed 's/^/    /' <<<"$out" >&2
  printf '  Run: %s\n' "$(rerun_command "$pkg")" >&2
done
exit 0
