# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Probe PRs: a draft a slot opens to exercise CI or a reusable workflow and never means to merge. Nothing infers one. The
# slot's agent marks it with `probe`, which adds its number to the record's probes, and closes it with `close-probe`, the
# one close open to a slot, since `gh pr close` sits behind an ask rule nobody can answer there. check counts a closed
# probe toward neither finishing the task nor blocking it, as it does a settled PR, and every other check still holds.
#
# Both verbs run from inside the slot, on a PR of origin's repo, and qualify a PR the same way: an open draft on a branch
# this clone created, whose current head this clone pushed. A remote-tracking ref's reflog is the proof. git writes
# "update by push" there only for a push from this clone and a fetch message for what it merely received, so the oldest
# entry says who brought the branch here, and a fixup on another writer's branch does not make it this slot's. A head
# another writer moved has no push entry either. A push that moved nothing still writes that line when the tracking ref
# was missing: a branch only ever seen through a pull ref and re-pushed reads as this clone's, which the reflog cannot
# tell apart. A fetch that stores the new head before the push's own update leaves no push entry for a head this clone
# did push, so the refusal says what restores the proof.

PROBE_REPO='' PROBE_N='' PROBE_KEY='' PROBE_PATH='' PROBE_ORIGIN='' PROBE_PR='{}'

# Usage: _probe_resolve <ref>; sets PROBE_* for the slot holding the current directory, reads the record, and reads the
# PR into ITEM and PROBE_PR. A ref naming another repo than origin's is refused unread.
_probe_resolve() {
  local at slug
  at=$(slot_at "$PWD") || at=''
  [[ -z $at ]] || read -r PROBE_REPO PROBE_N <<<"$at"
  if [[ -z $at ]] || ! record_read "$PROBE_REPO" "$PROBE_N"; then
    contract_fail not-in-slot "$PWD is not inside a slot under $AS_ROOT; $CONTRACT_VERB runs from inside the slot that \
pushed the PR" --value "$PWD" --command "agent-slot whoami"
  fi
  PROBE_KEY=$(slot_key "$PROBE_REPO" "$PROBE_N")
  PROBE_PATH=$(slot_path "$PROBE_REPO" "$PROBE_N")
  PROBE_ORIGIN=$(git -C "$PROBE_PATH" config --get remote.origin.url || true)
  item_parse_ref pr "$1" "$PROBE_ORIGIN"
  slug=$(pr_repo_slug "$PROBE_ORIGIN")
  [[ ${ITEM_REPO,,} == "${slug,,}" ]] || contract_fail pr-not-from-this-slot "$ITEM_REPO#$ITEM_NUMBER is not in $slug, \
this slot's origin, whose PRs are the only ones check judges" --value "$ITEM_REF" \
    --command "$(contract_help_command)" --action run
  require_tools gh
  item_resolve
  PROBE_PR=$(contract_json -c '{repo, number, title, head: .head_branch, oid: .head_oid, url}' <<<"$ITEM")
}

_probe_view_command() { contract_quote gh pr view "$ITEM_NUMBER" --repo "$ITEM_REPO"; }

_probe_state() { contract_json -r .state <<<"$ITEM"; }

_probe_marked() { contract_json --argjson n "$ITEM_NUMBER" '(.probes // []) | index($n) != null' <<<"$RECORD"; }

# Usage: _probe_refuse_not_open; a merged PR needs nothing more, while one closed before it was marked keeps its blocker,
# which only the operator can clear.
_probe_refuse_not_open() {
  [[ $(_probe_state) != MERGED ]] || contract_fail pr-not-open "PR #$ITEM_NUMBER is MERGED, so it needs no closing and \
cannot be a probe" --value "$ITEM_REF"
  contract_fail pr-not-open "PR #$ITEM_NUMBER is CLOSED, and a PR closed before it was marked stays the \
pr-closed-unmerged blocker; clearing that is the operator's call" --value "$ITEM_REF" \
    --command "$(_probe_view_command)" --action ask-operator
}

# Usage: _probe_require_draft; refuses a PR that is not a draft and drops its mark, so a return to draft does not make it
# a probe again. Marking one needs nobody, since it simply is no probe; closing a marked one is the operator's call.
_probe_require_draft() {
  [[ $(contract_json -r .draft <<<"$ITEM") != true ]] || return 0
  [[ $(_probe_marked) != true ]] \
    || record_update "$PROBE_REPO" "$PROBE_N" --argjson n "$ITEM_NUMBER" '.probes -= [$n]' || true
  [[ $CONTRACT_VERB != probe ]] || contract_fail pr-not-draft "PR #$ITEM_NUMBER is not a draft, so it is a real PR and \
cannot be marked a probe" --value "$ITEM_REF"
  contract_fail pr-not-draft "PR #$ITEM_NUMBER is not a draft, so it is a real PR rather than a probe, and its mark is \
dropped; closing it is the operator's call" --value "$ITEM_REF" --command "$(_probe_view_command)"
}

