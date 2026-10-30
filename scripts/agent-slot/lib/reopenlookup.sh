# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# What a reopen starts from. The source is a teardown event of the repo's slots in the ledger: the one --session names,
# else the newest whose work items hold the item, else, for a PR of origin's repo, the newest whose PRs hold its number,
# which covers slots torn down before work items were recorded. A reopen refuses while a slot holds the item or the
# source's session, while a Claude agent has that session open, and once Claude Code no longer has its transcript.
# launch reads the same source, reopen_source_event, to name the torn-down slot of an item it starts afresh.

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

# Usage: reopen_source_event <repo> <item> [<session id>]; prints the teardown event of a slot of the repo that a reopen
# of the {kind, repo, number} item starts from, or null: the one with that session ID when one is given, else the
# newest match. Each match is ranked, 2 for an event whose items hold the item and 1 for one whose PRs hold an origin
# PR's number, and the last line of the highest rank is the newest. The ledger is read line by line, so a line that is
# not JSON is skipped. The caller has run repo_prime.
reopen_source_event() {
  { [[ ! -r $AS_LEDGER ]] || contract_json -c -R --arg repo "$1" --argjson i "$2" --arg session "${3:-}" \
    --arg origin "$(pr_repo_slug "$REPO_ORIGIN")" '
    fromjson? | select(type == "object" and .event == "teardown" and .repo == $repo)
    | if $session != "" then select(.session_id == $session) | [0, .]
      elif any(.items[]?; .kind == $i.kind and .repo == $i.repo and .number == $i.number) then [2, .]
      elif $i.kind == "pr" and $i.repo == $origin and any(.prs[]?; . == $i.number) then [1, .]
      else empty end' "$AS_LEDGER"; } \
    | contract_json -s -c 'if length == 0 then null
      else (map(.[0]) | max) as $r | map(select(.[0] == $r)) | last | .[1] end'
}

# Sets REOPEN_SOURCE to the source teardown event, or refuses with item-not-found-in-ledger and returns 1.
_reopen_source() {
  local repo=$1 key
  key=$(_reopen_item_key)
  REOPEN_SOURCE=$(reopen_source_event "$repo" "$REOPEN_ITEM" "$REOPEN_SESSION")
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

_reopen_item_key() { printf '%s#%s' "$ITEM_REPO" "$ITEM_NUMBER"; }
