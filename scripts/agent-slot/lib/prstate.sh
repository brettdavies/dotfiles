# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Pull request state for slots: one bounded gh call per repo, shared by every slot of that repo.
#
# A slot's task owns the PRs whose head branch is one of the slot's local branches, or one its HEAD reflog shows it
# switching away from, and that were opened after the slot was made, plus every PR number its record already names.
# The reflog keeps the name of a branch `gh pr merge --delete-branch` deleted before any check recorded its PR. The age
# check keeps an old PR that reused a branch name from passing for this task's.

declare -gA PR_LISTS=() PR_OK=()

# Usage: pr_repo_slug <origin url>; prints owner/name for a GitHub remote, else the remote's last two path parts.
pr_repo_slug() {
  local url=${1%.git}
  url=${url#*github.com[:/]}
  url=${url%/}
  printf '%s/%s' "$(basename "$(dirname "$url")")" "$(basename "$url")"
}

# Usage: pr_load <repo> <origin url>; reads the repo's PRs once into PR_LISTS[repo], setting PR_OK[repo] to 1 or 0.
pr_load() {
  local repo=$1 out
  [[ -z ${PR_OK[$repo]:-} ]] || return 0
  PR_OK[$repo]=0 PR_LISTS[$repo]='[]'
  [[ -n $AS_GH ]] || return 0
  bounded out gh 30 "$AS_GH" pr list --repo "$(pr_repo_slug "$2")" --state all --limit 200 \
    --json number,state,headRefName,headRefOid,createdAt,url || return 0
  out=$(contract_json -c 'if type == "array" then . else error("not an array") end' <<<"$out" 2>/dev/null) || return 0
  PR_LISTS[$repo]=$out PR_OK[$repo]=1
}

# Usage: pr_for_slot <repo> <slot path> <record>; prints the task's PRs as a JSON array.
pr_for_slot() {
  local branches
  branches=$({
    git -C "$2" for-each-ref --format='%(refname:short)' refs/heads
    git -C "$2" log -g -n 200 --format=%gs HEAD 2>/dev/null | sed -n 's/^checkout: moving from \([^ ]*\) to .*/\1/p' \
      || true
  } | contract_json -R -s -c 'split("\n") | map(select(. != ""))')
  contract_json -c --argjson branches "$branches" --argjson record "$3" '
    ($record.created_at // "") as $since | ($record.prs // []) as $known | ($record.base // "") as $base
    | [.[] | select((.number as $n | $known | index($n) != null)
        or ((.headRefName as $h | $branches | index($h) != null) and .headRefName != $base
            and .createdAt >= $since))]
    | map({number, state, head: .headRefName, oid: .headRefOid, url})' <<<"${PR_LISTS[$1]}"
}
