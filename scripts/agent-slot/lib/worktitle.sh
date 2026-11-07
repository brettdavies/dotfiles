# shellcheck shell=bash
# What a Claude session outside a slot is called for the work it is on: the PR's name when the branch has one, else the
# branch's. session-title.sh titles a session with it and statusline.sh shows it for a prime. Both name a PR as a slot
# for it is named (item_name), but the status line has no PR title, so it slugs the branch where the hook slugs the PR's
# title. Callers source contract.sh, launch.sh, and items.sh first; worktitle_is_prime also needs env.sh and read.sh,
# with agent_slot_env run.

# Usage: worktitle_base_branch <branch> [<checkout>]
# True for a branch that names no work: a base or release branch, the branch origin's HEAD names when the checkout is
# given, or a detached head, which reaches here as an empty name.
worktitle_base_branch() {
  local default
  case $1 in
    '' | main | master | dev | develop | release/*) return 0 ;;
  esac
  [[ -n ${2:-} ]] || return 1
  default=$(git -C "$2" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
  [[ $1 == "${default#origin/}" ]]
}

# Usage: worktitle_is_prime <checkout top> <origin url>
# True for a prime checkout: a clone with an origin, directly under the dev root or named in the extra list. This is
# repo_primes' rule applied to one checkout, since listing every prime costs 0.3 s. The status line asks it of a session
# named *-prime.
worktitle_is_prime() {
  local real dev extra
  local IFS=:
  [[ -n $2 ]] && repo_is_clone "$1" || return 1
  real=$(readlink -f "$1") || return 1
  dev=$(readlink -f "$AS_DEV" 2>/dev/null) || dev=''
  [[ -z $dev || ${real%/*} != "$dev" ]] || return 0
  # shellcheck disable=SC2086 # AS_EXTRA_PRIMES is a colon-separated list
  for extra in $AS_EXTRA_PRIMES; do
    [[ -z $extra || $real != "$(readlink -f "$extra" 2>/dev/null)" ]] || return 0
  done
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
