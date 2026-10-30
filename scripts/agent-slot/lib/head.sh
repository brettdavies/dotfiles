# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# A PR's head, checked out in a fresh slot. The head branch comes from the remote that holds it and tracks that remote,
# so check counts what is pushed there: origin when the head is on origin's repo, else a remote named as the prime
# names that repo, else fork. A head whose branch or repository is gone is checked out from the item repo's
# refs/pull/<N>/head under the head's name with no upstream, so check never fetches a remote that is gone. GitHub URLs
# are compared as owner/name, whatever form each is written in.

HEAD_REMOTE='' HEAD_URL='' HEAD_PUSHABLE=null

# Usage: head_github_slug <url>; prints the lowercase owner/name of a GitHub URL in its https, ssh, or scp form, with or
# without .git, and nothing for any other URL.
head_github_slug() {
  local url=${1%/}
  url=${url%.git}
  [[ $url =~ ^(https://|ssh://git@|git@)github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]] || return 0
  printf '%s' "${BASH_REMATCH[2],,}"
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

# Usage: head_checkout <slot> <branch> <remote> <url> <item repo> <number> <retry command>
# Checks out <branch> from <remote> at <url>, adding the remote when the slot lacks it, and sets HEAD_PUSHABLE to true.
# An empty <url> means GitHub reports the head's repository gone. When that is so, or the remote answers without the
# branch, it checks out refs/pull/<number>/head of <item repo> (owner/name) instead and sets HEAD_PUSHABLE to false. A
# fetch that fails any other way fails with clone-failed naming the remote, for the caller's rollback.
head_checkout() {
  local slot=$1 branch=$2 remote=$3 url=$4 item_repo=$5 number=$6 retry=$7 from
  if [[ -n $url ]] && _head_fetch_branch "$slot" "$branch" "$remote" "$url" "$retry"; then
    _head_git checkout "$slot" "$retry" "$branch" checkout -q -B "$branch" --track "$remote/$branch"
    HEAD_PUSHABLE=true
    return 0
  fi
  from=origin
  if [[ $(head_github_slug "$(git -C "$slot" config --get remote.origin.url || true)") != "${item_repo,,}" ]]; then
    from=https://github.com/$item_repo.git
  fi
  _head_git fetch "$slot" "$retry" "$from" fetch -q -- "$from" "refs/pull/$number/head"
  _head_git checkout "$slot" "$retry" "$branch" checkout -q -B "$branch" FETCH_HEAD
  HEAD_PUSHABLE=false
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
