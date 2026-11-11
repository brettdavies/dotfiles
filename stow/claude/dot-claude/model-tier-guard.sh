#!/usr/bin/env bash
# PreToolUse guard for the Agent tool.
#
# orchestrator-handoff goal blocks declare a tier. This denies the dispatch when
# the requested model contradicts that tier, so a mis-tiered worker never starts.
# Dispatches with no TIER line pass through untouched, which is what keeps other
# skills (ce-doc-review's personas, ad-hoc Explore calls) unaffected.
#
# Tier map is duplicated from agent-skills/orchestrator-handoff/references/model-tiers.md.
# Change both together.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# Exit 2 + JSON deny when the call cannot be checked: no JSON parser on PATH,
# or a failure inside this script.
set -euo pipefail

readonly GUARD=model-tier-guard

# The deny is built from text already escaped for JSON, the guard's name, and a
# line number, so it needs no parser. Exit 2 blocks the call even where the
# harness does not read the JSON.
block() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s %s"},"systemMessage":"%s %s"}\n' \
    "$GUARD" "$1" "$GUARD" "$2"
  exit 2
}
trap 'block "failed [guard-internal-error] at line $LINENO, so this call did not run.\nnext_step [ask-user]: tell the user; bats tests/$GUARD.bats in the dotfiles repo shows what broke." "failed at line $LINENO and blocked the call"' ERR

payload=$(cat)

# Fast path: a dispatch with no TIER line, in any letter case, is not checked.
case "$payload" in
  *[Tt][Ii][Ee][Rr]:*) ;;
  *) exit 0 ;;
esac
JQ=$(command -v jaq || command -v jq) \
  || block 'blocked [json-parser-missing]: neither jaq nor jq is on PATH, so this call could not be checked. It did not run; install jaq, then rerun it.\ndocs: ~/dotfiles/BOOTSTRAP.md § \"Install Packages from Brewfile\"\nnext_step [install-jaq]:\nbrew install jaq' \
    'blocked the call: neither jaq nor jq is installed (brew install jaq)'

# No early-exiting consumer in the pipeline: `head -1` closes the pipe as soon
# as it has its line, so a prompt carrying a second TIER line leaves sed
# writing into a closed pipe. It takes SIGPIPE, `pipefail` promotes that to the
# substitution's status, and `set -e` aborts the guard. Every stage here drains
# its input; the first match is taken afterwards.
tier=$(
  "$JQ" -r '.tool_input.prompt // ""' <<<"$payload" \
    | sed -nE 's/^[[:space:]]*TIER:[[:space:]]*(build|ceiling|compound).*/\1/Ip' \
    | tr '[:upper:]' '[:lower:]'
)
tier=${tier%%$'\n'*}

# Not an orchestrator-handoff dispatch.
[ -n "$tier" ] || exit 0

case "$tier" in
  build) want=opus ;;
  ceiling) want=fable ;;
  compound) want=sonnet ;;
esac

got=$(printf '%s' "$payload" | "$JQ" -r '.tool_input.model // ""')
subagent=$(printf '%s' "$payload" | "$JQ" -r '.tool_input.subagent_type // ""')

deny() {
  # shellcheck disable=SC2016  # jaq filter syntax; $reason is a jaq variable
  "$JQ" -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# A fork always inherits the parent model, so a declared tier cannot be honored.
if [ "$subagent" = "fork" ]; then
  deny "TIER: $tier was declared, but subagent_type 'fork' always inherits the parent model and ignores 'model'. Dispatch a non-fork subagent, or drop the TIER line."
fi

if [ "$got" != "$want" ]; then
  deny "TIER: $tier requires model '$want'; this dispatch requested '${got:-none}'. Fix the model, or change the TIER line if the tier was wrong. Resolution table: agent-skills/orchestrator-handoff/references/model-tiers.md"
fi

exit 0
