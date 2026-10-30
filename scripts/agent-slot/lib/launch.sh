# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# launch and resume. launch returns the slot that already holds its request, task, or work item, and otherwise has the
# slot maker make one; a launch with a PR has the PR's head checked out there.

TASK_PATTERN='^[A-Za-z0-9][A-Za-z0-9_/-]{0,63}$'
TASK_RULE='a task name uses letters, digits, -, _, and /, starts with a letter or digit, and is at most 64 characters'
REQUEST_PATTERN='^[A-Za-z0-9._-]{1,128}$'

LAUNCH_REPO='' LAUNCH_TASK='' LAUNCH_REQUEST='' LAUNCH_PROMPT='' LAUNCH_REQUESTED_AT=''
LAUNCH_ITEM_KIND='' LAUNCH_ITEM_REF='' LAUNCH_ITEM='' LAUNCH_NAME=''

# Usage: launch_parse_args <args...>; sets the LAUNCH_* inputs, refusing bad ones before anything is touched.
launch_parse_args() {
  LAUNCH_REQUESTED_AT=''
  while (($#)); do
    case $1 in
      --pr | --issue)
        [[ -z $LAUNCH_ITEM_KIND ]] || usage_fail "launch takes one of --pr or --issue" "$1"
        (($# >= 2)) || usage_fail "$1 needs a ref: N, owner/name#N, or its GitHub URL" "$1"
        LAUNCH_ITEM_KIND=${1#--} LAUNCH_ITEM_REF=$2
        shift 2
        ;;
      --task | --request-id | --prompt-file | --requested-at)
        (($# >= 2)) || usage_fail "$1 needs a value" "$1"
        case $1 in
          --task) LAUNCH_TASK=$2 ;;
          --request-id) LAUNCH_REQUEST=$2 ;;
          --prompt-file) LAUNCH_PROMPT=$2 ;;
          --requested-at) LAUNCH_REQUESTED_AT=$2 ;;
        esac
        shift 2
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $LAUNCH_REPO ]] || usage_fail "launch takes one repo" "$1"
        LAUNCH_REPO=$1
        shift
        ;;
    esac
  done
  [[ -n $LAUNCH_REPO ]] || usage_fail "launch needs a repo; agent-slot repos lists them"
  [[ -z $LAUNCH_TASK || $LAUNCH_TASK =~ $TASK_PATTERN ]] \
    || contract_fail invalid-task-name "$TASK_RULE" --value "$LAUNCH_TASK" --command "agent-slot launch --help"
  [[ -z $LAUNCH_REQUEST || $LAUNCH_REQUEST =~ $REQUEST_PATTERN ]] \
    || usage_fail "a request ID uses letters, digits, ., _, and -, up to 128 characters" "$LAUNCH_REQUEST"
  if [[ -n $LAUNCH_PROMPT ]]; then
    [[ -f $LAUNCH_PROMPT && -r $LAUNCH_PROMPT ]] \
      || contract_fail prompt-file-unreadable "the first-message file cannot be read" --value "$LAUNCH_PROMPT" \
        --command "agent-slot launch --help"
    LAUNCH_PROMPT=$(realpath "$LAUNCH_PROMPT")
  fi
  [[ -n $LAUNCH_REQUESTED_AT ]] || LAUNCH_REQUESTED_AT=$(date +%s.%N)
  [[ $LAUNCH_REQUESTED_AT =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || usage_fail "--requested-at takes seconds since the epoch" "$LAUNCH_REQUESTED_AT"
}

# Sets LAUNCH_EXISTING to the slot holding this request ID, this task when one was given, or this work item when one
# was given, and LAUNCH_EXISTING_BY to request, task, or item; returns 1 when none does. A slot holds the item when its
# items do, by kind, repo, and number, or, for a PR of origin's repo, when its PRs do; a title that changed since does
# not matter.
LAUNCH_EXISTING='' LAUNCH_EXISTING_BY=''
launch_find_existing() {
  local repo=$1 n request task state origin held=false
  LAUNCH_EXISTING='' LAUNCH_EXISTING_BY=''
  origin=$(pr_repo_slug "$REPO_ORIGIN")
  while read -r n; do
    if [[ -z $n ]] || ! record_read "$repo" "$n"; then continue; fi
    request=$(contract_json -r '.request_id // ""' <<<"$RECORD")
    task=$(contract_json -r '.task // ""' <<<"$RECORD")
    state=$(contract_json -r '.state // ""' <<<"$RECORD")
    [[ -z $LAUNCH_ITEM ]] || held=$(contract_json -r --argjson i "$LAUNCH_ITEM" --arg origin "$origin" '
      any(.items[]?; .kind == $i.kind and .repo == $i.repo and .number == $i.number)
      or ($i.kind == "pr" and $i.repo == $origin and any(.prs[]?; . == $i.number))' <<<"$RECORD")
    if [[ -n $LAUNCH_REQUEST && $request == "$LAUNCH_REQUEST" ]]; then
      LAUNCH_EXISTING=$n LAUNCH_EXISTING_BY=request
      return 0
    fi
    if [[ -n $LAUNCH_TASK && $task == "$LAUNCH_TASK" && $state != tearing-down ]]; then
      LAUNCH_EXISTING=$n LAUNCH_EXISTING_BY=task
      return 0
    fi
    if [[ $held == true ]]; then
      LAUNCH_EXISTING=$n LAUNCH_EXISTING_BY=item
      return 0
    fi
  done < <(slot_numbers "$repo")
  return 1
}

# Usage: launch_item; reads the --pr or --issue item from GitHub into ITEM and LAUNCH_ITEM, {kind, repo, number,
# title}, sets LAUNCH_NAME to the slot name it gives, and gives a launch with no --task that name as its task.
launch_item() {
  item_parse_ref "$LAUNCH_ITEM_KIND" "$LAUNCH_ITEM_REF" "$REPO_ORIGIN"
  item_resolve
  LAUNCH_ITEM=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
  LAUNCH_NAME=$(item_name "$LAUNCH_ITEM")
  [[ -n $LAUNCH_TASK ]] || LAUNCH_TASK=$LAUNCH_NAME
}

# The head step of a launch with a PR: the PR's head, from the remote the prime knows the head's repo by.
_launch_head() {
  local url
  url=$(contract_json -r '.head_url // ""' <<<"$ITEM")
  HEAD_REMOTE='' HEAD_URL=''
  [[ -z $url ]] || head_remote_for "$REPO_PRIME" "$url"
  head_checkout "$1" "$(contract_json -r '.head_branch' <<<"$ITEM")" "$HEAD_REMOTE" "$HEAD_URL" "$ITEM_REPO" \
    "$ITEM_NUMBER" "$(_launch_command)${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}"
}

# The launch's command line without --request-id, for an error's next step.
_launch_command() {
  printf 'agent-slot launch %s' "$LAUNCH_REPO"
  [[ -z $LAUNCH_ITEM_KIND ]] || printf ' --%s %s' "$LAUNCH_ITEM_KIND" "$(contract_quote "$LAUNCH_ITEM_REF")"
}

# Usage: launch_output <repo> <n> <created> [<trust-prompt-expected> <phases-json> [<fields-json>]]
# prompt_delivered says whether this call's --prompt-file is the slot's first message: true for a new slot or a retry
# of the request that made it, false for a slot another request made, null without a --prompt-file. head_pushable says
# whether this call checked out a PR's head that can be pushed to, null when it checked out none. <fields-json> is
# merged over the output.
launch_output() {
  local repo=$1 n=$2 created=$3 trust=${4:-false} phases=${5:-null} fields=${6:-'{}'} delivered=null path
  path=$(slot_path "$repo" "$n")
  record_read "$repo" "$n" || RECORD='{}'
  if [[ -n $LAUNCH_PROMPT ]]; then
    delivered=false
    [[ $created != true && $LAUNCH_EXISTING_BY != request ]] || delivered=true
  fi
  contract_ok "$(contract_json -c --arg key "$(slot_key "$repo" "$n")" --arg path "$path" \
    --argjson created "$created" --argjson trust "$trust" --argjson phases "$phases" --arg docs "$CONTRACT_DOCS" \
    --argjson delivered "$delivered" --arg branch "$(slot_branch "$path")" --argjson pushable "$HEAD_PUSHABLE" \
    --argjson fields "$fields" \
    --argjson missing "$(printf '%s\n' "${PARITY_MISSING_SIBLINGS[@]}" | contract_json -R -s -c 'split("\n") | map(select(. != ""))')" \
    "$SLOT_LABEL_DEF"'{created: $created, key: $key, repo: .repo, slot: .slot, path: $path, state: .state, task: .task,
      name: .name, items: (.items // []), label_name: label_name($branch), request_id: .request_id,
      session_id: .session_id, base: .base, head_pushable: $pushable, trust_prompt_expected: $trust,
      prompt_delivered: $delivered, missing_siblings: $missing, phases: $phases,
      next_step: {action: "run", command: "agent-slot check \($key) --output json", docs: $docs,
                  note: ("each Rex client is asked to open this slot'"'"'s tab when the slot is made; a Mac that"
                         + " is asleep or offline opens it once it is back")}} + $fields' <<<"$RECORD")" '
    "\(.key) \(if .created then "is ready" else "already holds this request" end) at \(.path)" +
      (if .label_name then " (\(.label_name))" else "" end) +
      (if .trust_prompt_expected then "; Claude will ask to trust the folder" else "" end) +
      (if .prompt_delivered == false
       then "; this first message was not delivered, because the slot already holds the task" else "" end) +
      (if .prior then "\n\(.prior.note)" else "" end)'
}

# Usage: launch_prior <repo>; prints {prior: {session_id, ts, note}} for the newest torn-down slot of the repo that
# worked on the launch's item, whose conversation reopen resumes, else {prior: null}.
launch_prior() {
  contract_json -c --arg cmd "$(contract_quote agent-slot reopen "$1" "--$LAUNCH_ITEM_KIND" "$LAUNCH_ITEM_REF")" '
    {prior: (if . == null then null else {session_id, ts,
      note: "a slot torn down \(.ts) worked on this item; \($cmd) resumes its conversation once no slot holds the item"}
      end)}' \
    <<<"$(reopen_source_event "$1" "$LAUNCH_ITEM")"
}

cmd_launch() {
  local repo=$LAUNCH_REPO state seed head=''
  require_tools tmux claude trash
  [[ -z $LAUNCH_ITEM_KIND ]] || require_tools gh
  repo_prime "$repo"
  [[ -z $LAUNCH_ITEM_KIND ]] || launch_item
  [[ $LAUNCH_ITEM_KIND != pr ]] || head=_launch_head

  mkdir -p "$AS_ROOT/$repo"
  record_lock_repo "$repo" 60 \
    || contract_fail slot-busy "another launch on $repo held its lock for 60 s" --value "$repo" \
      --command "$(_launch_command)${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}"
  slot_reclaim_abandoned "$repo"
  if launch_find_existing "$repo"; then
    record_unlock_repo "$repo"
    record_read "$repo" "$LAUNCH_EXISTING" || RECORD='{}'
    state=$(contract_json -r '.state // "setting-up"' <<<"$RECORD")
    if [[ $state != active ]]; then
      contract_fail slot-busy "$(slot_key "$repo" "$LAUNCH_EXISTING") is $state, so this launch cannot report it yet" \
        --value "$(slot_key "$repo" "$LAUNCH_EXISTING")" \
        --command "$(_launch_command)${LAUNCH_REQUEST:+ --request-id $LAUNCH_REQUEST}"
    fi
    launch_output "$repo" "$LAUNCH_EXISTING" false false null '{"prior": null}'
    return
  fi
  # The session starts under the name, so named_as keeps the automatic sweep from typing a /rename to it.
  seed=$(contract_json -n -c --arg task "$LAUNCH_TASK" --arg request "$LAUNCH_REQUEST" \
    --argjson requested "$LAUNCH_REQUESTED_AT" --argjson item "${LAUNCH_ITEM:-null}" --arg name "$LAUNCH_NAME" \
    --arg origin "$(pr_repo_slug "$REPO_ORIGIN")" '
    {task: (if $task == "" then null else $task end), request_id: (if $request == "" then null else $request end),
     requested_at: $requested}
    + if $item == null then {} else
        {prs: (if $item.kind == "pr" and $item.repo == $origin then [$item.number] else [] end), items: [$item],
         name: $name, named_as: $name}
      end')
  slot_make "$repo" launch "$(_launch_command)" "$seed" "$LAUNCH_PROMPT" launch "$head"
  launch_output "$repo" "$SLOT_MADE" true "$SLOT_MADE_TRUST" "$SLOT_MADE_PHASES" \
    "$(if [[ -n $LAUNCH_ITEM ]]; then launch_prior "$repo"; else echo '{"prior": null}'; fi)"
}

cmd_resume() {
  local repo n state
  slot_parse_key "$1"
  repo=$SLOT_REPO n=$SLOT_N
  require_tools tmux claude
  slot_taken "$repo" "$n" \
    || contract_fail slot-not-found "$1 holds no slot" --value "$1" --command "agent-slot list"
  record_lock_slot "$repo" "$n" --wait "$AS_LOCK_WAIT" \
    || contract_fail slot-busy "$1 stayed locked for $AS_LOCK_WAIT s" --value "$1" --command "agent-slot resume $1"
  teardown_recover "$repo" "$n"
  record_read "$repo" "$n" || contract_fail slot-not-found "$1 has no record" --value "$1" --command "agent-slot list"
  state=$(contract_json -r '.state // ""' <<<"$RECORD")
  [[ $state == active ]] || contract_fail slot-busy "$1 is $state" --value "$1" --command "agent-slot resume $1"
  sessions_start "$repo" "$n" resume
  record_unlock_slot "$repo" "$n"
  contract_ok "$(printf '%s\n' "${SESSIONS_CREATED[@]}" | contract_json -R -s -c --arg key "$1" \
    '{key: $key, started: split("\n") | map(select(. != ""))}')" \
    '"\(.key): " + (if (.started | length) == 0 then "every session was already running" else "started \(.started | join(", "))" end)'
}
