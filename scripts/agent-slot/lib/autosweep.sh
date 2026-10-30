# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# What the automatic sweep (`sweep --yes --auto`, which agent-slot-sweep.timer runs) does with a finished slot that
# neither its agent released nor the operator finished. It tears none down, so no slot disappears before its learnings
# are recorded: an idle agent is typed its closing steps once, and a slot whose agent is gone, or that its agent did not
# release after those steps, joins the needs-you list as not-released.
#
# A finished slot kept only by files left in its tree is its agent's to clear, whether or not it was released: the idle
# agent is typed a reminder naming them, once, and the slot stays off the needs-you list while the agent is busy. It is
# listed when the agent is gone, or idle after the reminder with the files still there and no --not-yet saying why.
#
# An agent that ran `release --not-yet WHY` holds the slot off the needs-you list while it is there. Once it is idle
# and that record is AS_RELEASE_REMIND seconds old, it is typed a reminder, once. A reminder the agent answers with
# neither a release nor a new --not-yet ends the hold, and the slot is listed as before. A --not-yet withdraws any
# earlier release, so a slot counts as released only while its release is the newer of the two; the operator's finish
# holds whatever the agent says.
#
# Every slot the sweep keeps, finished or not, has its Claude session renamed to the record's name while the session
# carries another: an idle agent is typed /rename <name>, which Claude Code applies without a model turn, and the
# record's named_as says which name the session has. A pass that typed the agent anything else leaves the rename to
# the next pass, since an agent typed to in this pass is not known to be idle.

RELEASE_AUTO=
# The teardown blockers about files in the slot's tree, which its agent can clear itself.
RELEASE_FILE_CODES='untracked-files local-only-files uncommitted-changes'

# Usage: release_send <repo> <n> <text>; types one line into the slot's Claude session and submits it.
release_send() {
  local name out
  name=$(slot_session "$1" "$2")
  slot_tmux out 10 send-keys -t "=$name:" -l "$3" || return 1
  slot_tmux out 10 send-keys -t "=$name:" Enter
}

# Usage: release_rename <repo> <n>; after agentstate_of, under the slot's lock. Types /rename <name> into the slot's
# Claude session when its agent is idle and the record names the slot something other than named_as, then records
# named_as. Returns 1 when it typed nothing.
RELEASE_RENAMED=
release_rename() {
  local name
  [[ $AGENT_STATE == idle ]] || return 1
  record_read "$1" "$2" || return 1
  name=$(contract_json -r 'if .name != null and .name != .named_as then .name else "" end' <<<"$RECORD")
  [[ -n $name ]] || return 1
  release_send "$1" "$2" "/rename $name" || return 1
  record_update "$1" "$2" --arg name "$name" '.named_as = $name' || true
  RELEASE_RENAMED=$name
}

# Usage: release_rename_pass <repo> <n>; after check_record. Renames the session of an active slot the sweep keeps,
# unless this pass typed its agent something else, and sets the verdict's renamed to the name it typed.
release_rename_pass() {
  contract_json -e '.state == "active" and .teardown != true' <<<"$CHECK_VERDICT" >/dev/null || return 0
  case $RELEASE_AUTO in closing-sent | cleanup-sent | reminded) return 0 ;; esac
  release_rename "$1" "$2" || return 0
  CHECK_VERDICT=$(contract_json -c --arg name "$RELEASE_RENAMED" '.renamed = $name' <<<"$CHECK_VERDICT")
}

# Usage: release_send_closing <repo> <n>; types the closing steps into the slot's Claude session and records when.
release_send_closing() {
  release_send "$1" "$2" "$RELEASE_CLOSING" || return 1
  record_update "$1" "$2" --arg at "$(contract_now)" '.closing_sent_at = $at'
}

# Usage: release_files_only; true when the blockers in CHECK_VERDICT, leaving out the agent being busy, are all about
# files in the slot's tree.
release_files_only() {
  contract_json -e --arg codes "$RELEASE_FILE_CODES" --arg state "$AGENT_STATE" '($codes | split(" ")) as $f
    | [.blockers[] | select(.code != "agent-not-idle" or $state != "busy")] as $b
    | ($b | length) > 0 and all($b[]; .code as $c | any($f[]; . == $c))' <<<"$CHECK_VERDICT" >/dev/null
}

