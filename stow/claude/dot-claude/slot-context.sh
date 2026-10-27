#!/usr/bin/env bash
# SessionStart Claude hook: gives an agent in a slot its slot context. Inside a slot (the payload's cwd, or the working
# directory, under the slot root with a record) and only for the pane's top-level Claude in the slot's Claude session
# (see scripts/agent-slot/lib/hook.sh), it:
#   - records the payload's session ID and transcript in the slot record, and appends a `session` ledger line when
#     either changed (a /clear starts a new session);
#   - on the slot's first start sets the record's ready_at and, when the launch carried a request ID, appends the
#     `ready` ledger line that agent-slot doctor joins to the launch line;
#   - prints SessionStart additionalContext naming the slot and its working rules.
# Anywhere else it prints nothing. Always exits 0; failures go to the agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(realpath -m "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

# Usage: context_record <repo> <n>
# Under the slot lock, so the first-start check and the ready line happen once.
# shellcheck disable=SC2016 # jaq programs; their $names are bound with --arg
context_record() {
  local repo=$1 n=$2 sid transcript source ready old_sid old_transcript first request task
  sid=$(hook_field .session_id)
  transcript=$(hook_field .transcript_path)
  source=$(hook_field .source)
  ready=$(date +%s.%N)
  if ! record_lock_slot "$repo" "$n" --wait 10; then
    hook_log "slot $repo/$n lock not taken; session $sid not recorded"
    return 0
  fi
  if ! record_read "$repo" "$n"; then
    record_unlock_slot "$repo" "$n"
    return 0
  fi
  IFS=$'\t' read -r old_sid old_transcript first request task <<<"$(contract_json -r '[.session_id // "-",
    .transcript // "-", (.ready_at == null | tostring), .request_id // "-", .task // "-"] | join("\t")' <<<"$RECORD")"
  record_update "$repo" "$n" --arg sid "$sid" --arg tr "$transcript" --argjson ready "$ready" '
    (if $sid != "" then .session_id = $sid else . end)
    | (if $tr != "" then .transcript = $tr else . end)
    | (if .ready_at == null then .ready_at = $ready else . end)'
  if [[ -n $sid$transcript && ($sid != "$old_sid" || $transcript != "$old_transcript") ]]; then
    ledger_append session "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg task "$task" \
      --arg sid "$sid" --arg tr "$transcript" --arg source "$source" \
      '{repo: $repo, slot: $slot, task: (if $task == "-" then null else $task end), session_id: $sid,
        transcript: $tr, source: $source}')"
  fi
  if [[ $first == true && $request != - ]]; then
    ledger_append ready "$(contract_json -n -c --arg id "$request" --argjson at "$ready" --arg repo "$repo" \
      --argjson slot "$n" --arg sid "$sid" \
      '{request_id: $id, ready_at: $at, repo: $repo, slot: $slot, session_id: $sid}')"
  fi
  record_unlock_slot "$repo" "$n"
}

# Usage: context_text <repo> <n>; prints the SessionStart output for the record in RECORD.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
context_text() {
  contract_json -c --arg key "$(slot_key "$1" "$2")" --arg path "$(slot_path "$1" "$2")" '
    {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([
      "You are working in agent slot \($key), a full clone at \($path).",
      (if .task then "Task: \(.task)." else "This slot was given no task name." end),
      "The base branch is \(.base // "the default branch").",
      "The prime checkout \(.prime // "for this repo") is read-only for you; make every change in this slot.",
      "docs/solutions is the solutions repo shared with every other agent; commit to it only through `sd-commit-doc`.",
      "`agent-slot check` lists what blocks the teardown of this slot, and `agent-slot whoami` names it.",
      "Run agent-slot verbs with `--output json` after the verb; `--help` on any verb lists its flags and fields.",
      "`agent-slot schema --output json` prints the whole contract: the success and error objects and every reason.",
      "To hand a task to another agent, run `agent-slot launch <repo> --request-id <id> --prompt-file <brief>`.",
      "Claude runs here with `--dangerously-skip-permissions`; ask rules, deny rules, and hooks still stop tool calls.",
      "`agent-slot sweep` and `agent-slot finish` delete slots: ask the operator before running either with `--yes`.",
      "In a review round, re-check the state of the PR before stacking new commits on it.",
      "Stage with `git add`, then run a plain `git commit`; never `git commit -a` or `git commit <path>`.",
      "Create no git worktrees inside this slot."
    ] | join("\n"))}}' <<<"$RECORD"
}

context_main() {
  local dir at repo n
  hook_use_socket "${TMUX%%,*}" || return 0
  dir=$(hook_field .cwd)
  at=$(slot_at "${dir:-$PWD}") || return 0
  read -r repo n <<<"$at"
  record_read "$repo" "$n" || return 0
  hook_pane || return 0
  [[ $HOOK_PANE_SESSION == "$(slot_session "$repo" "$n")" ]] && hook_top_level_claude || return 0
  context_record "$repo" "$n"
  record_read "$repo" "$n" || return 0
  context_text "$repo" "$n"
}

HOOK_PAYLOAD_IN=$(cat)
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-context "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(context_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
