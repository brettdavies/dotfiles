# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# reopen: a torn-down slot's work brought back in a fresh slot, its Claude conversation resumed by session ID. The
# source is a teardown event of the repo's slots in the ledger: the one --session names, else the newest whose work
# items hold the item, else, for a PR of origin's repo, the newest whose PRs hold its number, which covers slots torn
# down before work items were recorded. A reopen refuses while a slot holds the item or the source's session, while a
# Claude agent has that session open, and once Claude Code no longer has its transcript; every refusal comes before
# anything is claimed. --dry-run reports the source, the head, and the command a reopen would type, or the refusal it
# would hit, and changes nothing, so it takes no lock.

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
  contract_fail usage "reopen without --dry-run is not available; --dry-run reports what it would do" \
    --value "$repo" --command "$(_reopen_command) --dry-run"
}

# Usage: reopen_lookup <repo>; finds what the reopen of REOPEN_ITEM starts from, stopping at the first
# refusal: contract_fail for a reopen, REOPEN_REFUSAL for a dry run. Sets REOPEN_HOLDER to a slot that holds the
# request ID or the item, with REOPEN_SOURCE its {key, state, name, items, session_id} and REOPEN_EXISTING its number
# when the request ID matched an active slot; else REOPEN_SOURCE to the source teardown event, or null, and
# REOPEN_TRANSCRIPT and REOPEN_TRANSCRIPT_EXISTS to where its transcript is.
REOPEN_ITEM='' REOPEN_HOLDER='' REOPEN_EXISTING='' REOPEN_SOURCE=null REOPEN_REFUSAL=null
REOPEN_TRANSCRIPT='' REOPEN_TRANSCRIPT_EXISTS=null
reopen_lookup() {
  local repo=$1 session missing
  LAUNCH_REQUEST=$REOPEN_REQUEST LAUNCH_TASK='' LAUNCH_ITEM=$REOPEN_ITEM
  if launch_find_existing "$repo"; then
    REOPEN_HOLDER=$(slot_key "$repo" "$LAUNCH_EXISTING")
    record_read "$repo" "$LAUNCH_EXISTING" || RECORD='{}'
    REOPEN_SOURCE=$(contract_json -c --arg key "$REOPEN_HOLDER" '{key: $key, state: (.state // "setting-up"),
      name: (.name // .task), items: (.items // []), session_id}' <<<"$RECORD")
    if [[ $LAUNCH_EXISTING_BY == request && $(contract_json -r .state <<<"$REOPEN_SOURCE") == active ]]; then
      REOPEN_EXISTING=$LAUNCH_EXISTING
      return 0
    fi
    _reopen_held "$repo" "$LAUNCH_EXISTING" "$(_reopen_item_key)"
    return 0
  fi
  _reopen_source "$repo" || return 0
  session=$(contract_json -r '.session_id // ""' <<<"$REOPEN_SOURCE")
  _reopen_find_transcript "$session"
  _reopen_session_slot "$session" || return 0
  _reopen_session_agent "$session" || return 0
  [[ $REOPEN_TRANSCRIPT_EXISTS != true ]] || return 0
  missing="Claude Code has no transcript of session $session"
  [[ -z $REOPEN_TRANSCRIPT ]] || missing+=" at $REOPEN_TRANSCRIPT"
  _reopen_refuse transcript-missing "$missing or under $AS_CLAUDE_PROJECTS, so its conversation cannot be resumed; \
launch a fresh slot instead" --value "$session" --command "$(_reopen_launch_command)"
}

# Usage: _reopen_refuse <reason> <message> [contract_fail options]; fails a reopen, or keeps the refusal a dry run
# reports in REOPEN_REFUSAL: the error object's fields a caller acts on.
_reopen_refuse() {
  ((REOPEN_DRY_RUN == 1)) || contract_fail "$@"
  REOPEN_REFUSAL=$(contract_error_json "$@" | contract_json -c 'del(.schema, .ok, .verb, .context, .log)')
}

# Usage: _reopen_held <repo> <n> <what>; refuses because the slot holds <what>: slot-busy while it is setting up or
# tearing down, which a retry outlasts, else item-held-by-slot naming the slot's name, the session to send a brief to.
_reopen_held() {
  local key state name
  key=$(slot_key "$1" "$2")
  record_read "$1" "$2" || RECORD='{}'
  state=$(contract_json -r '.state // "setting-up"' <<<"$RECORD")
  name=$(contract_json -r '.name // .task // ""' <<<"$RECORD")
  if [[ $state == setting-up || $state == tearing-down ]]; then
    _reopen_refuse slot-busy "$key holds $3 and is $state" --value "$key" --command "$(_reopen_command)"
  else
    _reopen_refuse item-held-by-slot "$key${name:+ ($name)} holds $3; send the brief to that slot's Claude session, \
or bring back its sessions with agent-slot resume" --value "$key" --command "agent-slot resume $key"
  fi
}

# Sets REOPEN_SOURCE to the source teardown event, or refuses with item-not-found-in-ledger and returns 1. Each match
# is ranked, 2 for an event whose items hold the item and 1 for one whose PRs hold an origin PR's number, and the last
# line of the highest rank is the newest. The ledger is read line by line, so a line that is not JSON is skipped.
_reopen_source() {
  local repo=$1 key
  key=$(_reopen_item_key)
  REOPEN_SOURCE=$({ [[ ! -r $AS_LEDGER ]] || contract_json -c -R --arg repo "$repo" --arg session "$REOPEN_SESSION" \
    --arg origin "$(pr_repo_slug "$REPO_ORIGIN")" --argjson i "$REOPEN_ITEM" '
    fromjson? | select(type == "object" and .event == "teardown" and .repo == $repo)
    | if $session != "" then select(.session_id == $session) | [0, .]
      elif any(.items[]?; .kind == $i.kind and .repo == $i.repo and .number == $i.number) then [2, .]
      elif $i.kind == "pr" and $i.repo == $origin and any(.prs[]?; . == $i.number) then [1, .]
      else empty end' "$AS_LEDGER"; } \
    | contract_json -s -c 'if length == 0 then null
      else (map(.[0]) | max) as $r | map(select(.[0] == $r)) | last | .[1] end')
  if [[ $REOPEN_SOURCE == null && -n $REOPEN_SESSION ]]; then
    _reopen_refuse item-not-found-in-ledger "no teardown of a $repo slot in $AS_LEDGER has session $REOPEN_SESSION" \
      --value "$key" --command "$(_reopen_launch_command)"
    return 1
  fi
  if [[ $REOPEN_SOURCE == null ]]; then
    _reopen_refuse item-not-found-in-ledger "no teardown of a $repo slot in $AS_LEDGER names $key; a slot torn down \
before its work items were recorded is reopened by its Claude session ID, with --session <id>" --value "$key" \
      --command "$(_reopen_launch_command)"
    return 1
  fi
  [[ -n $REOPEN_SESSION ]] || return 0
  contract_json -e --argjson i "$REOPEN_ITEM" '(.items // []) | . == []
    or any(.[]; .kind == $i.kind and .repo == $i.repo and .number == $i.number)' <<<"$REOPEN_SOURCE" >/dev/null \
    && return 0
  _reopen_refuse item-not-found-in-ledger "the teardown of $repo/$(contract_json -r .slot <<<"$REOPEN_SOURCE") with \
session $REOPEN_SESSION names $(contract_json -r '[.items[] | "\(.repo)#\(.number)"] | join(", ")' <<<"$REOPEN_SOURCE"), \
not $key" --value "$key" --command "$(_reopen_launch_command)"
  REOPEN_SOURCE=null
  return 1
}

# Usage: _reopen_find_transcript <session id>; the source's transcript at its recorded path, else by its ID in any of
# Claude's project directories. An ID that is not plain hex and dashes is not searched for.
_reopen_find_transcript() {
  local id=$1 found
  REOPEN_TRANSCRIPT=$(contract_json -r '.transcript // ""' <<<"$REOPEN_SOURCE") REOPEN_TRANSCRIPT_EXISTS=false
  if [[ -n $REOPEN_TRANSCRIPT && -f $REOPEN_TRANSCRIPT ]]; then
    REOPEN_TRANSCRIPT_EXISTS=true
    return 0
  fi
  [[ $id =~ ^[0-9A-Fa-f-]+$ ]] || return 0
  found=$(find "$AS_CLAUDE_PROJECTS" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null || true)
  [[ -z $found ]] || REOPEN_TRANSCRIPT=$found REOPEN_TRANSCRIPT_EXISTS=true
}

# Refuses, returning 1, when a slot of any repo has the session as its own.
_reopen_session_slot() {
  local id=$1 repo n
  [[ -n $id ]] || return 0
  while read -r repo; do
    while read -r n; do
      if [[ -z $n ]] || ! record_read "$repo" "$n"; then continue; fi
      [[ $(contract_json -r '.session_id // ""' <<<"$RECORD") == "$id" ]] || continue
      _reopen_held "$repo" "$n" "session $id"
      return 1
    done < <(slot_numbers "$repo")
  done < <(slot_repos)
}

# Refuses, returning 1, when a Claude agent has the session open, or when claude agents cannot say whether one has.
_reopen_session_agent() {
  local id=$1 holder
  [[ -n $id ]] || return 0
  agentstate_agents
  if ((AGENTS_OK == 0)); then
    _reopen_refuse session-in-use "claude agents --json failed, so whether a Claude agent has session $id open is \
unknown" --command "$(_reopen_command)"
    return 1
  fi
  holder=$(contract_json -r --arg s "$id" '[.[] | select(.sessionId == $s) | "\(.pid) \(.cwd)"] | .[0] // empty' \
    <<<"$AGENTS_JSON")
  [[ -n $holder ]] || return 0
  _reopen_refuse session-in-use "Claude agent ${holder%% *} in ${holder#* } has session $id open; the reopen can run \
once the operator closes it" --value "$holder" --command "$(_reopen_command)"
  return 1
}

# Usage: reopen_report; the dry run's output. A reopen from a teardown event takes the event's items, with the item
# added when they lack it, its name, else the item's, its task and session, the lowest free slot, and the command
# sessions_command would type there.
reopen_report() {
  local repo=$REOPEN_REPO n=1 would=false delivered=null items='[]' name='' task='' session='' slot='' command=''
  local head=null
  if [[ -n $REOPEN_HOLDER ]]; then
    items=$(contract_json -c .items <<<"$REOPEN_SOURCE")
    name=$(contract_json -r '.name // ""' <<<"$REOPEN_SOURCE")
    session=$(contract_json -r '.session_id // ""' <<<"$REOPEN_SOURCE")
    [[ -z $REOPEN_EXISTING ]] || slot=$REOPEN_HOLDER
  elif [[ $REOPEN_SOURCE != null ]]; then
    items=$(contract_json -c --argjson i "$REOPEN_ITEM" '(.items // [])
      | if any(.[]; .kind == $i.kind and .repo == $i.repo and .number == $i.number) then . else . + [$i] end' \
      <<<"$REOPEN_SOURCE")
    name=$(contract_json -r '.name // ""' <<<"$REOPEN_SOURCE")
    [[ -n $name ]] || name=$(item_name "$(contract_json -c '.[0]' <<<"$items")")
    task=$(contract_json -r '.task // ""' <<<"$REOPEN_SOURCE")
    session=$(contract_json -r '.session_id // ""' <<<"$REOPEN_SOURCE")
    while slot_taken "$repo" "$n"; do n=$((n + 1)); done
    slot=$(slot_key "$repo" "$n")
    head_plan "$REOPEN_SOURCE" "$ITEM"
    head=$HEAD_PLAN
    RECORD=$(contract_json -n -c --arg session "$session" --arg name "$name" --arg task "$task" \
      --arg prompt "${REOPEN_PROMPT:+$(slot_prompt_file "$(slot_path "$repo" "$n")")}" '
      {session_id: $session, name: $name, task: (if $task == "" then null else $task end),
       prompt_file: (if $prompt == "" then null else $prompt end)}')
    command=$(sessions_command "$repo" "$n" claude resume)
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

_reopen_item_key() { printf '%s#%s' "$ITEM_REPO" "$ITEM_NUMBER"; }

# The reopen's command line without --dry-run, for a refusal's next step.
_reopen_command() {
  local -a argv=(agent-slot reopen "$REOPEN_REPO" "--$REOPEN_KIND" "$REOPEN_REF")
  [[ -z $REOPEN_SESSION ]] || argv+=(--session "$REOPEN_SESSION")
  [[ -z $REOPEN_PROMPT ]] || argv+=(--prompt-file "$REOPEN_PROMPT")
  [[ -z $REOPEN_REQUEST ]] || argv+=(--request-id "$REOPEN_REQUEST")
  contract_quote "${argv[@]}"
}

# A fresh start for the same item, the next step when there is nothing to reopen.
_reopen_launch_command() {
  contract_quote agent-slot launch "$REOPEN_REPO" "--$REOPEN_KIND" "$REOPEN_REF"
}
