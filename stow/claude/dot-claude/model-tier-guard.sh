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

set -euo pipefail

payload=$(cat)

tier=$(
  printf '%s' "$payload" \
    | jq -r '.tool_input.prompt // ""' \
    | sed -nE 's/^[[:space:]]*TIER:[[:space:]]*(build|ceiling|compound).*/\1/Ip' \
    | head -1 \
    | tr '[:upper:]' '[:lower:]'
)

# Not an orchestrator-handoff dispatch.
[ -n "$tier" ] || exit 0

case "$tier" in
  build) want=opus ;;
  ceiling) want=fable ;;
  compound) want=sonnet ;;
esac

got=$(printf '%s' "$payload" | jq -r '.tool_input.model // ""')
subagent=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""')

deny() {
  jq -n --arg reason "$1" '{
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
