# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# finish: the operator's finish key. The key opens a tab in the agent-slots control session that runs the server's
# finish, so the teardown never closes the tab its own helper runs in; reconcile then closes the task's tab. A refusal,
# such as a task with an open PR, stays on screen until it has been read.

FINISH_KEY=

# Usage: finish_key_of <session-id> <block-id>; sets FINISH_KEY to the slot of the tab that holds the block, or ''.
finish_key_of() {
  local wid
  rex_window_of "$1" "$2"
  wid=$REX_OUT
  rex_snapshot
  FINISH_KEY=$(contract_json -r --arg s "$1" --arg w "$wid" --arg key "$SLOT_KEY_PATTERN" '
    ([.[] | select(.session_id == $s and .window_id == $w)][0] // {}) as $tab
    | (first($tab.commands[]? | capture("agent-slot-rex attach (?<k>" + $key + ") ").k)
       // (($tab.label // "") | capture("^(?<k>" + $key + ")( |$)").k)
       // "")' <<<"$REX_TABS")
}

# Usage: cmd_finish_tab <session-id> <block-id>
cmd_finish_tab() {
  contract_use_tools rex
  finish_key_of "$1" "$2"
  [[ -n $FINISH_KEY ]] || ar_fail "$(contract_error_json usage "the focused tab is not an agent slot's tab" \
    --value "$2" --command "agent-slot-rex finish <repo>/<N>")"
  rex_open_tab "$AR_CONTROL" "finish $FINISH_KEY" "$AR_SELF" finish "$FINISH_KEY"
  contract_ok "$(contract_json -n -c --arg k "$FINISH_KEY" --arg s "$REX_NEW_SESSION" --arg w "$REX_NEW_WINDOW" \
    '{key: $k, session_id: $s, window_id: $w}')" '"finishing \(.key) in a tab of the agent-slots session"'
}

# Usage: cmd_finish <repo>/<N>
cmd_finish() {
  local key=$1 error
  contract_use_tools rex ssh
  reconcile_hold_on_error
  if ! server_call 300 finish "$key" --yes; then
    error=$AR_ERROR
    ((SERVER_STATUS == 255 || SERVER_STATUS == 124)) || reconcile
    ar_fail "$error"
  fi
  reconcile
  contract_ok "$(contract_json -c --arg k "$key" '{key: $k, torn_down: true, reconcile: .}' <<<"$RECONCILE_RESULT")" '
    "\(.key) is torn down", (.reconcile.closed[] | "closed: \(.label) (\(.why))")'
}
