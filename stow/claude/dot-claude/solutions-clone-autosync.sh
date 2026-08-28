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
# --autostash carries in-flight tracked edits across the fast-forward; already-
# pushed phantom copies of the committed files are reverted the same bounded way
# sd-commit-doc does, then the fast-forward retried.
#
# Fail-open + near-zero latency: skip silently when the repo is absent, offline,
# or busy. The network is never a correctness dependency.
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

# The ff can be blocked by phantom copies of already-pushed files sitting in the
# clone as worktree-modified/untracked. Revert only the paths that differ from
# origin, then retry the ff — the same bounded reconcile sd-commit-doc performs,
# never a wholesale reset. Still surface-and-skip if it genuinely diverged.
mapfile -t phantom < <(git -C "$SD" diff --name-only "origin/$branch" 2>/dev/null)
if [ "${#phantom[@]}" -gt 0 ]; then
  git -C "$SD" checkout -q -- "${phantom[@]}" 2>/dev/null || true
  git -C "$SD" clean -fq -- "${phantom[@]}" >/dev/null 2>&1 || true
  if git -C "$SD" merge --ff-only --autostash --quiet "origin/$branch" 2>/dev/null; then
    echo "solutions-clone-autosync: fast-forwarded $SD to origin/$branch (reconciled phantom copies)"
    exit 0
  fi
fi

echo "solutions-clone-autosync: $SD diverged from origin/$branch; left untouched (needs manual reconcile)" >&2
exit 0
