# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# What the automatic sweep (`sweep --yes --auto`, which agent-slot-sweep.timer runs) does with a finished slot that
# neither its agent released nor the operator finished. It tears none down, so no slot disappears before its learnings
# are recorded: an idle agent is typed its closing steps once, and a slot whose agent is gone, or that its agent did not
# release after those steps, joins the needs-you list as not-released.
#
# An agent that ran `release --not-yet WHY` holds the slot off the needs-you list while it is there. Once it is idle
# and that record is AS_RELEASE_REMIND seconds old, it is typed a reminder, once. A reminder the agent answers with
# neither a release nor a new --not-yet ends the hold, and the slot is listed as before.

RELEASE_AUTO=

# Usage: release_send <repo> <n> <text>; types one line into the slot's Claude session and submits it.
release_send() {
  local name out
  name=$(slot_session "$1" "$2")
  slot_tmux out 10 send-keys -t "=$name:" -l "$3" || return 1
  slot_tmux out 10 send-keys -t "=$name:" Enter
}

# Usage: release_send_closing <repo> <n>; types the closing steps into the slot's Claude session and records when.
release_send_closing() {
  release_send "$1" "$2" "$RELEASE_CLOSING" || return 1
  record_update "$1" "$2" --arg at "$(contract_now)" '.closing_sent_at = $at'
}

# Usage: release_hold <repo> <n>; true while the agent's --not-yet record holds a finished slot: the agent is there and
# has left no reminder unanswered. Keeps the slot, off the needs-you list, and sets RELEASE_AUTO to reminded when it
# typed the reminder, or not-yet.
release_hold() {
  local repo=$1 n=$2 age why at
  [[ $AGENT_STATE != absent ]] || return 1
  contract_json -e '.not_yet.at != null and .not_yet.reminded_at == null' <<<"$RECORD" >/dev/null || return 1
  CHECK_VERDICT=$(contract_json -c '.teardown = false | .needs_you = []' <<<"$CHECK_VERDICT")
  RELEASE_AUTO=not-yet
  [[ $AGENT_STATE == idle ]] || return 0
  age=$(contract_json -r '(now - (.not_yet.at | fromdateiso8601)) | floor' <<<"$RECORD") || return 0
  ((age >= AS_RELEASE_REMIND)) || return 0
  why=$(contract_json -r .not_yet.why <<<"$RECORD")
  release_send "$repo" "$n" "You said this slot was not ready to release: $why. If that still holds, say so again \
with $RELEASE_NOT_YET. Otherwise: $RELEASE_CLOSING" || return 0
  at=$(contract_now)
  record_update "$repo" "$n" --arg at "$at" \
    '.not_yet.reminded_at = $at | .closing_sent_at = (.closing_sent_at // $at)' || true
  RELEASE_AUTO=reminded
}

# Usage: release_auto_gate <repo> <n>; after check_slot. Keeps a finished slot check would let go when neither its agent
# released it nor the operator finished it, setting RELEASE_AUTO to closing-sent, reminded, not-yet, or not-released.
release_auto_gate() {
  local repo=$1 n=$2 sent why blocker reminded
  RELEASE_AUTO=
  [[ $(contract_json -r .finished <<<"$CHECK_VERDICT") == true ]] || return 0
  ! contract_json -e '.release != null or .finished_by_operator == true' <<<"$RECORD" >/dev/null || return 0
  ! release_hold "$repo" "$n" || return 0
  [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") == true ]] || return 0
  sent=$(contract_json -r '.closing_sent_at // ""' <<<"$RECORD")
  if [[ $AGENT_STATE == idle && -z $sent ]] && release_send_closing "$repo" "$n"; then
    RELEASE_AUTO=closing-sent
    CHECK_VERDICT=$(contract_json -c '.teardown = false' <<<"$CHECK_VERDICT")
    return 0
  fi
  reminded=$(contract_json -r '.not_yet.reminded_at // ""' <<<"$RECORD")
  if [[ $AGENT_STATE == absent ]]; then
    why="its agent is gone, so nothing will release it; finish it with agent-slot finish $(slot_key "$repo" "$n") --yes"
  elif [[ -n $reminded ]]; then
    why="its agent said it was not ready ($(contract_json -r .not_yet.why <<<"$RECORD")), was reminded at $reminded, \
and has neither released it nor said why again"
  elif [[ -n $sent ]]; then
    why="its agent was sent the closing steps at $sent and has not released it"
  else
    why="its closing steps could not be typed into its Claude session"
  fi
  CHECK_BLOCKERS=()
  _check_block not-released "the task has finished, but $why"
  blocker=${CHECK_BLOCKERS[0]}
  RELEASE_AUTO=not-released
  CHECK_VERDICT=$(contract_json -c --argjson b "$blocker" \
    '.teardown = false | .blockers += [$b] | .needs_you += [$b]' <<<"$CHECK_VERDICT")
}
