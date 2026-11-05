# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Probe PRs: a draft a slot opens to exercise CI or a reusable workflow and never means to merge. Nothing infers one. The
# slot's agent marks it with `probe`, which adds its number to the record's probes, and closes it with `close-probe`, the
# one close open to a slot, since `gh pr close` sits behind an ask rule nobody can answer there. check counts a closed
# probe toward neither finishing the task nor blocking it, as it does a settled PR, and every other check still holds.
#
# Both verbs run from inside the slot, on a PR of origin's repo titled "test(probe): <what it probes>", which keeps the
# verbs off every other open PR and stays a Conventional Commits title. They qualify a PR the same way: an open draft on a
# branch this clone created, whose current head this clone pushed. A remote-tracking ref's reflog is the proof. git writes
# "update by push" there only for a push from this clone and a fetch message for what it merely received, and a clone
# writes no entry at all for the branches it brings. So a log that starts from an all-zero old oid with a push reads as
# a branch this clone created, while a log that starts from a fetch reads as another writer's. A head another writer
# moved, once it is fetched, has no push entry. That old oid is the tracking ref's prior value and not origin's, so the
# reflog cannot tell these apart: any push made while the tracking ref is missing, a fixup or one that moved nothing,
# reads as this clone creating the branch, and a push that moved nothing over a stale tracking ref, on a branch this
# clone created, records a head this clone did not write. A fetch that stores the new head before the push's own update
# leaves no push entry for a head this clone did push. On a later push a new commit restores the proof, and the refusal
# says so; on a branch's first push the branch reads as another writer's, and the operator closes it.

PROBE_TITLE_PREFIX='test(probe): '
PROBE_REPO='' PROBE_N='' PROBE_KEY='' PROBE_PATH='' PROBE_ORIGIN='' PROBE_PR='{}' PROBE_PROOF=''

# Usage: _probe_resolve <ref>; sets PROBE_* for the slot holding the current directory, reads the record, and reads the
# PR into ITEM and PROBE_PR. A ref naming another repo than origin's is refused unread, and an open PR without a probe's
# title is refused once read. Marking and closing an open PR are the only acts the title guards, so a closed or merged PR
# goes on to the refusal that says what can still be done about it.
_probe_resolve() {
  local at slug
  at=$(slot_at "$PWD") || at=''
  [[ -z $at ]] || read -r PROBE_REPO PROBE_N <<<"$at"
  if [[ -z $at ]] || ! record_read "$PROBE_REPO" "$PROBE_N"; then
    contract_fail not-in-slot "$PWD is not inside a slot under $AS_ROOT; $CONTRACT_VERB runs from inside the slot that \
pushed the PR" --value "$PWD"
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
  [[ $(_probe_state) != OPEN ]] || _probe_require_title
}