# Usage: release_cleanup_text; the reminder for a slot kept by files, naming them from CHECK_VERDICT.
release_cleanup_text() {
  local files
  files=$(contract_json -r '[.blockers[] | if .values then .values[] else .message end] as $f
    | ($f[:10] | join(", ")) + (if ($f | length) > 10 then ", and \(($f | length) - 10) more" else "" end)' \
    <<<"$CHECK_VERDICT")
  printf '%s' "This slot's task has finished, but its teardown is held by what is left in it: ${files//[$'\n\t']/ }. \
Delete each one that is scratch, such as local config, test output, or a tool log, and commit and PR each one that is \
real work; then close out and release as your closing steps say. If one of them cannot go yet, say why with \
$RELEASE_NOT_YET."
}

# Usage: release_cleanup <repo> <n>; for a finished slot kept only by files in its tree, keeps a busy agent's slot off
# the needs-you list, and types an idle agent the reminder once, setting RELEASE_AUTO to cleanup-sent.
release_cleanup() {
  local repo=$1 n=$2
  [[ $AGENT_STATE == idle || $AGENT_STATE == busy ]] || return 0
  release_files_only || return 0
  if [[ $AGENT_STATE == busy ]]; then
    CHECK_VERDICT=$(contract_json -c '.needs_you = []' <<<"$CHECK_VERDICT")
    return 0
  fi
  [[ -z $(contract_json -r '.cleanup_sent_at // ""' <<<"$RECORD") ]] || return 0
  release_send "$repo" "$n" "$(release_cleanup_text)" || return 0
  record_update "$repo" "$n" --arg at "$(contract_now)" '.cleanup_sent_at = $at' || true
  CHECK_VERDICT=$(contract_json -c '.needs_you = []' <<<"$CHECK_VERDICT")
  RELEASE_AUTO=cleanup-sent
}

# Usage: release_hold <repo> <n>; true while the agent's --not-yet record holds a finished slot: the agent is there and
# has left no reminder unanswered. Keeps the slot, off the needs-you list, and sets RELEASE_AUTO to reminded when it
# typed the reminder, or not-yet.
release_hold() {
  local repo=$1 n=$2 age why at sent text
  [[ $AGENT_STATE != absent ]] || return 1
  contract_json -e '.not_yet.at != null and .not_yet.reminded_at == null' <<<"$RECORD" >/dev/null || return 1
  CHECK_VERDICT=$(contract_json -c '.teardown = false | .needs_you = []' <<<"$CHECK_VERDICT")
  RELEASE_AUTO=not-yet
  [[ $AGENT_STATE == idle ]] || return 0
  age=$(contract_json -r '(now - (.not_yet.at | fromdateiso8601)) | floor' <<<"$RECORD") || return 0
  ((age >= AS_RELEASE_REMIND)) || return 0
  why=$(contract_json -r .not_yet.why <<<"$RECORD")
  sent=closing_sent_at text=$RELEASE_CLOSING
  if release_files_only; then
    sent=cleanup_sent_at text=$(release_cleanup_text)
  fi
  release_send "$repo" "$n" "You said this slot was not ready to release: $why. If that still holds, say so again \
with $RELEASE_NOT_YET. Otherwise: $text" || return 0
  at=$(contract_now)
  record_update "$repo" "$n" --arg at "$at" --arg sent "$sent" \
    '.not_yet.reminded_at = $at | .[$sent] = (.[$sent] // $at)' || true
  RELEASE_AUTO=reminded
}

# Usage: release_auto_gate <repo> <n>; after check_slot. Keeps a finished slot check would let go when neither its agent
# released it nor the operator finished it, and reminds the agent of one kept only by files, setting RELEASE_AUTO to
# closing-sent, cleanup-sent, reminded, not-yet, or not-released.
release_auto_gate() {
  local repo=$1 n=$2 sent why blocker reminded released=0
  RELEASE_AUTO=
  [[ $(contract_json -r .finished <<<"$CHECK_VERDICT") == true ]] || return 0
  ! contract_json -e '.release != null or .finished_by_operator == true' <<<"$RECORD" >/dev/null || released=1
  ((released == 1)) || ! release_hold "$repo" "$n" || return 0
  if [[ $(contract_json -r .teardown <<<"$CHECK_VERDICT") != true ]]; then
    release_cleanup "$repo" "$n"
    return 0
  fi
  ((released == 0)) || return 0
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
