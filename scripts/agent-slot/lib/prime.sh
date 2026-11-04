# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# A repo's prime: a slot's three tmux sessions, built by sessions_start, rooted at the repo's own checkout. It has no
# record and no slot number, so no verb that ends a slot can name it. Starting one touches neither git nor Claude's
# trust: the checkout keeps its branch and its local changes, and a person answers the trust dialog.

# The line Claude writes for a session's title. A transcript quoting one in a tool result holds it JSON-escaped, never at
# a line's start. Claude does not document this format, so this is the one place that knows it.
PRIME_TITLE_LINE='{"type":"custom-title","customTitle":"'

# Usage: _prime_old_session <repo>; sets PRIME_OLD to the session on the default tmux server that holds the repo's prime,
# else to nothing.
PRIME_OLD=
_prime_old_session() {
  local repo=$1 status=0 session held
  PRIME_OLD=
  default_tmux_panes || status=$?
  ((status != 124)) || tmux_unresponsive none "$TMUX_DEFAULT_SOCKET"
  if ((status != 0)); then
    contract_use_tools tmux
    contract_fail tmux-failed "tmux list-panes on the $TMUX_DEFAULT_SOCKET server exited $status" \
      --value "$TMUX_DEFAULT_SOCKET" --command "agent-slot prime $repo" --log "$BOUNDED_LOG"
  fi
  session=$(tmux_name "$(prime_display_name "$repo" "$AS_PRIMES")")
  held=$(prime_old_sessions <<<"$DEFAULT_PANES")
  ! grep -qxF -- "$session" <<<"$held" || PRIME_OLD=$session
}

# Usage: _prime_scan_fail <repo> <what failed>; a start never chooses a fresh conversation blind, since one may exist.
_prime_scan_fail() {
  local cause=''
  [[ -z $BOUNDED_LOG ]] || cause=$(awk 'seen && NF { last = $0 } /^--- stderr$/ { seen = 1 } END { print last }' "$BOUNDED_LOG")
  contract_fail script-error "$2: ${cause:-no error output, exit $BOUNDED_STATUS}, so no conversation could be chosen and nothing started" \
    --value "$(slot_key "$1" "$SLOT_PRIME")" --command "agent-slot prime $1" --log "$BOUNDED_LOG"
}

