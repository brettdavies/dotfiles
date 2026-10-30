#!/usr/bin/env bash
# Claude Code SessionStart hook: fast-forward the shared solutions clone.
#
# ~/dev/solutions-docs (symlinked as docs/solutions/ in every repo) is one clone
# that parallel compounding agents share. The write path is sd-commit-doc, which
# commits from a detached worktree and fast-forwards the shared checkout so it
# never drifts. When an agent hand-rolls the git flow and skips that
# fast-forward, already-pushed files resurface in the clone as phantom "modified"
# entries and the branch strands behind origin until a human notices. This hook
# is the read-path safety net: at session start it advances the clone to origin.
#
# Guard shape per
# docs/solutions/workflow-issues/unattended-autocommit-on-shared-clone-must-sync-then-rebase.md:
# `git fetch` then `git merge --ff-only --autostash`. A merely-behind clone
# fast-forwards; a genuinely-diverged one is surfaced-and-skipped (merge --ff-only
# aborts rather than merging or forcing). It NEVER commits, git-adds, resets, or
# forces — a hard reset would destroy a concurrent writer's in-flight work.
# --autostash carries in-flight tracked edits across the fast-forward; phantom
# copies of already-pushed files are reverted, then the fast-forward retried.
#
# Fail-open + near-zero latency: skip silently when the repo is absent, offline,
# or busy. The network is never a correctness dependency. The one non-zero exit
# is a phantom revert that git refuses, which Claude Code shows as a
# non-blocking hook error rather than dropping it with the stderr of an exit 0.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

set -uo pipefail

SD=${SD_DIR:-$HOME/dev/solutions-docs}
[ -d "$SD/.git" ] || exit 0

branch=main

# Already current? Skip without touching the network (the common path).
git -C "$SD" fetch --quiet origin "$branch" 2>/dev/null || exit 0
local_ref=$(git -C "$SD" rev-parse --quiet --verify "$branch" 2>/dev/null) || exit 0
remote_ref=$(git -C "$SD" rev-parse --quiet --verify "origin/$branch" 2>/dev/null) || exit 0
[ "$local_ref" = "$remote_ref" ] && exit 0

# Behind-and-clean fast-forwards; --autostash preserves in-flight tracked edits.
# --ff-only refuses (aborts, never force-resets) a genuinely-diverged branch.
if git -C "$SD" merge --ff-only --autostash --quiet "origin/$branch" 2>/dev/null; then
  echo "solutions-clone-autosync: fast-forwarded $SD to origin/$branch"
  exit 0
fi

# A writer whose own fast-forward never ran leaves phantom copies of files it
# already pushed, as worktree edits or untracked files, and an untracked one
# blocks the ff. A dirty path is a phantom only when its content matches
# origin's, so discarding it loses nothing; any other dirty path is in-flight
# work, left for --autostash to carry or to block the ff. Tracked phantoms go to
# checkout and untracked ones to clean, because `git checkout -- <paths>`
# refuses every path when any one is unknown to the index.
matches_origin() {
  local want
  if want=$(git -C "$SD" rev-parse --quiet --verify "origin/$branch:$1"); then
    [ -f "$SD/$1" ] && [ "$(git -C "$SD" hash-object -- "$1")" = "$want" ]
  else
    [ ! -e "$SD/$1" ]
  fi
}
phantoms() {
  local f
  while IFS= read -r -d '' f; do
    matches_origin "$f" && printf '%s\0' "$f"
  done < <(git -C "$SD" ls-files -z "$@")
}
revert_failed() {
  echo "solutions-clone-autosync: could not revert the phantom copies in $SD; it stays behind origin/$branch" >&2
  exit 1
}
mapfile -d '' -t tracked < <(phantoms --modified)
mapfile -d '' -t untracked < <(phantoms --others --exclude-standard)
if ((${#tracked[@]} + ${#untracked[@]} > 0)); then
  ((${#tracked[@]} == 0)) || git -C "$SD" checkout -q -- "${tracked[@]}" || revert_failed
  ((${#untracked[@]} == 0)) || git -C "$SD" clean -fq -- "${untracked[@]}" || revert_failed
  if git -C "$SD" merge --ff-only --autostash --quiet "origin/$branch" 2>/dev/null; then
    echo "solutions-clone-autosync: fast-forwarded $SD to origin/$branch (reconciled phantom copies)"
    exit 0
  fi
fi

echo "solutions-clone-autosync: $SD diverged from origin/$branch; left untouched (needs manual reconcile)" >&2
exit 0
