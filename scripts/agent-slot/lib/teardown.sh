# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# sweep and finish: deleting only the slots check passes. Both report what they would do unless given --yes.
#
# A teardown runs under the slot's lock, in order: mark the slot tearing-down, stop its agent, check the tree again,
# kill its three tmux sessions, move the clone to the trash, and append the ledger. A re-check that fails marks the
# slot active again with its sessions intact, so nothing written into the slot after the verdict is lost.

TEARDOWN_BLOCKERS='[]'

# Usage: _teardown_recheck <repo> <n>; the tree checks again, now that the agent has stopped.
_teardown_recheck() {
  local repo=$1 n=$2 path out
  path=$(slot_path "$repo" "$n")
  CHECK_BLOCKERS=()
  if out=$(git -C "$path" status --porcelain=v1 --untracked-files=no) && [[ -n $out ]]; then
    _check_block uncommitted-changes "$(_check_plural "$(grep -c . <<<"$out")" "uncommitted change")"
  fi
  if out=$(git -C "$path" stash list) && [[ -n $out ]]; then
    _check_block stash-present "$(_check_plural "$(grep -c . <<<"$out")" "stash entry" "stash entries")"
  fi
  _check_commits "$path" "$(contract_json -r '.base // "main"' <<<"$RECORD")" \
    "$(contract_json '.prs // [] | length' <<<"$RECORD")"
  _check_files "$path"
  TEARDOWN_BLOCKERS=$(printf '%s\n' "${CHECK_BLOCKERS[@]}" | contract_json -s -c 'map(select(. != null))')
  [[ $TEARDOWN_BLOCKERS == '[]' ]]
}

