#!/usr/bin/env bash
# UserPromptSubmit Claude hook: gives a generic session a title from its branch or PR, through hookSpecificOutput's
# sessionTitle. Generic means a session that is neither a slot's nor a prime's, with no custom title yet, in a git
# checkout on a feature branch. The title is <repo>-pr<N>-<slug> when the branch has an open PR, the same name a slot for
# that PR gets (items.sh), else <repo>-branch-<slug>. A session that already has a custom title, from -n, /rename, or
# this hook's first answer, is left alone, so nothing here replaces a /rename. A slot is found by its directory, a
# prime by repo_primes' rule applied to the checkout's top, since scanning every prime would add 0.3 s to each prompt.
# Prints one JSON object or nothing, and always exits 0; failures go to the agent-slot hooks.log.
#
# The checks run cheapest first, and the first two end nearly every prompt before any library loads: the payload's
# session_title, then the branch. A PR lookup is one gh call bounded to 3 s, made once per session, since the title it
# yields ends the hook's work on every later prompt.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")
PR_LOOKUP_SECS=3

# Usage: title_is_prime <checkout top> <origin url>
title_is_prime() {
  local real extra
  local IFS=:
  [[ -n $2 ]] && repo_is_clone "$1" || return 1
  real=$(realpath -m "$1")
  [[ ${real%/*} != "$(realpath -m "$AS_DEV")" ]] || return 0
  # shellcheck disable=SC2086 # AS_EXTRA_PRIMES is a colon-separated list
  for extra in $AS_EXTRA_PRIMES; do
    [[ -z $extra || $real != "$(realpath -m "$extra")" ]] || return 0
  done
  return 1
}

# Usage: title_pr <owner/name> <branch>; prints the number and title of the branch's open PR, tab-separated, or nothing.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
title_pr() {
  local out
  [[ -n $AS_GH ]] || return 0
  if ! bounded out gh "$PR_LOOKUP_SECS" "$AS_GH" pr list --repo "$1" --head "$2" --state open \
    --json number,title --limit 1; then
    _hook_absorb
    return 0
  fi
  contract_json -r '.[0] // empty | [.number, (.title | gsub("[\t\n]"; " "))] | @tsv' <<<"$out" 2>/dev/null || true
}

# Usage: title_run <cwd> <checkout top> <branch>
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
title_run() {
  local lib origin repo number title name
  for lib in hook items launch prstate; do
    # shellcheck source=/dev/null
    source "$AS_HOME/lib/$lib.sh" || return 0
  done
  hook_init session-title "$AS_HOME" || return 0
  ! slot_at "$1" >/dev/null || return 0
  origin=$(git -C "$2" config --get remote.origin.url 2>/dev/null || true)
  ! title_is_prime "$2" "$origin" || return 0
  repo=${2##*/}
  number='' title=''
  if [[ -n $origin ]]; then
    repo=$(pr_repo_slug "$origin")
    IFS=$'\t' read -r number title < <(title_pr "$repo" "$3") || true
  fi
  name=$(worktitle_name "$repo" "$3" "$number" "$title")
  [[ -n $name ]] || return 0
  contract_json -n -c --arg title "$name" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $title}}'
}

main() {
  local payload json cwd custom branch top
  payload=$(cat)
  json=$(command -v jaq || command -v jq) || return 0
  IFS=$'\037' read -r custom cwd < <("$json" -r '[(.session_title // ""), (.cwd // "")] | join("\u001f")' \
    <<<"$payload" 2>/dev/null) || true
  [[ -z $custom ]] || return 0
  [[ -d $cwd ]] || return 0
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/worktitle.sh" || return 0
  branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  ! worktitle_base_branch "$branch" || return 0
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
  title_run "$cwd" "$top" "$branch"
}

main 2>/dev/null || true
exit 0
