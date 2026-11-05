#!/usr/bin/env bash
# Claude hook that holds a slot's `git push` to the paths its brief declared. For the pane's top-level Claude in a slot's
# Claude session (see scripts/agent-slot/lib/hook.sh), which includes the calls of that Claude's subagents:
#   PreToolUse on Bash   when the command is a `git push`, lists the paths the slot's commits change against
#                        origin/<base> (`git diff --name-only origin/<base>...HEAD`) and denies the push when any path
#                        matches none of the record's scope.touches git pathspec globs and no `scope-grant` ledger line
#                        for the slot covers it
# A record with no scope.touches passes. Grants count from the slot's created_at, so a reused slot number starts at none.
# Anywhere else, and on a payload, record, or base it cannot read, it prints nothing, so the call goes ahead. Always
# exits 0; failures go to the agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

# A `git push` that starts a command: after a separator, a newline, or an opening parenthesis, past any assignments and
# git's own options.
PUSH_RE=$'(^|[;&|(\n])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[^[:space:]]+|-[A-Za-z]+))*[[:space:]]+push([[:space:]]|$|[;&|)])'

# Usage: scope_grants <repo> <n> <since>; prints the pathspec of each scope-grant ledger line for the slot, one per
# line. The ledger is read line by line, so a line that is not JSON grants nothing.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
scope_grants() {
  [[ -r $AS_LEDGER ]] || return 0
  contract_json -R -s -r --arg repo "$1" --argjson n "$2" --arg since "$3" \
    '[split("\n")[] | fromjson? | select(type == "object" and .event == "scope-grant" and .repo == $repo
      and .slot == $n and .ts >= $since and (.pathspec | type == "string")) | .pathspec] | .[]' "$AS_LEDGER"
}

# Usage: scope_deny_reason <repo> <n> <touches> <paths>; <touches> is the comma-separated globs, <paths> one per line.
scope_deny_reason() {
  printf '%s' "This slot's brief lets its PR change only: $3. The push changes paths outside that, and no scope grant \
covers them:
  ${4//$'\n'/$'\n'  }
Revert that change, or record it under \"Not in scope\" in the PR body and send the coordinating session a request for \
a scope grant, naming the paths. Keep working on what the push does not need."
}

# Usage: scope_decide <repo> <n>; RECORD holds the slot's record. Prints the denial, or nothing.
# shellcheck disable=SC2016 # a jaq program
scope_decide() {
  local repo=$1 n=$2 path base since touches changed matched outside spec
  local -a specs=()
  contract_json -e '.scope.touches | type == "array"' <<<"$RECORD" >/dev/null || return 0
  path=$(slot_path "$repo" "$n")
  base=$(contract_json -r '.base // empty' <<<"$RECORD")
  since=$(contract_json -r '.created_at // ""' <<<"$RECORD")
  [[ -n $base ]] || {
    hook_log "slot $repo/$n has no base in its record; push allowed"
    return 0
  }
  mapfile -t specs < <(contract_json -r '.scope.touches[]' <<<"$RECORD")
  touches=$(contract_json -r '.scope.touches | join(", ")' <<<"$RECORD")
  while IFS= read -r spec; do
    [[ -z $spec ]] || specs+=("$spec")
  done < <(scope_grants "$repo" "$n" "$since" || true)
  changed=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "origin/$base...HEAD" 2>/dev/null \
    | sort -u) || {
    hook_log "slot $repo/$n: git diff origin/$base...HEAD failed; push allowed"
    return 0
  }
  matched=
  if ((${#specs[@]} > 0)); then
    matched=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "origin/$base...HEAD" -- \
      "${specs[@]}" 2>/dev/null | sort -u) || {
      hook_log "slot $repo/$n: a Touches: glob is not a valid pathspec; push allowed"
      return 0
    }
  fi
  outside=$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$matched") | sed '/^$/d')
  [[ -n $outside ]] || return 0
  contract_json -n -c --arg m "$(scope_deny_reason "$repo" "$n" "$touches" "$outside")" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}'
}

scope_main() {
  local fields event tool command repo n
  hook_use_socket "${TMUX%%,*}" || return 0
  fields='"\(.hook_event_name // "")\u001f\(.tool_name // "")\u001f\(.tool_input.command // "" | gsub("\u001f"; " "))"'
  IFS=$'\x1f' read -r -d '' event tool command <<<"$(hook_field "$fields")" || true
  [[ $event == PreToolUse && $tool == Bash ]] || return 0
  [[ $command =~ $PUSH_RE ]] || return 0
  hook_pane && hook_claude_session && hook_top_level_claude || return 0
  read -r repo n <<<"$(hook_slot)"
  record_read "$repo" "$n" || {
    hook_log "slot $repo/$n has no readable record; push allowed"
    return 0
  }
  scope_decide "$repo" "$n"
}

HOOK_PAYLOAD_IN=$(cat)
[[ $HOOK_PAYLOAD_IN == *push* && -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-scope-guard "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(scope_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
