# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# finish: the operator's way to end a task that has no open PR, and the teardown a release starts. With --yes it marks
# the task finished and tears its slot down when check passes; --when-idle first waits for the slot's agent to go idle.
# Every finish --yes appends its outcome to teardown.log, with what ran it.

# Usage: _finish_refuse <key> <reason> <message> [options]; logs a refused finish --yes, then fails as contract_fail.
_finish_refuse() {
  local key=$1
  shift
  [[ ${FINISH_YES:-0} != 1 ]] || teardown_log finish "$(contract_json -n -c --arg key "$key" --arg by "$(_teardown_by)" \
    --arg reason "$1" --arg m "$2" '{key: $key, by: $by, result: "refused", reason: $reason, message: $m}')"
  contract_fail "$@"
}

cmd_finish() {
  local key=$1 repo n retry
  slot_parse_key "$key"
  repo=$SLOT_REPO n=$SLOT_N
  retry="agent-slot finish $key"
  [[ ${FINISH_YES:-0} != 1 ]] || retry+=" --yes"
  require_tools tmux claude gh trash
  contract_on_exit _teardown_disarm_on_exit
  slot_taken "$repo" "$n" \
    || _finish_refuse "$key" slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  if [[ ${FINISH_WHEN_IDLE:-0} == 1 ]] && ! release_wait_idle "$repo" "$n"; then
    _finish_refuse "$key" teardown-blocked "the agent of $key stayed $AGENT_STATE for $AS_RELEASE_WAIT s; the automatic \
sweep tears the slot down once it is idle" --value "$key" --command "agent-slot check $key"
  fi
  check_inputs_load
  record_lock_slot "$repo" "$n" "$([[ ${FINISH_WHEN_IDLE:-0} == 1 ]] && echo --wait || echo --nowait)" "$AS_LOCK_WAIT" \
    || _finish_refuse "$key" slot-busy "another agent-slot process holds $key" --value "$key" --command "$retry"
  teardown_recover "$repo" "$n"
  check_slot "$repo" "$n"
  if contract_json -e 'any(.blockers[]; .code == "pr-state-unknown")' <<<"$CHECK_VERDICT" >/dev/null; then
    _finish_refuse "$key" pr-state-unknown "gh could not read the PRs of $key, so an open one cannot be ruled out" \
      --value "$key" --command "$retry"
  fi
  if contract_json -e 'any(.prs[]; .state == "OPEN")' <<<"$CHECK_VERDICT" >/dev/null; then
    _finish_refuse "$key" task-has-open-pr "$key has an open PR: $(contract_json -r '[.prs[] | select(.state == "OPEN")
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
    _finish_refuse "$key" teardown-blocked "$key is finished but kept: $(contract_json -r '.blockers | map(.message)
      | join("; ")' <<<"$CHECK_VERDICT")" --value "$key" --command "agent-slot check $key"
  fi
  if ! slot_teardown "$repo" "$n"; then
    _finish_refuse "$key" teardown-blocked "$key changed before it could be deleted, so it was kept: $(contract_json -r \
      'map(.message) | join("; ")' <<<"$TEARDOWN_BLOCKERS")" --value "$key" --command "agent-slot check $key"
  fi
  record_unlock_slot "$repo" "$n"
  teardown_log finish "$(contract_json -n -c --arg key "$key" --arg by "$(_teardown_by)" \
    --argjson waited "$RELEASE_WAITED" '{key: $key, by: $by, result: "torn-down", waited_s: $waited}')"
  push_clients finish "$key"
  contract_ok "$(contract_json -n -c --arg key "$key" '{key: $key, torn_down: true}')" '"\(.key): torn down"'
}
