# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Pull request state for slots: one bounded gh call per repo, shared by every slot of that repo.
#
# A slot's task owns the PRs whose head branch is one of the slot's local branches, or one its HEAD reflog shows it
# switching away from, and that were opened after the slot was made or whose head commit a local head holds beyond
# origin's base, plus every PR number its record already names. The reflog keeps the name of a branch
# `gh pr merge --delete-branch` deleted before any check recorded its PR. An older PR counts only when the slot built
# on its head, as a review round does: an old PR that reused a branch name has a head the slot never had, or one the
# base already holds when it merged with a merge commit.

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

# Usage: _pr_head_held <slot path> <base> <oid>; true when a local head holds the commit and neither origin's base nor
# its default branch does.
_pr_head_held() {
  local path=$1 oid=$3 ref head
  local -a not=()
  git -C "$path" cat-file -e "$oid^{commit}" 2>/dev/null || return 1
  for ref in "refs/remotes/origin/$2" refs/remotes/origin/HEAD; do
    ! git -C "$path" rev-parse -q --verify "$ref" >/dev/null || not+=("$ref")
  done
  ((${#not[@]} > 0)) && [[ -n $(git -C "$path" rev-list -n 1 "$oid" --not "${not[@]}") ]] || return 1
  while read -r head; do
    ! git -C "$path" merge-base --is-ancestor "$oid" "$head" || return 0
  done < <(check_local_heads "$path")
  return 1
}

# Usage: pr_for_slot <repo> <slot path> <record>; prints the task's PRs as a JSON array.
pr_for_slot() {
  local branches oid held=()
  branches=$({
    git -C "$2" for-each-ref --format='%(refname:short)' refs/heads
    git -C "$2" log -g -n 200 --format=%gs HEAD 2>/dev/null | sed -n 's/^checkout: moving from \([^ ]*\) to .*/\1/p' \
      || true
  } | contract_json -R -s -c 'split("\n") | map(select(. != ""))')
  while read -r oid; do
    [[ -z $oid ]] || ! _pr_head_held "$2" "$(contract_json -r '.base // "main"' <<<"$3")" "$oid" || held+=("$oid")
  done < <(contract_json -r --argjson branches "$branches" --argjson record "$3" '
    ($record.created_at // "") as $since | ($record.prs // []) as $known
    | .[] | select((.number as $n | $known | index($n) == null) and .createdAt < $since
        and (.headRefName as $h | $branches | index($h) != null)) | .headRefOid' <<<"${PR_LISTS[$1]}")
  contract_json -c --argjson branches "$branches" --argjson record "$3" \
    --argjson held "$(printf '%s\n' "${held[@]}" | contract_json -R -s -c 'split("\n") | map(select(. != ""))')" '
    ($record.created_at // "") as $since | ($record.prs // []) as $known | ($record.base // "") as $base
    | [.[] | select((.number as $n | $known | index($n) != null)
        or ((.headRefName as $h | $branches | index($h) != null) and .headRefName != $base
            and (.createdAt >= $since or (.headRefOid as $o | $held | index($o) != null))))]
    | map({number, state, head: .headRefName, oid: .headRefOid, url})' <<<"${PR_LISTS[$1]}"
}
