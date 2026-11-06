# shellcheck shell=bash
# What a Claude session outside a slot is called for the work it is on: the PR's name when the branch has one, else the
# branch's. session-title.sh titles a generic session with it and statusline.sh shows it for a prime, so the two agree
# with the name a slot for the same PR gets (item_name). Callers source contract.sh, launch.sh, and items.sh first.

# Usage: worktitle_base_branch <branch>; true for a branch that names no work: a base or release branch, or a detached
# head, which reaches here as an empty name.
worktitle_base_branch() {
  case $1 in
    '' | main | master | dev | develop | release/*) return 0 ;;
  esac
  return 1
}

# Usage: worktitle_name <owner/name> <branch> [<PR number> <PR title>]
# Prints <repo>-pr<N>-<slug of the title> for a PR, else <repo>-branch-<slug of the branch>, cut as a slot's name is.
# shellcheck disable=SC2016 # jaq programs; their $names are bound with --arg
worktitle_name() {
  local item
  if [[ -n ${3:-} ]]; then
    item=$(contract_json -n -c --arg repo "$1" --argjson number "$3" --arg title "${4:-}" \
      '{kind: "pr", repo: $repo, number: $number, title: $title}') || return 0
  else
    item=$(contract_json -n -c --arg repo "$1" --arg branch "$2" \
      '{kind: "branch", repo: $repo, number: "", title: $branch}') || return 0
  fi
  item_name "$item"
}
