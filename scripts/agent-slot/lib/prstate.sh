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
    --json number,state,headRefName,headRefOid,baseRefName,createdAt,title,url,isCrossRepository || return 0
  out=$(contract_json -c 'if type == "array" then . else error("not an array") end' <<<"$out" 2>/dev/null) || return 0
  PR_LISTS[$repo]=$out PR_OK[$repo]=1
}

# Usage: pr_prune_branches <repo> <slot path>; deletes each local branch of the slot whose PRs from origin's own
# branches are all merged or closed, and origin's branch of that name with it. Only branches the slot holds are touched,
# never the rest of origin's. It keeps the slot's base, origin's default branch, the branch checked out, and any branch
# a PR targets, since deleting a PR's base closes that PR. A branch goes only when its tip, and origin's tip of that name
# if origin has one, are each a PR's head or an ancestor of one, so a commit pushed after the PR keeps it on both sides.
# Origin's branch goes first, and a branch whose delete fails on either side is reported, so a later resume retries it.
# Prints `checked <true|false>` first (false with no PR list from GitHub, when it deletes nothing), then one
# `pruned <branch>` or `failed <branch> <reason>` line per branch, tab-separated.
pr_prune_branches() {
  local repo=$1 path=$2 base current default branch tip heads remote out
  pr_load "$repo" "$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  if [[ ${PR_OK[$repo]} != 1 ]]; then
    printf 'checked\tfalse\n'
    return 0
  fi
  printf 'checked\ttrue\n'
  base=$(contract_json -r '.base // ""' <<<"$RECORD")
  current=$(git -C "$path" symbolic-ref -q --short HEAD || true)
  default=$(git -C "$path" symbolic-ref -q --short refs/remotes/origin/HEAD || true)
  default=${default#origin/}
  while read -r branch; do
    [[ -n $branch && $branch != "$base" && $branch != "$current" && $branch != "$default" ]] || continue
    heads=$(contract_json -r --arg b "$branch" 'if any(.[]; .baseRefName == $b) then empty else
      [.[] | select(.headRefName == $b and .isCrossRepository == false)]
      | if length > 0 and all(.[]; .state == "MERGED" or .state == "CLOSED") then .[].headRefOid else empty end end' \
      <<<"${PR_LISTS[$repo]}")
    [[ -n $heads ]] || continue
    tip=$(git -C "$path" rev-parse "refs/heads/$branch")
    _pr_in_heads "$path" "$tip" "$heads" || continue
    remote=
    # ls-remote --exit-code exits 2 when origin has no such branch; any other failure leaves origin's tip unknown.
    if bounded remote prune 15 "${AS_GIT_REMOTE[@]}" \
      git -C "$path" ls-remote --exit-code origin "refs/heads/$branch"; then
      remote=${remote%%[[:space:]]*}
      _pr_in_heads "$path" "$remote" "$heads" || continue
    elif ((BOUNDED_STATUS != 2)); then
      # Origin out of reach: stop here rather than spend the timeout again on every branch left.
      printf 'failed\t%s\torigin could not be reached; log: %s\n' "$branch" "${BOUNDED_LOG:-none}"
      break
    fi
    if [[ -n $remote ]] \
      && ! bounded out prune 30 "${AS_GIT_REMOTE[@]}" git -C "$path" push -q origin --delete "$branch"; then
      printf 'failed\t%s\torigin refused the delete; log: %s\n' "$branch" "${BOUNDED_LOG:-none}"
      continue
    fi
    if ! git -C "$path" branch -q -D "$branch" >/dev/null 2>&1; then
      printf 'failed\t%s\tgit could not delete the branch here, such as one a linked worktree has checked out\n' \
        "$branch"
      continue
    fi
    printf 'pruned\t%s\n' "$branch"
  done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads)
}

# Usage: _pr_in_heads <slot path> <oid> <heads, one per line>; true when the commit is one of the heads, or an ancestor
# of one the slot has.
_pr_in_heads() {
  local head
  while read -r head; do
    [[ $2 != "$head" ]] || return 0
    ! git -C "$1" merge-base --is-ancestor "$2" "$head" 2>/dev/null || return 0
  done <<<"$3"
  return 1
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

# Usage: pr_for_slot <repo> <slot path> <record>; prints the task's PRs as a JSON array of
# {number, state, head, oid, url, title, created_at}.
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
    | map({number, state, head: .headRefName, oid: .headRefOid, url, title, created_at: .createdAt})' \
    <<<"${PR_LISTS[$1]}"
}
