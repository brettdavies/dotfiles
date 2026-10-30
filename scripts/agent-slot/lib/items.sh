# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Work items: the GitHub PR or issue a slot works on. A ref names one as N, owner/name#N, or its GitHub URL, a bare N
# being in origin's repo; item_resolve reads it from GitHub, and item_name alone derives a slot's name from it.

ITEM_NUMBER_PATTERN='[1-9][0-9]{0,9}'
ITEM_REPO_PATTERN='[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'
ITEM_SHORT_PATTERN="^($ITEM_REPO_PATTERN)#($ITEM_NUMBER_PATTERN)\$"
ITEM_URL_PATTERN="^https://github\.com/($ITEM_REPO_PATTERN)/(pull|issues)/($ITEM_NUMBER_PATTERN)([/?#].*)?\$"

# Usage: item_parse_ref <pr | issue> <ref> <origin url>; sets ITEM_KIND, ITEM_REPO (owner/name), ITEM_NUMBER, and
# ITEM_REF, the ref as given, or fails with usage.
ITEM_KIND='' ITEM_REPO='' ITEM_NUMBER='' ITEM_REF=''
item_parse_ref() {
  ITEM_KIND=$1 ITEM_REF=$2
  if [[ $2 =~ ^($ITEM_NUMBER_PATTERN)$ ]]; then
    ITEM_NUMBER=$2
    ITEM_REPO=$(pr_repo_slug "$3")
  elif [[ $2 =~ $ITEM_SHORT_PATTERN ]]; then
    ITEM_REPO=${BASH_REMATCH[1]} ITEM_NUMBER=${BASH_REMATCH[2]}
  elif [[ $2 =~ $ITEM_URL_PATTERN ]]; then
    ITEM_REPO=${BASH_REMATCH[1]} ITEM_NUMBER=${BASH_REMATCH[3]}
  else
    usage_fail "a work item is N, owner/name#N, or its GitHub URL, such as https://github.com/owner/name/pull/N" "$2"
  fi
}