_teardown_stop_agent() {
  local pid waited=0
  for pid in $AGENT_PIDS; do
    kill -TERM "$pid" 2>/dev/null || continue
    while kill -0 "$pid" 2>/dev/null && ((waited++ < 50)); do sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Usage: slot_teardown <repo> <n>
# Tears down a slot whose verdict passed; the caller holds its lock and the verdict's AGENT_PIDS. Returns 1, with the
# slot active again and TEARDOWN_BLOCKERS set, when the re-check fails.
slot_teardown() {
  local repo=$1 n=$2 path real base suffix out
  path=$(slot_path "$repo" "$n")
  real=$(realpath -m "$path")
  if [[ $real != "$AS_ROOT_REAL/$repo/$n" ]]; then
    contract_fail slot-outside-root "$(slot_key "$repo" "$n") resolves to $real, outside $AS_ROOT_REAL" \
      --value "$real" --command "ls -l $path" --side-effects none
  fi
  record_update "$repo" "$n" '.state = "tearing-down"'
  _teardown_stop_agent
  record_read "$repo" "$n"
  if ! _teardown_recheck "$repo" "$n"; then
    record_update "$repo" "$n" --argjson b "$TEARDOWN_BLOCKERS" --arg at "$(contract_now)" \
      '.state = "active" | .last_check = {at: $at, finished: true, blockers: $b}'
    return 1
  fi
  base=$(slot_session "$repo" "$n")
  for suffix in '' -files -git; do
    slot_tmux out 10 kill-session -t "=$base$suffix" || true
  done
  bounded out trash 120 "$AS_TRASH" "$path" \
    || contract_fail script-error "trash could not move $path to the trash" --value "$path" --side-effects partial \
      --reconcile "agent-slot list" --log "$BOUNDED_LOG"
  ledger_append teardown "$(contract_json -c '{repo, slot, task, session_id, transcript, prs, request_id}' <<<"$RECORD")"
}

# Usage: _teardown_one <repo> <n> <yes>; checks one slot and, with yes, tears it down. Sets TEARDOWN_RESULT to one of
# torn-down, would-tear-down, kept, or busy, with the verdict in CHECK_VERDICT.
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
  check_slot "$repo" "$n"
  check_record "$repo" "$n"
  if [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") != true ]]; then
    TEARDOWN_RESULT=kept
  elif [[ $yes != 1 ]]; then
    TEARDOWN_RESULT=would-tear-down
  elif slot_teardown "$repo" "$n"; then
    TEARDOWN_RESULT=torn-down
  else
    CHECK_VERDICT=$(contract_json -c --argjson b "$TEARDOWN_BLOCKERS" '.teardown = false | .blockers = $b
      | .needs_you = $b' <<<"$CHECK_VERDICT")
    TEARDOWN_RESULT=kept
  fi
  record_unlock_slot "$repo" "$n"
}

cmd_sweep() {
  local repo n results=()
  require_tools tmux claude gh trash
  check_inputs_load
  while read -r repo; do
    [[ -n $repo ]] || continue
    while read -r n; do
      [[ -n $n ]] || continue
      _teardown_one "$repo" "$n" "${SWEEP_YES:-0}"
      results+=("$(contract_json -c --arg r "$TEARDOWN_RESULT" '. + {result: $r}' <<<"$CHECK_VERDICT")")
    done < <(slot_numbers "$repo")
  done < <(slot_repos)
  contract_ok "$(printf '%s\n' "${results[@]}" | contract_json -s -c --argjson yes "${SWEEP_YES:-0}" '
    map(select(. != null)) as $r
    | {dry_run: ($yes != 1),
       torn_down: [$r[] | select(.result == "torn-down") | .key],
       would_tear_down: [$r[] | select(.result == "would-tear-down") | .key],
       needs_you: [$r[] | select(.needs_you != []) | {key, needs_you}],
       slots: $r}')" '
    (.torn_down[] | "torn down\t\(.)"), (.would_tear_down[] | "would tear down\t\(.)"),
    (.needs_you[] | "needs you\t\(.key)\t\(.needs_you | map(.message) | join("; "))"),
    (if (.torn_down + .would_tear_down + .needs_you | length) == 0 then "nothing to tear down" else empty end)'
}

cmd_finish() {
  local key=$1 repo n
  slot_parse_key "$key"
  repo=$SLOT_REPO n=$SLOT_N
  require_tools tmux claude gh trash
  slot_taken "$repo" "$n" || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  check_inputs_load
  record_lock_slot "$repo" "$n" --nowait \
    || contract_fail slot-busy "another agent-slot process holds $key" --value "$key" --command "agent-slot finish $key --yes"
  check_slot "$repo" "$n"
  if contract_json -e 'any(.blockers[]; .code == "pr-state-unknown")' <<<"$CHECK_VERDICT" >/dev/null; then
    contract_fail pr-state-unknown "gh could not read the PRs of $key, so an open one cannot be ruled out" \
      --value "$key" --command "agent-slot finish $key --yes"
  fi
  if contract_json -e 'any(.prs[]; .state == "OPEN")' <<<"$CHECK_VERDICT" >/dev/null; then
    contract_fail task-has-open-pr "$key has an open PR: $(contract_json -r '[.prs[] | select(.state == "OPEN")
      | "#\(.number)"] | join(", ")' <<<"$CHECK_VERDICT"); merge or close it first" \
      --value "$(contract_json -r '[.prs[] | select(.state == "OPEN") | .url] | join(" ")' <<<"$CHECK_VERDICT")"
  fi
  if [[ ${FINISH_YES:-0} != 1 ]]; then
    record_unlock_slot "$repo" "$n"
    contract_ok "$(contract_json -c '{key, dry_run: true, would_tear_down: ((.blockers
      | map(select(.code != "pr-closed-unmerged")) | length) == 0), verdict: .}' <<<"$CHECK_VERDICT")" '
      if .would_tear_down then "\(.key): finish --yes would tear it down"
      else "\(.key): finish --yes would mark it finished, then keep it for: \(.verdict.blockers
        | map(select(.code != "pr-closed-unmerged")) | map(.message) | join("; "))" end'
    return
  fi
  record_update "$repo" "$n" '.finished_by_operator = true'
  check_slot "$repo" "$n"
  check_record "$repo" "$n"
  if [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") != true ]]; then
    contract_fail teardown-blocked "$key is finished but kept: $(contract_json -r '.blockers | map(.message)
      | join("; ")' <<<"$CHECK_VERDICT")" --value "$key" --command "agent-slot check $key"
  fi
  if ! slot_teardown "$repo" "$n"; then
    contract_fail teardown-blocked "$key changed before it could be deleted, so it was kept: $(contract_json -r \
      'map(.message) | join("; ")' <<<"$TEARDOWN_BLOCKERS")" --value "$key" --command "agent-slot check $key"
  fi
  record_unlock_slot "$repo" "$n"
  contract_ok "$(contract_json -n -c --arg key "$key" '{key: $key, torn_down: true}')" '"\(.key): torn down"'
}
