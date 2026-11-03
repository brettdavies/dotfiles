#!/usr/bin/env bash
# Claude hook that keeps a slot's agent from waiting on a dialog nobody answers: no one watches a slot's tab. For the
# pane's top-level Claude in a slot's Claude session (see scripts/agent-slot/lib/hook.sh), which includes the tool
# calls of that Claude's subagents, since they run inside its process:
#   PermissionRequest                               denies the request, telling the agent to work within its brief
#   PreToolUse on AskUserQuestion, EnterPlanMode,   denies the call, sending the question to the session the brief
#     ExitPlanMode                                    reports to; plan mode ends only on a person's approval
#   Notification                                    records a dialog that waited for a person anyway
# Each denial appends a `prompt-denied` ledger line, and each Notification of a waiting dialog a `prompt-waiting` one.
# Anywhere else, and on a payload it cannot read, it prints nothing, so the dialog shows as it does without the hook.
# Always exits 0; failures go to the agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

UNATTENDED_PERMISSION="This agent slot runs unattended: nobody watches its tab, so nobody can approve this \
permission request, and it was denied without a prompt. Do the work another way within your brief, such as \`cp\` then \
\`trash\` in place of \`mv\`, or \`uv run\` in place of \`python\`. If nothing within your brief does it, send what \
you need to the session your brief reports to as one \`SendMessage\`, and keep working on what it does not block."

UNATTENDED_QUESTION="This agent slot runs unattended: nobody watches its tab, so a question asked here is never \
answered, and it was denied. Answer it yourself where the code, the repo's docs, \`docs/solutions\`, or precedent \
settles it. Send a decision only a person can make to the session your brief reports to as one \`SendMessage\`: the \
question, the options, your recommendation, and its evidence. Keep working on what it does not block; if your brief \
names no such session, leave the decision open in your plan and your report."

UNATTENDED_PLAN="This agent slot runs unattended: plan mode ends only when a person approves the plan in this tab, \
and nobody watches it, so plan mode is denied here. Write the plan to a file instead, run it through the reviews your \
brief asks for, send a decision only a person can make to the session your brief reports to as one \`SendMessage\`, \
and keep working on what it does not block."

# Prints "<repo> <n>" for this hook's slot: the one the payload's cwd is in, else the one the pane's session names.
unattended_slot() {
  local at
  if at=$(slot_at "$(hook_field .cwd)"); then
    printf '%s' "$at"
  else
    printf '%s %s' "${HOOK_PANE_SESSION%-*}" "${HOOK_PANE_SESSION##*-}"
  fi
}

# Usage: unattended_ledger <event> <jq filter over the payload, giving the line's own members>
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
unattended_ledger() {
  local repo n members
  read -r repo n <<<"$(unattended_slot)"
  if members=$(contract_json -c --arg repo "$repo" --argjson slot "$n" \
    '{repo: $repo, slot: $slot, session_id: .session_id} + ('"$2"')
      + (if .agent_id then {agent_id, agent_type} else {} end)' <<<"$HOOK_PAYLOAD") &&
    ledger_append "$1" "$members"; then
    return 0
  fi
  hook_log "slot $repo/$n $1 line not written"
}

unattended_deny() {
  unattended_ledger prompt-denied '{hook: .hook_event_name, tool: .tool_name,
    input: (.tool_input | if type == "object" then .command // .file_path // tojson else tojson end | .[0:200])}'
}

# Usage: unattended_answer <PermissionRequest | PreToolUse> <message>; prints the hook output that denies the call.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
unattended_answer() {
  if [[ $1 == PermissionRequest ]]; then
    contract_json -n -c --arg m "$2" \
      '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $m}}}'
  else
    contract_json -n -c --arg m "$2" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}'
  fi
}

unattended_main() {
  local fields event tool type
  hook_use_socket "${TMUX%%,*}" || return 0
  # Not a tab: read merges a run of IFS whitespace, so a Notification's empty tool_name would shift its type left.
  fields='"\(.hook_event_name // "")\u001f\(.tool_name // "")\u001f\(.notification_type // "")"'
  IFS=$'\x1f' read -r event tool type <<<"$(hook_field "$fields")"
  case $event:$tool:$type in
    PermissionRequest:?*:* | PreToolUse:?*:* | Notification::?*) ;;
    *)
      hook_log "payload without the fields its event needs (event=${event:-none}); left to the dialog"
      return 0
      ;;
  esac
  hook_pane && hook_claude_session && hook_top_level_claude || return 0
  case $event:$tool:$type in
    PermissionRequest:*)
      unattended_deny
      unattended_answer "$event" "$UNATTENDED_PERMISSION"
      ;;
    PreToolUse:AskUserQuestion:*)
      unattended_deny
      unattended_answer "$event" "$UNATTENDED_QUESTION"
      ;;
    PreToolUse:EnterPlanMode:* | PreToolUse:ExitPlanMode:*)
      unattended_deny
      unattended_answer "$event" "$UNATTENDED_PLAN"
      ;;
    Notification::permission_prompt | Notification::elicitation_dialog | Notification::agent_needs_input)
      unattended_ledger prompt-waiting '{notification_type, message: (.message // "" | .[0:200])}'
      ;;
  esac
}

HOOK_PAYLOAD_IN=$(cat)
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-unattended "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(unattended_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