# Usage: item_resolve; reads the item item_parse_ref named from GitHub into ITEM: {kind, repo, number, title, state}, and
# for a PR also head_branch, head_repo (owner/name), head_url, and cross_repository, with head_repo and head_url null
# once the head's repository is gone. state is gh's OPEN, CLOSED, or MERGED. The caller has required gh.
#
# The issues API answers for both kinds and says which one the number is; only a PR's own view names its head.
ITEM='{}'
item_resolve() {
  local kind
  _item_gh api "repos/$ITEM_REPO/issues/$ITEM_NUMBER"
  kind=$(contract_json -r 'if type == "object" and has("number") then (if has("pull_request") then "pr" else "issue" end)
    else error("not an issue") end' <<<"$ITEM_GH_OUT") || _item_unreadable "gh answered with something other than an issue"
  if [[ $kind != "$ITEM_KIND" ]]; then
    contract_fail item-kind-mismatch \
      "$ITEM_REPO#$ITEM_NUMBER is $(_item_kind_word "$kind"), not $(_item_kind_word "$ITEM_KIND")" \
      --value "$ITEM_REF" --command "$(_item_swapped_command)"
  fi
  if [[ $ITEM_KIND == issue ]]; then
    ITEM=$(contract_json -c --arg repo "$ITEM_REPO" --argjson number "$ITEM_NUMBER" \
      '{kind: "issue", repo: $repo, number: $number, title: (.title // ""), state: (.state // "" | ascii_upcase)}' \
      <<<"$ITEM_GH_OUT")
    return 0
  fi
  _item_gh pr view "$ITEM_NUMBER" --repo "$ITEM_REPO" \
    --json headRefName,headRepository,headRepositoryOwner,isCrossRepository,state,title,url
  ITEM=$(contract_json -c --arg repo "$ITEM_REPO" --argjson number "$ITEM_NUMBER" '
    if type == "object" and has("headRefName") then . else error("not a PR") end
    | (if .headRepository and .headRepositoryOwner
       then "\(.headRepositoryOwner.login)/\(.headRepository.name)" else null end) as $head
    | {kind: "pr", repo: $repo, number: $number, title: (.title // ""), state, head_branch: .headRefName,
       head_repo: $head, head_url: (if $head then "https://github.com/\($head).git" else null end),
       cross_repository: (.isCrossRepository == true)}' <<<"$ITEM_GH_OUT") \
    || _item_unreadable "gh answered with something other than a PR"
}

# Usage: item_name <item>; prints the slot name of a {kind, repo, number, title} item, <repo>-<kind><N>-<slug>. The repo
# half is the repo's name with dots as dashes and no leading non-alphanumerics, and the slug the title in lowercase
# letters, digits, and single dashes. A name past TASK_PATTERN's length loses the slug's last words, then the repo
# name's last characters, so the number always stays.
item_name() {
  local repo id slug name
  local -a parts
  mapfile -t parts < <(contract_json -r '
    (.repo | split("/") | last | gsub("\\."; "-") | sub("^[^A-Za-z0-9]+"; "")),
    "\(.kind)\(.number)",
    ((.title // "") | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-"; "") | sub("-$"; ""))' <<<"$1")
  repo=${parts[0]} id=${parts[1]} slug=${parts[2]}
  while [[ -n $repo && ! $repo-$id =~ $TASK_PATTERN ]]; do repo=${repo%?}; done
  while [[ $repo == *- ]]; do repo=${repo%-}; done
  name=${repo:+$repo-}$id${slug:+-$slug}
  while [[ ! $name =~ $TASK_PATTERN ]]; do name=${name%-*}; done
  printf '%s' "$name"
}

# Usage: _item_gh <gh args...>; a bounded gh call whose output lands in ITEM_GH_OUT. GitHub's not-found answer, which it
# also gives for a repo this gh cannot see, fails with item-not-found, and a missing or rejected sign-in with
# gh-auth-missing. Anything else is an outage, so it fails with retryable pr-state-unknown.
ITEM_GH_OUT=
_item_gh() {
  bounded ITEM_GH_OUT gh 30 "$AS_GH" "$@" && return 0
  contract_use_tools gh
  if ((BOUNDED_STATUS == 4)) || grep -q 'HTTP 401' "$BOUNDED_LOG"; then
    contract_fail gh-auth-missing "gh is not signed in to GitHub, so $ITEM_REPO#$ITEM_NUMBER cannot be read" \
      --command "gh auth login" --log "$BOUNDED_LOG"
  fi
  if grep -q 'HTTP 404' "$BOUNDED_LOG"; then
    contract_fail item-not-found "GitHub has no PR or issue $ITEM_REPO#$ITEM_NUMBER that gh can see" \
      --value "$ITEM_REF" --command "agent-slot launch --help" --log "$BOUNDED_LOG"
  fi
  if ((BOUNDED_STATUS == 124)); then
    _item_unreadable "gh did not answer within 30 s"
  fi
  _item_unreadable "gh exited $BOUNDED_STATUS"
}

_item_unreadable() {
  contract_use_tools gh
  contract_fail pr-state-unknown "gh could not read $ITEM_REPO#$ITEM_NUMBER: $1" --value "$ITEM_REF" \
    --command "$(contract_quote "$CONTRACT_PROGRAM" "${CONTRACT_ARGV[@]}")" --log "$BOUNDED_LOG"
}

_item_kind_word() {
  case $1 in
    pr) printf 'a PR' ;;
    *) printf 'an issue' ;;
  esac
}

# The failing command line with --pr and --issue swapped.
_item_swapped_command() {
  local arg
  local -a argv=()
  for arg in "${CONTRACT_ARGV[@]}"; do
    case $arg in
      --pr) argv+=(--issue) ;;
      --issue) argv+=(--pr) ;;
      *) argv+=("$arg") ;;
    esac
  done
  contract_quote "$CONTRACT_PROGRAM" "${argv[@]}"
}
