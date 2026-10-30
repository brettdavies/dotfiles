# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# finish: the operator's way to end a task, and the teardown a release starts. With --yes it marks the task finished
# and tears its slot down when check passes; a task with an open PR also needs --allow-open-pr, which a release never
# passes. --when-idle first waits for the slot's agent to go idle. The operator's finish marks the record
# finished_by_operator. A release's finish marks the release itself, so a later --not-yet withdraws the mark with the
# release, and it stands down once the record no longer holds its release. Every finish --yes appends its outcome to
# teardown.log, with what ran it and whether --allow-open-pr did.

# Usage: _finish_log <json-object>; one finish line in teardown.log.
_finish_log() {
  teardown_log finish "$(contract_json -c --arg by "$(_teardown_by)" --arg allow "${FINISH_ALLOW_OPEN_PR:-0}" \
    '{key, by: $by} + . + (if $allow == "1" then {allow_open_pr: true} else {} end)' <<<"$1")"
}

# Usage: _finish_refuse <key> <reason> <message> [options]; logs a refused finish --yes, then fails as contract_fail.
_finish_refuse() {
  local key=$1
  shift
  [[ ${FINISH_YES:-0} != 1 ]] || _finish_log "$(contract_json -n -c --arg key "$key" --arg reason "$1" --arg m "$2" \
    '{key: $key, result: "refused", reason: $reason, message: $m}')"
  contract_fail "$@"
}

# Usage: _finish_open_pr_need; the one judgment of whether the task's open PRs stop this finish, which finish --yes
# refuses on and the report-only run reports. Sets FINISH_OPEN_PRS to their numbers, empty when none is open, and
# FINISH_NEED to --allow-open-pr when one is open and the flag is absent.
_finish_open_pr_need() {
  FINISH_OPEN_PRS=$(contract_json -r '[.prs[] | select(.state == "OPEN") | "#\(.number)"] | join(", ")' \
    <<<"$CHECK_VERDICT")
  FINISH_NEED=
  [[ -z $FINISH_OPEN_PRS || ${FINISH_ALLOW_OPEN_PR:-0} == 1 ]] || FINISH_NEED=--allow-open-pr
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
  if release_withdrawn "$repo" "$n"; then
    _finish_refuse "$key" release-withdrawn "the release that started this finish was withdrawn by release --not-yet \
or replaced by a newer release, so $key was kept" --value "$key"
  fi
  teardown_recover "$repo" "$n"
  check_slot "$repo" "$n"
  if contract_json -e 'any(.blockers[]; .code == "pr-state-unknown")' <<<"$CHECK_VERDICT" >/dev/null; then
    _finish_refuse "$key" pr-state-unknown "gh could not read the PRs of $key, so an open one cannot be ruled out" \
      --value "$key" --command "$retry"
  fi
  _finish_open_pr_need
  if [[ -n $FINISH_NEED && ${FINISH_YES:-0} == 1 ]]; then
    _finish_refuse "$key" task-has-open-pr "$key has an open PR: $FINISH_OPEN_PRS; merge or close it first, or finish \
it anyway with --yes $FINISH_NEED" \
      --value "$(contract_json -r '[.prs[] | select(.state == "OPEN") | .url] | join(" ")' <<<"$CHECK_VERDICT")"
  fi
  if [[ ${FINISH_YES:-0} != 1 ]]; then
    record_unlock_slot "$repo" "$n"
    contract_ok "$(contract_json -c --arg need "$FINISH_NEED" '{key, dry_run: true, would_tear_down: ((.blockers
      | map(select(.code != "pr-closed-unmerged")) | length) == 0),
      would_need: (if $need == "" then null else $need end), verdict: .}' <<<"$CHECK_VERDICT")" '
      "\(.key): finish --yes\(if .would_need then " \(.would_need)" else "" end) would "
      + (if .would_tear_down then "tear it down"
         else "mark it finished, then keep it for: \(.verdict.blockers
           | map(select(.code != "pr-closed-unmerged")) | map(.message) | join("; "))" end)'
    return
  fi
  if [[ -n ${AGENT_SLOT_RELEASE_ID:-} ]]; then
    record_update "$repo" "$n" --arg at "$(contract_now)" '.release.finished_at = $at'
  else
    record_update "$repo" "$n" '.finished_by_operator = true'
  fi
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
  _finish_log "$(contract_json -n -c --arg key "$key" --argjson waited "$RELEASE_WAITED" --argjson purge "$PURGE_RESULT" \
    '{key: $key, result: "torn-down", waited_s: $waited, purge: $purge}')"
  push_clients finish "$key"
  contract_ok "$(contract_json -n -c --arg key "$key" --argjson purge "$PURGE_RESULT" \
    '{key: $key, torn_down: true, purge: $purge}')" '"\(.key): torn down",
    (.purge | select(.purged == false) | "  its clone is still in the trash: \(.message)", "  next: \(.next_step.command)")'
}
