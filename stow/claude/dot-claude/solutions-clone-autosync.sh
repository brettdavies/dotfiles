#!/usr/bin/env bash
# Claude Code SessionStart hook: fast-forward the shared solutions clone and
# report what it holds that origin lacks.
#
# ~/dev/solutions-docs (docs/solutions/ in every repo's own checkout; each agent
# slot links to a worktree of its own) is one clone that parallel compounding
# agents share. The write path is sd-commit-doc, which publishes from a
# detached worktree and fast-forwards the shared checkout so it never drifts. When an agent hand-rolls the git flow and skips that
# fast-forward, already-pushed files resurface in the clone as phantom "modified"
# entries and the branch strands behind origin until a human notices. This hook
# is the read-path safety net: at session start it advances the clone to origin.
#
# Guard shape per
# docs/solutions/workflow-issues/unattended-autocommit-on-shared-clone-must-sync-then-rebase.md:
# `git fetch` then `git merge --ff-only`. A merely-behind clone fast-forwards;
# a genuinely-diverged one is surfaced-and-skipped (merge --ff-only aborts
# rather than merging or forcing). It NEVER commits, git-adds, stashes, resets,
# or forces — a hard reset would destroy a concurrent writer's in-flight work.
# A plain fast-forward carries in-flight edits to paths origin did not change,
# and refuses, writing nothing, when origin changed a path holding one; with
# --autostash that re-apply would write conflict markers into the draft and
# leave it in the shared stash. Phantom copies of already-pushed files are
# reverted, then the fast-forward retried.
#
# Every other dirty path is a stray: prime checkouts draft in this clone and
# publish by sd-commit-doc's copy-out, so a stray can be a draft still in
# progress, and the hook only reports it, never commits, stages, or deletes it.
# Output is one SessionStart JSON object: additionalContext carries the
# fast-forward lines and the strays to Claude, and in a session outside the
# agent-slot root a systemMessage names the strays to the person, since plain
# stdout reaches only Claude.
#
# Fail-open + near-zero latency: print nothing when the repo is absent, when
# there is nothing to say, or when neither jaq nor jq is installed; an offline
# fetch still reports strays. The network is never a correctness dependency.
# The one non-zero exit is a phantom revert that git refuses, which Claude Code
# shows as a non-blocking hook error rather than dropping it with the stderr of
# an exit 0.

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
JQ=$(command -v jaq || command -v jq) || JQ=
notes=()
max_named=10

in_slot() {
  local payload="" dir="" root
  if [ ! -t 0 ]; then
    IFS= read -r -d '' -t 2 payload || true
  fi
  [ -z "$payload" ] || dir=$("$JQ" -r '.cwd // empty' <<<"$payload" 2>/dev/null) || dir=""
  dir=$(readlink -f -- "${dir:-$PWD}" 2>/dev/null) || return 1
  root=$(readlink -f -- "${AGENT_SLOT_ROOT:-$HOME/slots}" 2>/dev/null) || return 1
  [[ $dir == "$root"/* ]]
}

report() {
  local entry named n noun them any held msg=""
  local -a strays=()
  while IFS= read -r -d '' entry; do
    strays+=("${entry:3}")
  done < <(git -C "$SD" status --porcelain=v1 -z --untracked-files=all --no-renames 2>/dev/null)
  [ -n "$JQ" ] && ((${#notes[@]} + ${#strays[@]} > 0)) || exit 0

  n=${#strays[@]}
  if ((n > 0)); then
    named=$(printf '%s, ' "${strays[@]:0:max_named}")
    named=${named%, }
    ((n <= max_named)) || named+=", and $((n - max_named)) more"
    noun=changes them=them any="Any of them"
    ((n > 1)) || noun=change them=it any=It
    held="$SD holds $n $noun origin/$branch lacks: $named."
    if in_slot; then
      notes+=("solutions-clone-autosync: $held Each one sits in the shared clone, not this slot's worktree, and is not this agent's to change.")
    else
      msg="solutions-clone-autosync: $held $any can be a prime session's draft, waiting there for its sd-commit-doc copy-out. Automation never commits or deletes $them; anything else is for a person to publish or discard."
      notes+=("$msg This session leaves alone every change it did not write.")
    fi
  fi

  # shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
  "$JQ" -n -c --arg msg "$msg" --arg ctx "$(printf '%s\n' "${notes[@]}")" \
    '(if $msg == "" then {} else {systemMessage: $msg} end)
      + {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>/dev/null
  exit 0
}

ff() {
  git -C "$SD" merge --ff-only --quiet "origin/$branch" >/dev/null 2>&1
}

# A hung fetch would run past the hook's 15 s budget and take the stray report
# with it.
fetch() {
  local bound=()
  ! command -v timeout >/dev/null 2>&1 || bound=(timeout 10)
  GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' GIT_TERMINAL_PROMPT=0 \
    "${bound[@]}" git -C "$SD" fetch --quiet origin "$branch" 2>/dev/null
}

fetch || report
local_ref=$(git -C "$SD" rev-parse --quiet --verify "$branch" 2>/dev/null) || report
remote_ref=$(git -C "$SD" rev-parse --quiet --verify "origin/$branch" 2>/dev/null) || report
[ "$local_ref" = "$remote_ref" ] && report

# --ff-only refuses (aborts, never force-resets) a genuinely-diverged branch.
if ff; then
  notes+=("solutions-clone-autosync: fast-forwarded $SD to origin/$branch")
  report
fi

# A writer whose own fast-forward never ran leaves phantom copies of files it
# already pushed, as worktree edits or untracked files, and an untracked one
# blocks the ff. A dirty path is a phantom only when its content matches
# origin's, so discarding it loses nothing; any other dirty path is in-flight
# work, which the ff carries or which blocks it. Tracked phantoms go to
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
# Claude Code's hook-error notice carries only the first stderr line, so this
# script's own line goes ahead of git's.
revert() {
  local err
  err=$(git -C "$SD" "$@" 2>&1) && return 0
  printf 'solutions-clone-autosync: could not revert the phantom copies in %s; it stays behind origin/%s\n%s\n' \
    "$SD" "$branch" "$err" >&2
  exit 1
}
mapfile -d '' -t tracked < <(phantoms --modified)
mapfile -d '' -t untracked < <(phantoms --others --exclude-standard)
if ((${#tracked[@]} + ${#untracked[@]} > 0)); then
  ((${#tracked[@]} == 0)) || revert checkout -q -- "${tracked[@]}"
  ((${#untracked[@]} == 0)) || revert clean -fq -- "${untracked[@]}"
  if ff; then
    notes+=("solutions-clone-autosync: fast-forwarded $SD to origin/$branch (reconciled phantom copies)")
    report
  fi
fi

notes+=("solutions-clone-autosync: $SD not fast-forwarded to origin/$branch: it diverged, or origin changed a path that holds a local change; left untouched (needs manual reconcile)")
report
