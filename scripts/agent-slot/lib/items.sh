# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Work items: the GitHub PR or issue a slot works on. A ref names one as N, owner/name#N, or its GitHub URL, a bare N
# being in origin's repo; item_resolve reads it from GitHub, and item_name alone derives a slot's name from it. A slot's
# record holds its items as {kind, repo, number, title} and its name, which the first item gives and which no later item
# changes; item_add is the one writer of both, for check's adoption of a PR and for the adopt verb.

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

# A jq definition: whether a work item is $i, by kind, repo, and number, whatever its title.
ITEM_SAME_DEF='def same_item($i): .kind == $i.kind and .repo == $i.repo and .number == $i.number;'

# The update item_add applies to a record, with $items, $origin (owner/name), and $name bound: each item joins .items
# unless one with its kind, repo, and number is there, each PR of origin's repo joins .prs, which means origin's PRs
# wherever check reads it, and a record with no name takes $name.
ITEM_ADD_FILTER='(if $items == [] then . else .items = reduce $items[] as $i (.items // [];
      if any(.[]; same_item($i)) then . else . + [$i] end) end)
  | .prs = ((.prs // []) + [$items[] | select(.kind == "pr" and .repo == $origin) | .number] | unique)
  | if .name == null and $name != "" then .name = $name else . end'

# Usage: item_add <repo> <n> <origin url> <items> [<jq options...> <filter>]; adds the JSON array <items> of work items
# to the slot's record under its lock, the first one naming a slot that has no name. A filter given runs after, in the
# same update.
item_add() {
  local repo=$1 n=$2 origin items name='' filter=$ITEM_SAME_DEF$ITEM_ADD_FILTER
  origin=$(pr_repo_slug "$3")
  items=$(contract_json -c 'map({kind, repo, number, title: (.title // "")})' <<<"$4")
  shift 4
  if (($# > 0)); then
    filter+=" | ${*: -1}"
    set -- "${@:1:$#-1}"
  fi
  [[ $items == '[]' ]] || name=$(item_name "$(contract_json -c '.[0]' <<<"$items")")
  record_update "$repo" "$n" --argjson items "$items" --arg origin "$origin" --arg name "$name" "$@" "$filter"
}

ADOPT_KEY='' ADOPT_KIND='' ADOPT_REF=''

# Usage: adopt_parse_args <args...>; sets ADOPT_KEY, ADOPT_KIND (pr or issue), and ADOPT_REF.
adopt_parse_args() {
  while (($#)); do
    case $1 in
      --pr | --issue)
        [[ -z $ADOPT_KIND ]] || usage_fail "adopt takes one of --pr or --issue" "$1"
        (($# >= 2)) || usage_fail "$1 needs a ref: N, owner/name#N, or its GitHub URL" "$1"
        ADOPT_KIND=${1#--} ADOPT_REF=$2
        shift 2
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $ADOPT_KEY ]] || usage_fail "adopt takes one slot, <repo>/<N>" "$1"
        ADOPT_KEY=$1
        shift
        ;;
    esac
  done
  [[ -n $ADOPT_KEY ]] || usage_fail "adopt needs a slot, <repo>/<N>"
  [[ -n $ADOPT_KIND ]] || usage_fail "adopt needs --pr <ref> or --issue <ref>"
  slot_parse_key "$ADOPT_KEY"
}

# Usage: cmd_adopt; attaches the item ADOPT_KIND and ADOPT_REF name to the slot SLOT_REPO/SLOT_N, logs an adopt event,
# and renames the slot's Claude session when its agent is idle. A busy agent's session is renamed by a later automatic
# sweep.
cmd_adopt() {
  local repo=$SLOT_REPO n=$SLOT_N key=$ADOPT_KEY origin item renamed=false
  require_tools tmux claude gh
  slot_taken "$repo" "$n" \
    || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  origin=$(git -C "$(slot_path "$repo" "$n")" config --get remote.origin.url || true)
  item_parse_ref "$ADOPT_KIND" "$ADOPT_REF" "$origin"
  item_resolve
  item=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
  agentstate_load
  record_lock_slot "$repo" "$n" --wait 10 \
    || contract_fail slot-busy "another agent-slot process held $key for 10 s, so $ITEM_REPO#$ITEM_NUMBER was not \
attached" --value "$key" --command "$(contract_quote "$CONTRACT_PROGRAM" "${CONTRACT_ARGV[@]}")"
  item_add "$repo" "$n" "$origin" "[$item]" \
    || contract_fail slot-not-found "$key has no record to attach $ITEM_REPO#$ITEM_NUMBER to" --value "$key" \
      --command "agent-slot list"
  record_read "$repo" "$n"
  ledger_append adopt "$(contract_json -c --argjson item "$item" \
    '{repo, slot, task, session_id, item: $item, name}' <<<"$RECORD")"
  agentstate_of "$repo" "$n"
  if release_rename "$repo" "$n"; then renamed=true; fi
  record_unlock_slot "$repo" "$n"
  contract_ok "$(contract_json -c --arg key "$key" --argjson item "$item" --argjson renamed "$renamed" \
    '{key: $key, name, items, item: $item, renamed: $renamed}' <<<"$RECORD")" '
    "\(.key): \(.item.repo)#\(.item.number) attached; the slot is named \(.name)"
      + (if .renamed then ", and its Claude session renamed" else "" end)'
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
