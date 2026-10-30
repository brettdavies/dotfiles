# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# reopen: a torn-down slot's work brought back in a fresh slot, its Claude conversation resumed by session ID with no
# transcript moved or copied. reopen_lookup (reopenlookup.sh) finds the source teardown event and makes every refusal,
# all before anything is claimed; the slot maker then makes the slot on the head head_plan picks, as launch does.
# --dry-run reports the source, the head, and the command a reopen would type, or the refusal it would hit, and changes
# nothing, so it takes no lock.

REOPEN_REPO='' REOPEN_KIND='' REOPEN_REF='' REOPEN_SESSION='' REOPEN_PROMPT='' REOPEN_REQUEST='' REOPEN_DRY_RUN=0

# Usage: reopen_parse_args <args...>; sets the REOPEN_* inputs, refusing bad ones before anything is read.
reopen_parse_args() {
  while (($#)); do
    case $1 in
      --pr | --issue)
        [[ -z $REOPEN_KIND ]] || usage_fail "reopen takes one of --pr or --issue" "$1"
        (($# >= 2)) || usage_fail "$1 needs a ref: N, owner/name#N, or its GitHub URL" "$1"
        REOPEN_KIND=${1#--} REOPEN_REF=$2
        shift 2
        ;;
      --session | --prompt-file | --request-id)
        (($# >= 2)) || usage_fail "$1 needs a value" "$1"
        case $1 in
          --session) REOPEN_SESSION=$2 ;;
          --prompt-file) REOPEN_PROMPT=$2 ;;
          --request-id) REOPEN_REQUEST=$2 ;;
        esac
        shift 2
        ;;
      --dry-run)
        REOPEN_DRY_RUN=1
        shift
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $REOPEN_REPO ]] || usage_fail "reopen takes one repo" "$1"
        REOPEN_REPO=$1
        shift
        ;;
    esac
  done
  [[ -n $REOPEN_REPO ]] || usage_fail "reopen needs a repo; agent-slot repos lists them"
  [[ -n $REOPEN_KIND ]] || usage_fail "reopen needs --pr <ref> or --issue <ref>"
  [[ -z $REOPEN_REQUEST || $REOPEN_REQUEST =~ $REQUEST_PATTERN ]] \
    || usage_fail "a request ID uses letters, digits, ., _, and -, up to 128 characters" "$REOPEN_REQUEST"
  if [[ -n $REOPEN_PROMPT ]]; then
    [[ -f $REOPEN_PROMPT && -r $REOPEN_PROMPT ]] \
      || contract_fail prompt-file-unreadable "the first-message file cannot be read" --value "$REOPEN_PROMPT" \
        --command "agent-slot launch --help"
    REOPEN_PROMPT=$(realpath "$REOPEN_PROMPT")
  fi
}

cmd_reopen() {
  local repo=$REOPEN_REPO
  if ((REOPEN_DRY_RUN == 1)); then require_tools claude gh; else require_tools tmux claude gh trash; fi
  repo_prime "$repo"
  item_parse_ref "$REOPEN_KIND" "$REOPEN_REF" "$REPO_ORIGIN"
  item_resolve
  REOPEN_ITEM=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
  if ((REOPEN_DRY_RUN == 1)); then
    reopen_lookup "$repo"
    reopen_report
    return
  fi
  mkdir -p "$AS_ROOT/$repo"
  record_lock_repo "$repo" 60 \
    || contract_fail slot-busy "another launch or reopen on $repo held its lock for 60 s" --value "$repo" \
      --command "$(_reopen_command)"
  slot_reclaim_abandoned "$repo"
  reopen_lookup "$repo"
  if [[ -n $REOPEN_EXISTING ]]; then
    record_unlock_repo "$repo"
    _reopen_output "$REOPEN_EXISTING" false
    return
  fi
  reopen_make "$repo"
}