# Usage: _prime_conversation <repo>; sets PRIME_MODE to resumed or fresh and PRIME_SESSION_ID to the session Claude starts
# with: the newest transcript, in any of Claude's project directories, whose latest title is exactly the prime's name and
# whose session no running Claude holds, else a new ID. The newest wins because /clear starts a new transcript that keeps
# the title. Every project directory counts because a conversation resumed elsewhere stays in the file it started in.
PRIME_MODE=
PRIME_SESSION_ID=
_prime_conversation() {
  local repo=$1 out titled held path id best=''
  PRIME_MODE=fresh
  PRIME_SESSION_ID=$(session_new_id)
  [[ -d $AS_CLAUDE_PROJECTS ]] || return 0
  # grep exits 1 for a batch holding no title, which is no failure, and 2 for a file it cannot read. A transcript can hold
  # bytes that make grep call it binary and print no line.
  # shellcheck disable=SC2016 # the inner shell expands these
  bounded out prime-titles 30 "$AS_FIND" "$AS_CLAUDE_PROJECTS" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
    -exec sh -c 'LC_ALL=C grep -aH -e "$0" -- "$@"; [ $? -lt 2 ]' "^$PRIME_TITLE_LINE" {} + \
    || _prime_scan_fail "$repo" "reading the titles in $AS_CLAUDE_PROJECTS failed"
  titled=$(awk -v line=":$PRIME_TITLE_LINE" -v want="$(prime_claude_name "$repo")\"" '
    (at = index($0, line)) { latest[substr($0, 1, at - 1)] = substr($0, at + length(line)) }
    END { for (file in latest) if (index(latest[file], want) == 1) print file }' <<<"$out")
  [[ -n $titled ]] || return 0
  agentstate_agents
  ((AGENTS_OK == 1)) || _prime_scan_fail "$repo" "claude agents --json, which says which conversations are held, failed"
  held=$(contract_json -r '.[].sessionId // empty' <<<"$AGENTS_JSON")
  while IFS= read -r path; do
    id=${path##*/}
    id=${id%.jsonl}
    # Claude names a transcript by its session's UUID. Any other name reaches its command line as an argument.
    [[ $id =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] || continue
    ! grep -qxF -- "$id" <<<"$held" || continue
    [[ -n $best && ! $path -nt $best ]] || best=$path
  done <<<"$titled"
  [[ -n $best ]] || return 0
  id=${best##*/}
  PRIME_MODE=resumed PRIME_SESSION_ID=${id%.jsonl}
}

# Usage: prime_start <repo>
# The one way a prime starts. Creates whichever of its sessions are missing, unless a session on the default server
# already holds it, and sets PRIME_JSON to what it found and SESSIONS_CREATED to what it made. Sessions are read under
# the lock, so two callers never race. The lock stays out of the slot root because doctor reads every directory there as
# a repo with slots. The checkout comes from the repo's name, never from a slot's record, which the slot's agent can write.
PRIME_JSON=
prime_start() {
  local repo=$1 path key name session server=slots mode=running id='' trust=false started
  local -a bus=()
  key=$(slot_key "$repo" "$SLOT_PRIME")
  name=$(prime_claude_name "$repo")
  session=$(slot_session "$repo" "$SLOT_PRIME")
  started=$(_slot_us)
  SESSIONS_CREATED=()
  repo_prime "$repo"
  path=$REPO_PRIME
  _record_lock "$AS_STATE_DIR/primes/$repo.lock" "prime:$repo" --wait "$AS_LOCK_WAIT" \
    || contract_fail slot-busy "$key stayed locked for $AS_LOCK_WAIT s" --value "$key" --command "agent-slot prime $repo"
  _prime_old_session "$repo"
  if [[ -n $PRIME_OLD ]]; then
    server=default session=$PRIME_OLD
  else
    slot_sessions_or_fail
    if ! grep -qxF -- "$session" <<<"$SLOT_SESSIONS"; then
      _prime_conversation "$repo"
      mode=$PRIME_MODE id=$PRIME_SESSION_ID
      trust_known "$path" || trust=true
    fi
    [[ ! -e $AS_USER_BUS ]] || bus=(-e "DBUS_SESSION_BUS_ADDRESS=unix:path=$AS_USER_BUS")
    RECORD=$(contract_json -n -c --arg name "$name" --arg id "$id" '{name: $name, session_id: $id, prompt_file: null}')
    sessions_start "$repo" "$SLOT_PRIME" resume "$path" "${bus[@]}"
  fi
  # An agent runs next_step.command, so it is never the pane's attach, which waits on a terminal.
  PRIME_JSON=$(printf '%s\n' "${SESSIONS_CREATED[@]}" | contract_json -R -s -c --arg key "$key" --arg repo "$repo" \
    --arg path "$path" --arg name "$name" --arg server "$server" --arg session "$session" --arg mode "$mode" \
    --arg id "$id" --argjson trust "$trust" --arg docs "$CONTRACT_DOCS" '
    {key: $key, repo: $repo, path: $path, name: $name, server: $server, session: $session,
     started: (split("\n") | map(select(. != ""))),
     conversation: {mode: $mode, session_id: (if $id == "" then null else $id end)},
     trust_prompt_expected: $trust,
     next_step: {action: "run", command: "agent-slot list --output json", docs: $docs,
                 note: "other sessions reach it by the name \($name); a terminal holds it with agent-slot-rex prime \($repo)"}}')
  ((${#SESSIONS_CREATED[@]} == 0)) || ledger_append prime-start "$(contract_json -c --argjson from "$started" \
    --argjson to "$(_slot_us)" '{repo, key, path, started, conversation: .conversation.mode,
      session_id: .conversation.session_id, started_at: ($from / 1000000), made_at: ($to / 1000000)}' <<<"$PRIME_JSON")"
  _record_unlock "prime:$repo"
}

# Usage: prime_list; sets PRIME_LIST to the running primes as [{key, repo, server, session, label}], one per repo, the
# old-style one when both run, and only for a repo with a checkout here. An old-style session is named by the map, or by
# its own repo when the map gives that repo no other name. A server that does not answer costs only its own rows, since
# the list's callers only open tabs from it, and a slot's state must still reach them.
PRIME_LIST='[]'
prime_list() {
  local out name path repo rows=''
  local -A seen=()
  if default_tmux_panes; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      repo=$(awk -F '\t' -v name="$name" '!/^#/ && NF == 2 && $2 == name { print $1; exit }' "$AS_PRIMES")
      repo=${repo:-$name}
      [[ $(prime_display_name "$repo" "$AS_PRIMES") == "$name" ]] || continue
      repo_lookup "$repo" || continue
      seen[$repo]=1
      rows+=$repo$'\t'$TMUX_DEFAULT_SOCKET$'\t'$name$'\t'$name$'\n'
    done < <(prime_old_sessions <<<"$DEFAULT_PANES")
  fi
  if slot_tmux out 5 -u list-sessions -F $'#{session_name}\t#{session_path}'; then
    while IFS=$'\t' read -r name path; do
      repo=${path##*/}
      [[ -n $repo && -z ${seen[$repo]:-} && $name == "$(slot_session "$repo" "$SLOT_PRIME")" ]] || continue
      repo_lookup "$repo" || continue
      rows+=$repo$'\tslots\t'$name$'\t'$(prime_display_name "$repo" "$AS_PRIMES")$'\n'
    done <<<"$out"
  elif ((BOUNDED_STATUS != 124)); then
    tmux_no_server || true
  fi
  PRIME_LIST=$(contract_json -R -s -c --arg prime "$SLOT_PRIME" 'split("\n") | map(select(. != "") | split("\t")
    | {key: "\(.[0])/\($prime)", repo: .[0], server: .[1], session: .[2], label: .[3]})' <<<"$rows")
}

# Usage: prime_for_slot <repo>
# Starts a slot's prime, and sets PRIME_FIELD to the prime field of the slot verb's output: what prime_start found, else
# {error: {reason, exit_code, message, value, next_step, recovery, log}}. A subshell keeps contract_fail, RECORD, and the exit traps away from the
# slot, since bash resets traps in one, so a prime that fails to start never costs the slot. It runs in the background
# because a subshell whose status is tested runs with errexit off.
PRIME_FIELD=null
prime_for_slot() {
  local repo=$1 out err status=0 failure log
  out=$(mktemp) err=$(mktemp)
  (
    CONTRACT_OUTPUT=json CONTRACT_NOISE=$err
    trap 'printf "stopped at: %s\n" "${CONTRACT_LAST_FAILURE:-unknown}" >&2' EXIT
    prime_start "$repo"
    printf '%s\n' "$PRIME_JSON"
  ) >"$out" 2>>"$err" </dev/null &
  wait "$!" || status=$?
  if ((status == 0)); then
    PRIME_FIELD=$(<"$out")
  else
    failure=$(grep '^{' "$err" | tail -1 || true)
    if [[ -z $failure ]]; then
      mkdir -p "$AS_LOG_DIR"
      log="$AS_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-prime-start.log"
      cp "$err" "$log"
      failure=$(contract_error_json script-error "the start of the prime of $repo stopped unexpectedly (exit $status)" \
        --value "$repo" --command "agent-slot prime $repo" --log "$log")
    fi
    PRIME_FIELD=$(contract_json -c '{error: {reason, exit_code, message, value, next_step, recovery, log}}' <<<"$failure")
  fi
  rm -f "$out" "$err"
}

cmd_prime() {
  local repo=$1
  require_tools tmux claude find
  prime_start "$repo"
  ((${#SESSIONS_CREATED[@]} == 0)) || push_restore prime "$(slot_key "$repo" "$SLOT_PRIME")"
  contract_ok "$PRIME_JSON" '"\(.key): " + (
    if .server == "default" then
      "runs in \(.session) on the default tmux server; close that session to rebuild it on the slot server"
    elif (.started | length) == 0 then "already running"
    else "started \(.started | join(", "))" + (
      if .conversation.mode == "resumed" then ", resuming \(.conversation.session_id)"
      elif .conversation.mode == "fresh" then ", as new conversation \(.conversation.session_id)"
      else "" end)
    end) + (if .trust_prompt_expected then "; Claude will ask to trust the folder" else "" end)'
}