_probe_require_title() {
  local title
  title=$(contract_json -r '.title // ""' <<<"$ITEM")
  [[ $title == "$PROBE_TITLE_PREFIX"?* ]] || contract_fail pr-title-not-probe "PR #$ITEM_NUMBER's title is \"$title\", \
and $CONTRACT_VERB acts only on a PR titled '${PROBE_TITLE_PREFIX}<what it probes>'; open a probe PR as a draft with that \
title" --value "$ITEM_REF" --command "$(contract_help_command)"
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

# Usage: _probe_require_draft; refuses a PR that is not a draft and drops its mark, which does not come back by itself on
# a return to draft; marking it again is a new declaration by the agent. Marking one out of draft needs nobody, since it
# simply is no probe; closing a marked one is the operator's call.
_probe_require_draft() {
  [[ $(contract_json -r .draft <<<"$ITEM") != true ]] || return 0
  [[ $(_probe_marked) != true ]] \
    || record_update "$PROBE_REPO" "$PROBE_N" --argjson n "$ITEM_NUMBER" '.probes -= [$n]' || true
  [[ $CONTRACT_VERB != probe ]] || contract_fail pr-not-draft "PR #$ITEM_NUMBER is not a draft, so it is a real PR and \
cannot be marked a probe" --value "$ITEM_REF"
  contract_fail pr-not-draft "PR #$ITEM_NUMBER is not a draft, so it is a real PR rather than a probe, and its mark is \
dropped; closing it is the operator's call" --value "$ITEM_REF" --command "$(_probe_view_command)"
}

# Usage: _probe_read_proof; sets PROBE_PROOF from the reflog of the remote-tracking ref for the head branch, on a remote
# of this clone at the head's repository: pushed when the log starts with the push that created the ref and records the
# PR's current head commit as pushed, moved when it starts that way but has no push entry for that commit, and foreign
# otherwise. It reads the log file because only that holds an entry's old oid, which no `git log` format prints. Its
# lines are "<old> <new> <who> <when>\t<message>", oldest first. A reftable repository has no such file, so the proof
# fails closed.
_probe_read_proof() {
  local head_repo branch oid remote slug log entries
  local created='^0+ .*'$'\t''update by push$'
  PROBE_PROOF=foreign
  head_repo=$(contract_json -r '.head_repo // ""' <<<"$ITEM")
  branch=$(contract_json -r '.head_branch // ""' <<<"$ITEM")
  oid=$(contract_json -r '.head_oid // ""' <<<"$ITEM")
  [[ -n $head_repo && -n $branch && -n $oid ]] || return 0
  while read -r remote; do
    slug=$(pr_repo_slug "$(git -C "$PROBE_PATH" config --get "remote.$remote.url" || true)")
    [[ ${slug,,} == "${head_repo,,}" ]] || continue
    log=$(git -C "$PROBE_PATH" rev-parse --path-format=absolute --git-path "logs/refs/remotes/$remote/$branch") || continue
    [[ -r $log ]] || continue
    entries=$(<"$log")
    [[ ${entries%%$'\n'*} =~ $created ]] || continue
    PROBE_PROOF=moved
    if grep -qE "^[0-9a-f]+ $oid .*"$'\t'"update by push\$" <<<"$entries"; then
      PROBE_PROOF=pushed
      return 0
    fi
  done < <(git -C "$PROBE_PATH" remote)
}

# Usage: _probe_require_pushed_here; refuses unless PROBE_PROOF is pushed. On a branch this clone created, the agent can
# read the head's commits and restore the proof itself; on any other branch only the operator can act. The commits come
# from GitHub because a head this clone never fetched is in no local ref, and the slots commit under one user.name.
_probe_require_pushed_here() {
  local head
  _probe_read_proof
  [[ $PROBE_PROOF != pushed ]] || return 0
  head=$(contract_json -r '"\(.head_repo // "(repository gone)"):\(.head_branch) at \(.head_oid // "(unknown)")"' <<<"$ITEM")
  if [[ $PROBE_PROOF == moved ]]; then
    contract_fail pr-not-from-this-slot "PR #$ITEM_NUMBER's head $head, on a branch this slot created, is not a commit \
this slot pushed: another writer moved it, or a fetch landed before the push's own update. Read the PR's commits; if none \
of its work is another writer's, push a new commit to it and rerun, and do not force-push" --value "$ITEM_REF" \
      --command "$(contract_quote gh pr view "$ITEM_NUMBER" --repo "$ITEM_REPO" --json commits)" --action run
  fi
  contract_fail pr-not-from-this-slot "PR #$ITEM_NUMBER's head $head is not on a branch this slot created, so it is \
another writer's to close" --value "$ITEM_REF" --command "$(_probe_view_command)"
}

# Usage: _probe_ledger <event> [extra fields, a JSON object]; one ledger line naming the PR, from RECORD and PROBE_PR.
_probe_ledger() {
  local extra=${2:-'{}'}
  ledger_append "$1" "$(contract_json -c --argjson pr "$PROBE_PR" --argjson extra "$extra" \
    '{repo, slot, task, session_id, number: $pr.number, head: $pr.head, oid: $pr.oid} + $extra' <<<"$RECORD")"
}

# Usage: cmd_probe <ref>; marks an open draft this slot pushed as a probe, in the same record update that attaches it as
# a work item. A PR already marked, open or closed, succeeds and changes nothing, as close-probe's rerun does.
cmd_probe() {
  local already work_item state
  _probe_resolve "$1"
  already=$(_probe_marked) state=$(_probe_state)
  [[ $state == OPEN || ($state == CLOSED && $already == true) ]] || _probe_refuse_not_open
  _probe_require_draft
  [[ $state != OPEN ]] || _probe_require_pushed_here
  if [[ $already != true ]]; then
    work_item=$(contract_json -c '{kind, repo, number, title}' <<<"$ITEM")
    item_add "$PROBE_REPO" "$PROBE_N" "$PROBE_ORIGIN" "[$work_item]" --argjson n "$ITEM_NUMBER" \
      '.probes = ((.probes // []) + [$n] | unique)' \
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
# a close whose outcome is unknown. Every success logs, because a close that landed while gh reported failure gets its
# only event from the rerun; already_closed tells that rerun from the run that made the close.
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
  fi
  _probe_ledger close-probe "{\"already_closed\": $already}"
  contract_ok "$(contract_json -n -c --arg key "$PROBE_KEY" --argjson pr "$PROBE_PR" --argjson already "$already" \
    '{key: $key, pr: $pr, closed: true, already_closed: $already}')" \
    '"\(.key): PR #\(.pr.number) \(if .already_closed then "was already closed" else "closed" end) as a probe"'
}