# Usage: _reopen_plan; sets what a slot reopened from the source teardown event carries: REOPEN_ITEMS, the event's
# items with the item added when they lack it, REOPEN_NAME, the event's name, else the first item's, and REOPEN_TASK
# and REOPEN_SESSION_ID, the event's.
REOPEN_ITEMS='[]' REOPEN_NAME='' REOPEN_TASK='' REOPEN_SESSION_ID=''
_reopen_plan() {
  REOPEN_ITEMS=$(contract_json -c --argjson i "$REOPEN_ITEM" "$ITEM_SAME_DEF"'(.items // [])
    | if any(.[]; same_item($i)) then . else . + [$i] end' \
    <<<"$REOPEN_SOURCE")
  REOPEN_NAME=$(contract_json -r '.name // ""' <<<"$REOPEN_SOURCE")
  [[ -n $REOPEN_NAME ]] || REOPEN_NAME=$(item_name "$(contract_json -c '.[0]' <<<"$REOPEN_ITEMS")")
  REOPEN_TASK=$(contract_json -r '.task // ""' <<<"$REOPEN_SOURCE")
  REOPEN_SESSION_ID=$(contract_json -r '.session_id // ""' <<<"$REOPEN_SOURCE")
}

# Usage: reopen_make <repo>; has the slot maker make the slot, from under the repo lock, with the source's items, name,
# task, session, and transcript, its PRs of origin's repo, and settled_prs: those of them already merged or closed,
# which check neither finishes nor blocks the task on, so only an outcome after the reopen finishes it. Its head is the
# one head_plan picks, and its Claude session resumes the source's conversation.
reopen_make() {
  local repo=$1 origin prs seed fields
  origin=$(pr_repo_slug "$REPO_ORIGIN")
  _reopen_plan
  prs=$(contract_json -c --argjson items "$REOPEN_ITEMS" --arg origin "$origin" "$ITEM_SAME_DEF"'
    (.prs // []) + [$items[] | select(.kind == "pr" and same_repo(.repo; $origin)) | .number] | unique' \
    <<<"$REOPEN_SOURCE")
  _reopen_settled "$prs" "$origin"
  head_plan "$REOPEN_SOURCE" "$ITEM"
  seed=$(contract_json -c --arg request "$REOPEN_REQUEST" --argjson requested "$(date +%s.%N)" \
    --argjson items "$REOPEN_ITEMS" --arg name "$REOPEN_NAME" --arg task "$REOPEN_TASK" \
    --arg session "$REOPEN_SESSION_ID" --arg transcript "$REOPEN_TRANSCRIPT" --argjson prs "$prs" \
    --argjson settled "$REOPEN_SETTLED" '
    def text: if . == "" then null else . end;
    {request_id: ($request | text), requested_at: $requested, items: $items, name: $name, named_as: $name,
     task: ($task | text), session_id: $session, transcript: ($transcript | text), prs: $prs, settled_prs: $settled,
     reopened_from: {slot, session_id, ts}}' <<<"$REOPEN_SOURCE")
  fields=$(contract_json -n -c --argjson item "$REOPEN_ITEM" --argjson seed "$seed" --argjson head "$HEAD_PLAN" \
    '{item: $item, reopened_from: $seed.reopened_from, head: $head}')
  slot_make "$repo" reopen "$(_reopen_command no-request)" "$seed" "$REOPEN_PROMPT" reopen _reopen_head "$fields"
  _reopen_output "$SLOT_MADE" true "$SLOT_MADE_TRUST" "$SLOT_MADE_PHASES"
}

# Usage: _reopen_settled <PR numbers> <origin owner/name>; sets REOPEN_SETTLED to those of origin's PRs that GitHub
# reports merged or closed. The item's own state came with it; any other's comes from the list of origin's PRs that
# check reads too, so a PR check cannot see is never settled. Not knowing fails the reopen, since a merged PR counted
# as new would finish the task at once.
REOPEN_SETTLED='[]'
_reopen_settled() {
  local others list='[]'
  others=$(contract_json -c --argjson i "$ITEM" --arg origin "$2" "$ITEM_SAME_DEF"'
    map(select(($i.kind == "pr" and same_repo($i.repo; $origin) and . == $i.number) | not))' <<<"$1")
  if [[ $others != '[]' ]]; then
    pr_load "$REOPEN_REPO" "$REPO_ORIGIN"
    [[ ${PR_OK[$REOPEN_REPO]} == 1 ]] || contract_fail pr-state-unknown "gh could not read the PRs of $2, so which of \
the source's PRs have merged or closed is unknown" --value "$2" --command "$(_reopen_command)"
    list=${PR_LISTS[$REOPEN_REPO]}
  fi
  REOPEN_SETTLED=$(contract_json -c --argjson i "$ITEM" --arg origin "$2" --argjson list "$list" "$ITEM_SAME_DEF"'
    def settled: . == "MERGED" or . == "CLOSED";
    [.[] as $n | if $i.kind == "pr" and same_repo($i.repo; $origin) and $n == $i.number
                 then $n | select($i.state | settled)
                 else $list[] | select(.number == $n and (.state | settled)) | .number end] | unique' <<<"$1")
}

# The head step of a reopen: the branch HEAD_PLAN names, unless that is the base the clone already has. Sets
# REOPEN_HEAD_MOVED to whether the head differs from the commit the ledger recorded, or null when it recorded none.
REOPEN_HEAD_MOVED=null
_reopen_head() {
  local oid remote
  [[ $(contract_json -r .source.branch <<<"$HEAD_PLAN") != base ]] || return 0
  remote=$(contract_json -r '.remote // ""' <<<"$HEAD_PLAN")
  head_checkout "$1" "$(contract_json -r .branch <<<"$HEAD_PLAN")" "$remote" \
    "$(contract_json -r '.url // ""' <<<"$HEAD_PLAN")" "$REOPEN_KIND" "$ITEM_REPO" "$ITEM_NUMBER" "$(_reopen_command)"
  oid=$(contract_json -r '.oid // ""' <<<"$HEAD_PLAN")
  [[ -z $oid ]] || REOPEN_HEAD_MOVED=$([[ $(git -C "$1" rev-parse HEAD) == "$oid" ]] && echo false || echo true)
}

# Usage: _reopen_output <n> <created> [<trust-prompt-expected> <phases-json>]; launch's output for the slot, with
# reopened_from, settled_prs, and the head this call checked out.
_reopen_output() {
  local extra
  record_read "$REOPEN_REPO" "$1" || RECORD='{}'
  extra=$(contract_json -c --argjson head "$HEAD_PLAN" --argjson moved "$REOPEN_HEAD_MOVED" \
    '{reopened_from, settled_prs: (.settled_prs // []), head: $head, head_moved: $moved}' <<<"$RECORD")
  LAUNCH_PROMPT=$REOPEN_PROMPT
  launch_output "$REOPEN_REPO" "$1" "$2" "${3:-false}" "${4:-null}" "$extra"
}

# Usage: reopen_report; the dry run's output: for a source teardown event, what _reopen_plan takes from it, the lowest
# free slot, and the command sessions_command would type there.
reopen_report() {
  local repo=$REOPEN_REPO n=1 would=false delivered=null items='[]' name='' task='' session='' slot='' command=''
  local head=null
  if [[ -n $REOPEN_HOLDER ]]; then
    items=$(contract_json -c .items <<<"$REOPEN_SOURCE")
    name=$(contract_json -r '.name // ""' <<<"$REOPEN_SOURCE")
    session=$(contract_json -r '.session_id // ""' <<<"$REOPEN_SOURCE")
    [[ -z $REOPEN_EXISTING ]] || slot=$REOPEN_HOLDER
  elif [[ $REOPEN_SOURCE != null ]]; then
    _reopen_plan
    items=$REOPEN_ITEMS name=$REOPEN_NAME task=$REOPEN_TASK session=$REOPEN_SESSION_ID
    while slot_taken "$repo" "$n"; do n=$((n + 1)); done
    slot=$(slot_key "$repo" "$n")
    head_plan "$REOPEN_SOURCE" "$ITEM"
    head=$HEAD_PLAN
    RECORD=$(contract_json -n -c --arg session "$session" --arg name "$name" --arg task "$task" \
      --arg prompt "${REOPEN_PROMPT:+$(slot_prompt_file "$(slot_path "$repo" "$n")")}" '
      {session_id: $session, name: $name, task: (if $task == "" then null else $task end),
       prompt_file: (if $prompt == "" then null else $prompt end)}')
    command=$(sessions_command "$repo" "$n" claude reopen)
  fi
  [[ $REOPEN_REFUSAL != null || -n $REOPEN_HOLDER || $REOPEN_SOURCE == null ]] || would=true
  [[ -z $REOPEN_PROMPT ]] || delivered=$would
  contract_ok "$(contract_json -n -c --argjson would "$would" --argjson refusal "$REOPEN_REFUSAL" \
    --argjson item "$REOPEN_ITEM" --argjson source "$REOPEN_SOURCE" --arg name "$name" --argjson items "$items" \
    --arg task "$task" --arg session "$session" --arg transcript "$REOPEN_TRANSCRIPT" \
    --argjson exists "$REOPEN_TRANSCRIPT_EXISTS" --argjson head "$head" --arg slot "$slot" \
    --arg command "$command" --argjson delivered "$delivered" '
    def text: if . == "" then null else . end;
    {dry_run: true, would_reopen: $would, refusal: $refusal, item: $item, source: $source, name: ($name | text),
     items: $items, task: ($task | text), session_id: ($session | text), transcript: ($transcript | text),
     transcript_exists: $exists, head: $head, slot: ($slot | text), command: ($command | text),
     prompt_delivered: $delivered}')" '
    "\(.item.repo)#\(.item.number): " + (
      if .would_reopen then
        "would reopen \(.source.repo)/\(.source.slot), torn down \(.source.ts), in \(.slot) as \(.name)\n"
        + "  session \(.session_id), transcript \(.transcript)\n"
        + "  head \(.head.branch) " + (if .head.remote then "from \(.head.remote) at \(.head.url)"
                                       else "from refs/pull/\(.item.number)/head" end) + "\n"
        + "  command: \(.command)"
      elif .refusal then
        "would refuse with \(.refusal.reason): \(.refusal.message)"
        + (if .refusal.next_step.command then "\n  next: \(.refusal.next_step.command)" else "" end)
      else "\(.slot) already holds this request" end)'
}

# Usage: _reopen_command [no-request]; the reopen's command line without --dry-run, for an error's next step, and
# without --request-id too when asked.
_reopen_command() {
  local -a argv=(agent-slot reopen "$REOPEN_REPO" "--$REOPEN_KIND" "$REOPEN_REF")
  [[ -z $REOPEN_SESSION ]] || argv+=(--session "$REOPEN_SESSION")
  [[ -z $REOPEN_PROMPT ]] || argv+=(--prompt-file "$REOPEN_PROMPT")
  [[ ${1:-} == no-request || -z $REOPEN_REQUEST ]] || argv+=(--request-id "$REOPEN_REQUEST")
  contract_quote "${argv[@]}"
}

# A fresh start for the same item, the next step when there is nothing to reopen.
_reopen_launch_command() {
  contract_quote agent-slot launch "$REOPEN_REPO" "--$REOPEN_KIND" "$REOPEN_REF"
}
