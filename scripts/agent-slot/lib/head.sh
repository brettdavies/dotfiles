# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# A PR's head, checked out in a fresh slot. The head branch comes from the remote that holds it and tracks that remote,
# so check counts what is pushed there: origin when the head is on origin's repo, else a remote named as the prime
# names that repo, else fork. A head whose branch or repository is gone is checked out from the item repo's
# refs/pull/<N>/head under the head's name with no upstream, so check never fetches a remote that is gone; an issue's
# branch that is gone leaves the slot on the base. GitHub URLs are compared as owner/name, whatever form each is written
# in. head_plan picks a reopen's head from the slot's teardown event in the ledger, keeping the branch and remote the
# slot had over GitHub's.

HEAD_REMOTE='' HEAD_URL='' HEAD_PUSHABLE=null

# Usage: head_github_slug <url>; prints the lowercase owner/name of a GitHub URL in its https, ssh, or scp form, with or
# without .git, and nothing for any other URL. GitHub matches its host and names in any case, so this does too.
head_github_slug() {
  local url=${1,,}
  url=${url%/}
  url=${url%.git}
  [[ $url =~ ^(https://|ssh://git@|git@)github\.com[:/]([a-z0-9_.-]+/[a-z0-9_.-]+)$ ]] || return 0
  printf '%s' "${BASH_REMATCH[2]}"
}

# Usage: head_remote_for <prime> <head url>; sets HEAD_REMOTE and HEAD_URL to the remote a slot of the prime fetches
# the head from: origin when the head URL names origin's repo, else the prime's own remote for that repo with the
# prime's URL for it, else fork with the head URL.
head_remote_for() {
  local prime=$1 slug remote
  slug=$(head_github_slug "$2")
  HEAD_REMOTE=fork HEAD_URL=$2
  [[ -n $slug ]] || return 0
  while read -r remote; do
    [[ -n $remote ]] || continue
    if [[ $(head_github_slug "$(git -C "$prime" config --get "remote.$remote.url" || true)") == "$slug" ]]; then
      HEAD_REMOTE=$remote HEAD_URL=$(git -C "$prime" config --get "remote.$remote.url")
      [[ $remote != origin ]] || return 0
    fi
  done < <(git -C "$prime" remote)
  return 0
}

# Usage: head_checkout <slot> <branch> <remote> <url> <kind> <item repo> <number> <retry command>
# Checks out <branch> from <remote> at <url>, adding the remote when the slot lacks it, and sets HEAD_PUSHABLE to true.
# An empty <url> means GitHub reports the head's repository gone. When that is so, or the remote answers without the
# branch, it sets HEAD_PUSHABLE to false and, for a <kind> of pr, checks out refs/pull/<number>/head of <item repo>
# (owner/name) instead; an issue has no such ref, so its slot keeps the base. A fetch that fails any other way fails
# with clone-failed naming the remote, for the caller's rollback.
head_checkout() {
  local slot=$1 branch=$2 remote=$3 url=$4 kind=$5 item_repo=$6 number=$7 retry=$8 from
  if [[ -n $url ]] && _head_fetch_branch "$slot" "$branch" "$remote" "$url" "$retry"; then
    _head_git checkout "$slot" "$retry" "$branch" checkout -q -B "$branch" --track "$remote/$branch"
    HEAD_PUSHABLE=true
    return 0
  fi
  HEAD_PUSHABLE=false
  [[ $kind == pr ]] || return 0
  from=origin
  if [[ $(head_github_slug "$(git -C "$slot" config --get remote.origin.url || true)") != "${item_repo,,}" ]]; then
    from=https://github.com/$item_repo.git
  fi
  _head_git fetch "$slot" "$retry" "$from" fetch -q -- "$from" "refs/pull/$number/head"
  _head_git checkout "$slot" "$retry" "$branch" checkout -q -B "$branch" FETCH_HEAD
}

# Usage: head_plan <teardown event> <item>; sets HEAD_PLAN to the head a reopen of the slot the ledger event tore down
# checks out, {branch, remote, url, oid, source: {branch, remote}}, for an item as item_resolve reads it. The caller
# has run repo_prime. The branch is the event's head when the event kept that branch, else a PR's head branch on
# GitHub, else the base. Its remote and URL are the event's for that branch only when the URL is on origin's host,
# since the slot's own agent wrote them, and are origin when they name origin's repo; else they are a PR's head
# repository on GitHub, under the prime's name for it or fork, with a null remote when that repository is gone, so the
# head comes from refs/pull/<N>/head.
HEAD_PLAN=null
head_plan() {
  local event=$1 item=$2 kind branch from=ledger entry url remote host origin_slug
  kind=$(contract_json -r .kind <<<"$item")
  parity_base "$REPO_PRIME"
  branch=$(contract_json -r '.head as $h | if $h != null and any(.branches[]?; .name == $h) then $h else "" end' \
    <<<"$event")
  if [[ -z $branch && $kind == pr ]]; then
    branch=$(contract_json -r '.head_branch // ""' <<<"$item") from=gh
  fi
  entry=$(contract_json -c --arg b "$branch" '[.branches[]? | select(.name == $b)] | last // {}' <<<"$event")
  url=$(contract_json -r '.url // ""' <<<"$entry")
  remote=$(contract_json -r '.remote // ""' <<<"$entry")
  host=$(_check_url_host "$REPO_ORIGIN")
  if [[ -n $branch && -n $remote && -n $host && $(_check_url_host "$url") == "$host" ]]; then
    origin_slug=$(head_github_slug "$REPO_ORIGIN")
    if [[ -n $origin_slug && $(head_github_slug "$url") == "$origin_slug" ]]; then
      remote=origin url=$REPO_ORIGIN
    fi
    _head_plan_json "$branch" "$remote" "$url" "$entry" "$from" ledger
  elif [[ -n $branch && $kind == pr ]]; then
    url=$(contract_json -r '.head_url // ""' <<<"$item")
    HEAD_REMOTE='' HEAD_URL=''
    [[ -z $url ]] || head_remote_for "$REPO_PRIME" "$url"
    _head_plan_json "$branch" "$HEAD_REMOTE" "$HEAD_URL" "$entry" "$from" gh
  else
    _head_plan_json "$PARITY_BASE" origin "$REPO_ORIGIN" '{}' base base
  fi
}

_head_plan_json() {
  HEAD_PLAN=$(contract_json -n -c --arg branch "$1" --arg remote "$2" --arg url "$3" --argjson entry "$4" \
    --arg from "$5" --arg remote_from "$6" '
    {branch: $branch, remote: (if $remote == "" then null else $remote end),
     url: (if $url == "" then null else $url end), oid: ($entry.oid // null),
     source: {branch: $from, remote: (if $remote == "" then null else $remote_from end)}}')
}

# Returns 1 when the remote answers that it has no such branch.
_head_fetch_branch() {
  local slot=$1 branch=$2 remote=$3 url=$4 retry=$5 out log
  if [[ -z $(git -C "$slot" config --get "remote.$remote.url" || true) ]]; then
    git -C "$slot" remote add -- "$remote" "$url"
  fi
  _head_bounded out fetch 900 "$slot" fetch -q -- "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" \
    && return 0
  log=$BOUNDED_LOG
  _head_bounded out ls-remote 60 "$slot" ls-remote --exit-code -- "$remote" "refs/heads/$branch" || true
  ((BOUNDED_STATUS != 2)) || return 1
  contract_fail clone-failed "fetching $branch from $remote in the new clone failed" --value "$remote" \
    --side-effects none --command "$retry" --log "$log"
}

# Usage: _head_git <label> <slot> <retry command> <value> <git args...>; a bounded git call in the slot that fails with
# clone-failed naming <value>.
_head_git() {
  local label=$1 slot=$2 retry=$3 value=$4 out
  shift 4
  _head_bounded out "$label" 900 "$slot" "$@" && return 0
  contract_fail clone-failed "git $label of $value in the new clone failed" --value "$value" --side-effects none \
    --command "$retry" --log "$BOUNDED_LOG"
}

# A git call in the slot under bounded, with ssh and credential prompts off, as the clone runs.
_head_bounded() {
  local var=$1 label=$2 secs=$3 slot=$4
  shift 4
  bounded "$var" "$label" "$secs" /usr/bin/env GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_TERMINAL_PROMPT=0 \
    git -C "$slot" "$@"
}
