#!/usr/bin/env bash
# Claude hook that caps the review rounds of a slot's agent. For the pane's top-level Claude in a slot's Claude session
# (see scripts/agent-slot/lib/hook.sh), which includes the calls of that Claude's subagents:
#   PreToolUse on Skill   counts a call of compound-engineering:ce-code-review as one round for the PR on the slot's
#                         current branch and appends a `review-round` ledger line; with REVIEW_CAP rounds plus the
#                         branch's `review-grant` lines already counted, it denies the call instead
#   PreToolUse on Bash    does the same for a command that starts `claude` with ce-code-review, the way the agent-slot
#                         skill runs a review: `claude -p` from a throwaway clone of the pushed head
# Rounds and grants count from the slot's created_at, so a reused slot number starts at none. Anywhere else, and on a
# payload or ledger it cannot read, it prints nothing, so the call goes ahead. Always exits 0; failures go to the
# agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

REVIEW_SKILL=compound-engineering:ce-code-review
# A command that starts claude (a word of its own, not a path such as ~/.claude/) and names the skill, not a longer
# skill name such as ce-code-reviewer.
REVIEW_COMMAND_CLAUDE='(^|[^[:alnum:]_./-])claude[[:space:]]'
REVIEW_COMMAND_SKILL='ce-code-review([^[:alnum:]_-]|$)'

# Usage: review_deny_reason <repo> <n> <rounds> <grants> <branch>; RECORD holds the slot's record.
# shellcheck disable=SC2016 # a jaq program
review_deny_reason() {
  local allowed="at most $REVIEW_CAP review rounds per PR" head pr which="the PR"
  head=$(git -C "$(slot_path "$1" "$2")" rev-parse --short HEAD 2>/dev/null) || head=
  pr=$(contract_json -r '(.prs // []) | map(select(type == "number")) | last // empty' <<<"$RECORD") || pr=
  [[ -z $pr ]] || which="PR #$pr"
  (($4 == 0)) || allowed="$REVIEW_CAP review rounds per PR plus $4 granted"
  printf '%s' "This slot allows $allowed, and branch $5 has had $3. A PR gets one review round, and a second only to \
review round 1's P0 and P1 fixes. If this round is needed, send the coordinating session $which, its head SHA\
${head:+ ($head)}, and why, as one \`SendMessage\`: it or the operator can allow one more round by running \
\`agent-slot grant-review $1/$2\`, which you cannot run yourself. Keep working on what the review does not block. If \
your brief names no such session, leave the decision open in your plan and your report."
}

# Usage: review_decide <repo> <n> <branch> <since>; under the ledger lock, prints the denial or appends the round.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
review_decide() {
  local repo=$1 n=$2 branch=$3 since=$4 fd rounds grants members
  mkdir -p "${AS_LEDGER%/*}"
  exec {fd}>>"$AS_LEDGER.review.lock" || return 1
  flock -w 5 "$fd" || true
  rounds=$(review_count review-round "$repo" "$n" "$branch" "$since") || rounds=
  grants=$(review_count review-grant "$repo" "$n" "$branch" "$since") || grants=
  if [[ $rounds =~ ^[0-9]+$ && $grants =~ ^[0-9]+$ ]]; then
    if ((rounds >= REVIEW_CAP + grants)); then
      contract_json -n -c --arg m "$(review_deny_reason "$repo" "$n" "$rounds" "$grants" "$branch")" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}'
    elif members=$(contract_json -c --arg repo "$repo" --argjson slot "$n" --arg branch "$branch" \
      '{repo: $repo, slot: $slot, branch: $branch, session_id: .session_id}
        + (if .agent_id then {agent_id, agent_type} else {} end)' <<<"$HOOK_PAYLOAD"); then
      ledger_append review-round "$members" || hook_log "slot $repo/$n review-round line not written"
    fi
  else
    hook_log "slot $repo/$n review ledger unreadable; call allowed"
  fi
  exec {fd}>&-
}

review_main() {
  local fields event tool skill command repo n branch since
  hook_use_socket "${TMUX%%,*}" || return 0
  fields='"\(.hook_event_name // "")\u001f\(.tool_name // "")\u001f\(.tool_input.skill // "")"'
  IFS=$'\x1f' read -r event tool skill <<<"$(hook_field "$fields")"
  if [[ $event == PreToolUse && $tool == Bash ]]; then
    command=$(hook_field .tool_input.command)
    [[ $command =~ $REVIEW_COMMAND_CLAUDE && $command =~ $REVIEW_COMMAND_SKILL ]] || return 0
    tool=Skill skill=$REVIEW_SKILL
  fi
  # Claude Code runs the skill under its trimmed name, without one leading slash, and accepts the name without its
  # plugin prefix.
  skill=${skill#"${skill%%[![:space:]]*}"}
  skill=${skill%"${skill##*[![:space:]]}"}
  skill=${skill#/}
  skill=${skill#"${skill%%[![:space:]]*}"}
  [[ $event == PreToolUse && $tool == Skill && ($skill == "$REVIEW_SKILL" || $skill == "${REVIEW_SKILL#*:}") ]] || return 0
  hook_pane && hook_claude_session && hook_top_level_claude || return 0
  read -r repo n <<<"$(hook_slot)"
  branch=$(slot_review_key "$(slot_path "$repo" "$n")")
  [[ -n $branch ]] || {
    hook_log "slot $repo/$n has no readable HEAD; review call allowed"
    return 0
  }
  record_read "$repo" "$n" || {
    hook_log "slot $repo/$n has no readable record; review call allowed"
    return 0
  }
  since=$(contract_json -r '.created_at // ""' <<<"$RECORD")
  review_decide "$repo" "$n" "$branch" "$since"
}

HOOK_PAYLOAD_IN=$(cat)
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
# Every Bash call on the host reaches this hook; only one that names the skill can count.
[[ $HOOK_PAYLOAD_IN == *ce-code-review* ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-review-cap "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(review_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