# Usage: _probe_pushed_here; true when a remote of this clone at the head's repository has a remote-tracking ref for the
# head branch whose reflog starts with a push and records the PR's current head commit as pushed. `log -g` lists newest
# first, so the last line is the oldest. The reflog goes through a variable because a grep that stops at its first match
# would fail a pipeline under pipefail.
_probe_pushed_here() {
  local head_repo branch oid remote slug pushes
  head_repo=$(contract_json -r '.head_repo // ""' <<<"$ITEM")
  branch=$(contract_json -r '.head_branch // ""' <<<"$ITEM")
  oid=$(contract_json -r '.head_oid // ""' <<<"$ITEM")
  [[ -n $head_repo && -n $branch && -n $oid ]] || return 1
  while read -r remote; do
    slug=$(pr_repo_slug "$(git -C "$PROBE_PATH" config --get "remote.$remote.url" || true)")
    [[ ${slug,,} == "${head_repo,,}" ]] || continue
    pushes=$(git -C "$PROBE_PATH" log -g --format='%H %gs' "refs/remotes/$remote/$branch" 2>/dev/null) || continue
    [[ ${pushes##*$'\n'} == *' update by push' ]] || continue
    ! grep -qxF "$oid update by push" <<<"$pushes" || return 0
  done < <(git -C "$PROBE_PATH" remote)
  return 1
}

_probe_require_pushed_here() {
  _probe_pushed_here || contract_fail pr-not-from-this-slot "PR #$ITEM_NUMBER's head \
$(contract_json -r '"\(.head_repo // "(repository gone)"):\(.head_branch) at \(.head_oid // "(unknown)")"' <<<"$ITEM") \
is not on a branch this slot created with that commit pushed from here, so it is another writer's to close. If this \
slot did push it, a fetch can have landed first: push a new commit and rerun" --value "$ITEM_REF" \
    --command "$(_probe_view_command)"
}

# Usage: _probe_ledger <event>; one ledger line naming the PR, from RECORD and PROBE_PR.
_probe_ledger() {
  ledger_append "$1" "$(contract_json -c --argjson pr "$PROBE_PR" \
    '{repo, slot, task, session_id, number: $pr.number, head: $pr.head, oid: $pr.oid}' <<<"$RECORD")"
}

# Usage: cmd_probe <ref>; marks an open draft this slot pushed as a probe, in the same record update that attaches it as
# a work item. A probe names no slot, so the update drops the name this PR would give, whether item_add just gave it or a
# check took it before the PR was marked. A PR already marked succeeds and changes nothing.
cmd_probe() {
  local already work_item own
  _probe_resolve "$1"
  [[ $(_probe_state) == OPEN ]] || _probe_refuse_not_open
  _probe_require_draft
  _probe_require_pushed_here
  already=$(_probe_marked)
  if [[ $already != true ]]; then
    work_item=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
    own=$(item_name "$work_item")
    item_add "$PROBE_REPO" "$PROBE_N" "$PROBE_ORIGIN" "[$work_item]" --argjson n "$ITEM_NUMBER" --arg own "$own" \
      '.probes = ((.probes // []) + [$n] | unique) | if .name == $own then del(.name) else . end' \
      || contract_fail slot-busy "$PROBE_KEY stayed locked, so PR #$ITEM_NUMBER was not marked" --value "$PROBE_KEY" \
        --command "$(contract_quote "$CONTRACT_PROGRAM" "${CONTRACT_ARGV[@]}")"
    record_read "$PROBE_REPO" "$PROBE_N"
    _probe_ledger probe
  fi
  contract_ok "$(contract_json -c --arg key "$PROBE_KEY" --argjson pr "$PROBE_PR" --argjson already "$already" \
    '{key: $key, pr: $pr, probes: .probes, already_marked: $already}' <<<"$RECORD")" \
    '"\(.key): PR #\(.pr.number) (\(.pr.title)) is marked a probe; close it with agent-slot close-probe \(.pr.number)"'
}

# Usage: cmd_close_probe <ref>; closes a marked open draft whose head this slot pushed. It deletes no branch, so
# `gh pr reopen` undoes it. A marked draft already closed succeeds without a second close, which makes a rerun safe after
# a close whose outcome is unknown.
cmd_close_probe() {
  local already=false state marked rerun out
  _probe_resolve "$1"
  marked=$(_probe_marked)
  [[ $marked == true ]] || contract_fail pr-not-probe "PR #$ITEM_NUMBER is not marked a probe, so close-probe will not \
close it; mark an open draft this slot pushed with agent-slot probe first" --value "$ITEM_REF" \
    --command "$(contract_quote agent-slot probe "$ITEM_REF")"
  state=$(_probe_state)
  [[ $state != MERGED ]] || _probe_refuse_not_open
  _probe_require_draft
  if [[ $state == CLOSED ]]; then
    already=true
  else
    _probe_require_pushed_here
    rerun=$(contract_quote "$CONTRACT_PROGRAM" "${CONTRACT_ARGV[@]}")
    if ! bounded out gh 30 "$AS_GH" pr close "$ITEM_NUMBER" --repo "$ITEM_REPO" \
      --comment "Closed by agent-slot close-probe: slot $PROBE_KEY marked this draft a throwaway probe."; then
      contract_use_tools gh
      contract_fail pr-close-failed "gh pr close failed for PR #$ITEM_NUMBER (exit $BOUNDED_STATUS), so it may or may \
not be closed; rerunning is safe" --value "$ITEM_REF" --command "$rerun" --side-effects unknown --reconcile "$rerun" \
        --log "$BOUNDED_LOG"
    fi
    _probe_ledger close-probe
  fi
  contract_ok "$(contract_json -n -c --arg key "$PROBE_KEY" --argjson pr "$PROBE_PR" --argjson already "$already" \
    '{key: $key, pr: $pr, closed: true, already_closed: $already}')" \
    '"\(.key): PR #\(.pr.number) \(if .already_closed then "was already closed" else "closed" end) as a probe"'
}
