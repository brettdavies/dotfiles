# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Tearing down a slot, and sweep: deleting only the slots check passes. sweep, like finish in finish.sh, reports what it
# would do unless given --yes.
#
# A teardown deletes the slot's clone. Under the slot's lock, in order, it marks the slot tearing-down, reads the agent's
# state again, stops the agent, checks the tree again, kills its three tmux sessions, moves the clone to the trash, and
# appends the ledger, which names the clone's trash entry. A check that fails marks the slot active again with its
# sessions intact, so nothing written into the slot after the verdict is lost, and so does a teardown that stops before
# the trash: through its exit handler, or, when it was killed, through the next process that takes the slot lock. Then
# it releases the lock and purges that entry from the trash (purge.sh). A purge that fails leaves the slot torn down
# and is reported in the result, a purge ledger event, and teardown.log.

TEARDOWN_BLOCKERS='[]'
TEARDOWN_ARMED=

# Usage: _teardown_recheck <repo> <n>; the tree checks again, now that the agent has stopped.
_teardown_recheck() {
  local repo=$1 n=$2 path
  path=$(slot_path "$repo" "$n")
  CHECK_BLOCKERS=()
  _check_uncommitted "$path"
  _check_stash "$path"
  _check_commits "$path" "$(contract_json -r '.base // "main"' <<<"$RECORD")" \
    "$(contract_json '.prs // [] | length' <<<"$RECORD")"
  _check_files "$path"
  ((${#CHECK_BLOCKERS[@]} == 0))
}

# Usage: _teardown_keep <repo> <n>; marks the slot active again with the blockers in CHECK_BLOCKERS.
_teardown_keep() {
  TEARDOWN_ARMED=
  TEARDOWN_BLOCKERS=$(printf '%s\n' "${CHECK_BLOCKERS[@]}" | contract_json -s -c 'map(select(. != null))')
  record_update "$1" "$2" --argjson b "$TEARDOWN_BLOCKERS" --arg at "$(contract_now)" \
    '.state = "active" | .last_check = {at: $at, finished: true, blockers: $b}'
}

_teardown_disarm_on_exit() {
  [[ -n $TEARDOWN_ARMED ]] || return 0
  record_update "${TEARDOWN_ARMED%/*}" "${TEARDOWN_ARMED##*/}" '.state = "active"'
}

# Usage: teardown_recover <repo> <n>; the caller holds the slot lock. A tearing-down record whose lock was free belongs
# to a teardown that died before its trash, so the slot is marked active again and judged afresh.
teardown_recover() {
  record_read "$1" "$2" || return 0
  [[ $(contract_json -r '.state // ""' <<<"$RECORD") == tearing-down ]] || return 0
  record_update "$1" "$2" '.state = "active"'
}

# Stops the slot's Claude and every process still below it, such as a background job it started. Every process gets
# SIGTERM before the wait, so they share one grace period.
_teardown_stop_agent() {
  local pid waited=0
  local -a claude pids
  read -ra claude <<<"$AGENT_PIDS"
  ((${#claude[@]} > 0)) || return 0
  mapfile -t pids < <(
    printf '%s\n' "${claude[@]}"
    agentstate_descendants "${claude[@]}"
  )
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do
    while kill -0 "$pid" 2>/dev/null && ((waited++ < 50)); do sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Usage: _teardown_branches <slot path> <base>; prints the slot's local branches other than the base as a JSON array of
# {name, oid, remote, url}: the remote each pushes to and its URL, or null for a branch with none. The ledger keeps them
# so the work can be checked out again from wherever it was pushed, a fork included, once the clone is gone.
_teardown_branches() {
  local name oid remote url
  while IFS=$'\t' read -r name oid remote; do
    [[ -n $name && $name != "$2" ]] || continue
    url=
    [[ -z $remote ]] || url=$(git -C "$1" config --get "remote.$remote.url" || true)
    contract_json -n -c --arg name "$name" --arg oid "$oid" --arg remote "$remote" --arg url "$url" \
      '{name: $name, oid: $oid, remote: (if $remote == "" then null else $remote end),
        url: (if $url == "" then null else $url end)}'
  done < <(git -C "$1" for-each-ref --format='%(refname:short)%09%(objectname)%09%(push:remotename)' refs/heads) \
    | contract_json -s -c .
}

# Usage: slot_teardown <repo> <n>
# Tears down a slot whose verdict passed; the caller holds its lock and the verdict's AGENT_PIDS. Once the clone is in
# the trash and the ledger, it releases the lock and purges the clone, setting PURGE_RESULT. Returns 1, with the slot
# still locked and active again and TEARDOWN_BLOCKERS set, when the re-check fails.
slot_teardown() {
  local repo=$1 n=$2 path real kind out branches
  path=$(slot_path "$repo" "$n")
  real=$(realpath -m "$path")
  if [[ $real != "$AS_ROOT_REAL/$repo/$n" ]]; then
    contract_fail slot-outside-root "$(slot_key "$repo" "$n") resolves to $real, outside $AS_ROOT_REAL" \
      --value "$real" --command "ls -l $path" --side-effects none
  fi
  record_update "$repo" "$n" '.state = "tearing-down"'
  TEARDOWN_ARMED=$repo/$n
  agentstate_load
  CHECK_BLOCKERS=()
  _check_agent "$repo" "$n"
  if ((${#CHECK_BLOCKERS[@]} > 0)); then
    _teardown_keep "$repo" "$n"
    return 1
  fi
  _teardown_stop_agent
  record_read "$repo" "$n"
  if ! _teardown_recheck "$repo" "$n"; then
    _teardown_keep "$repo" "$n"
    return 1
  fi
  branches=$(_teardown_branches "$path" "$(contract_json -r '.base // "main"' <<<"$RECORD")")
  for kind in "${SLOT_SESSION_KINDS[@]}"; do
    slot_tmux out 10 kill-session -t "=$(slot_session "$repo" "$n" "$kind")" || true
  done
  purge_before "$real"
  bounded out trash 120 "$AS_TRASH" "$path" \
    || contract_fail script-error "trash could not move $path to the trash" --value "$path" --side-effects partial \
      --reconcile "agent-slot list" --log "$BOUNDED_LOG"
  TEARDOWN_ARMED=
  purge_find
  ledger_append teardown "$(contract_json -c --argjson branches "$branches" \
    --arg entry "${PURGE_ENTRY:+$AS_TRASH_DIR/files/$PURGE_ENTRY}" '{repo, slot, task, session_id, transcript, prs,
      request_id, branches: $branches, trash_entry: (if $entry == "" then null else $entry end)}' <<<"$RECORD")"
  record_unlock_slot "$repo" "$n"
  purge_run "$repo" "$n"
}

# Usage: _teardown_one <repo> <n> <yes>; checks one slot and, with yes, tears it down. Sets TEARDOWN_RESULT to one of
# torn-down, would-tear-down, kept, busy, or, for the automatic sweep, closing-sent, cleanup-sent, reminded, or not-yet,
# with the verdict in CHECK_VERDICT.
TEARDOWN_RESULT=
_teardown_one() {
  local repo=$1 n=$2 yes=$3
  if ! record_lock_slot "$repo" "$n" --nowait; then
    CHECK_VERDICT=$(contract_json -n -c --arg key "$(slot_key "$repo" "$n")" '{key: $key, finished: false,
      teardown: false, blockers: [{code: "slot-busy", message: "another agent-slot process holds this slot"}],
      needs_you: [{code: "slot-busy", message: "another agent-slot process holds this slot"}]}')
    TEARDOWN_RESULT=busy
    return
  fi
  teardown_recover "$repo" "$n"
  check_slot "$repo" "$n"
  RELEASE_AUTO=
  [[ ${SWEEP_AUTO:-0} != 1 ]] || release_auto_gate "$repo" "$n"
  check_record "$repo" "$n"
  if [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") != true ]]; then
    TEARDOWN_RESULT=kept
    case $RELEASE_AUTO in closing-sent | cleanup-sent | reminded | not-yet) TEARDOWN_RESULT=$RELEASE_AUTO ;; esac
  elif [[ $yes != 1 ]]; then
    TEARDOWN_RESULT=would-tear-down
  elif slot_teardown "$repo" "$n"; then
    TEARDOWN_RESULT=torn-down
    CHECK_VERDICT=$(contract_json -c --argjson p "$PURGE_RESULT" '.purge = $p' <<<"$CHECK_VERDICT")
  else
    CHECK_VERDICT=$(contract_json -c --argjson b "$TEARDOWN_BLOCKERS" '.teardown = false | .blockers = $b
      | .needs_you = $b' <<<"$CHECK_VERDICT")
    TEARDOWN_RESULT=kept
  fi
  record_unlock_slot "$repo" "$n"
}

cmd_sweep() {
  local repo n results=() removed=() start out
  start=$(contract_ms)
  require_tools tmux claude gh trash
  contract_on_exit _teardown_disarm_on_exit
  check_inputs_load
  while read -r repo; do
    [[ -n $repo ]] || continue
    while read -r n; do
      [[ -n $n ]] || continue
      _teardown_one "$repo" "$n" "${SWEEP_YES:-0}"
      results+=("$(contract_json -c --arg r "$TEARDOWN_RESULT" '. + {result: $r}' <<<"$CHECK_VERDICT")")
      [[ $TEARDOWN_RESULT != torn-down ]] || removed+=("$(slot_key "$repo" "$n")")
    done < <(slot_numbers "$repo")
  done < <(slot_repos)
  ((${#removed[@]} == 0)) || push_clients sweep "${removed[@]}"
  out=$(printf '%s\n' "${results[@]}" | contract_json -s -c --argjson yes "${SWEEP_YES:-0}" '
    map(select(. != null)) as $r
    | {dry_run: ($yes != 1),
       torn_down: [$r[] | select(.result == "torn-down") | .key],
       purge_failed: [$r[] | select(.purge.purged == false) | .key],
       would_tear_down: [$r[] | select(.result == "would-tear-down") | .key],
       closing_sent: [$r[] | select(.result == "closing-sent") | .key],
       cleanup_sent: [$r[] | select(.result == "cleanup-sent") | .key],
       reminded: [$r[] | select(.result == "reminded") | .key],
       not_yet: [$r[] | select(.result == "not-yet") | .key],
       needs_you: [$r[] | select(.needs_you != []) | {key, needs_you}],
       slots: $r}')
  [[ ${SWEEP_YES:-0} != 1 ]] || teardown_log sweep "$(contract_json -c --arg by "$(_teardown_by)" \
    --argjson ms "$(($(contract_ms) - start))" '{by: $by, ms: $ms, torn_down,
      purges: [.slots[] | select(.purge != null) | {key} + .purge], closing_sent,
      cleanup_sent: [.slots[] | select(.result == "cleanup-sent") | {key, files: [.blockers[] | .values[]? // .message]}],
      reminded, not_yet, kept: [.slots[] | select(.result == "kept" or .result == "busy") | {key, blockers: [.blockers[].code]}]}' \
    <<<"$out")"
  contract_ok "$out" '
    (.torn_down[] | "torn down\t\(.)"), (.would_tear_down[] | "would tear down\t\(.)"),
    (.slots[] | select(.purge.purged == false)
      | "clone left in the trash\t\(.key)\t\(.purge.message); next: \(.purge.next_step.command)"),
    (.closing_sent[] | "sent the closing steps\t\(.)"), (.cleanup_sent[] | "asked its agent to clean up\t\(.)"),
    (.reminded[] | "reminded its agent\t\(.)"),
    (.not_yet[] | "not ready to release, its agent says\t\(.)"),
    (.needs_you[] | "needs you\t\(.key)\t\(.needs_you | map(.message) | join("; "))"),
    (if (.torn_down + .would_tear_down + .closing_sent + .cleanup_sent + .reminded + .not_yet + .needs_you
      | length) == 0
     then "nothing to tear down" else empty end)'
}

# What ran a sweep or finish, for teardown.log: the timer's automatic sweep, a release's finish, or the operator.
_teardown_by() {
  if [[ ${SWEEP_AUTO:-0} == 1 ]]; then
    echo timer
  elif [[ ${FINISH_WHEN_IDLE:-0} == 1 ]]; then
    echo release
  else
    echo operator
  fi
}
