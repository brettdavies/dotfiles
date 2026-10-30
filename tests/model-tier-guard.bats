#!/usr/bin/env bats
# Tests for the PreToolUse Agent hook that denies a dispatch whose model
# contradicts the TIER line an orchestrator-handoff goal block declares.
#
# Run: bats tests/model-tier-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/model-tier-guard.sh"

load lib/json-parser

setup() { command -v jaq >/dev/null 2>&1 || skip "jaq not available"; }

# The JSON for an Agent dispatch. Args: prompt, model, subagent_type.
agent_payload() {
  jaq -nc --arg p "$1" --arg m "$2" --arg s "${3:-general-purpose}" \
    '{tool_name: "Agent", tool_input: {prompt: $p, model: $m, subagent_type: $s}}'
}

reason() { jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"; }

GOAL_BUILD='Goal: ship the fix.
TIER: build
Scope: one file.'

@test "a build tier dispatched on opus is allowed" {
  run "$HOOK" <<<"$(agent_payload "$GOAL_BUILD" opus)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a build tier dispatched on sonnet is denied naming opus" {
  run "$HOOK" <<<"$(agent_payload "$GOAL_BUILD" sonnet)"
  [ "$status" -eq 0 ]
  [[ "$(reason)" == *"TIER: build requires model 'opus'"* ]]
}

@test "a declared tier on a fork is denied, since a fork ignores model" {
  run "$HOOK" <<<"$(agent_payload "$GOAL_BUILD" opus fork)"
  [ "$status" -eq 0 ]
  [[ "$(reason)" == *"subagent_type 'fork' always inherits the parent model"* ]]
}

@test "a dispatch with no TIER line is allowed whatever its model" {
  run "$HOOK" <<<"$(agent_payload 'Summarize the README.' haiku)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Without a working JSON parser the guard blocks what it checks, never allows it
# ---------------------------------------------------------------------------

@test "with neither jaq nor jq, a TIER dispatch in any letter case is blocked naming the fix" {
  run_hook_with_parser none "$HOOK" "$(agent_payload 'Goal: x
tier: Ceiling' fable)"
  assert_parser_block json-parser-missing
  [[ $REASON == "model-tier-guard blocked [json-parser-missing]: "* ]]
  [ "${REASON##*$'\n'}" = 'brew install jaq' ]
}

@test "with neither jaq nor jq, a dispatch with no TIER line still runs" {
  run_hook_with_parser none "$HOOK" "$(agent_payload 'Summarize the README.' haiku)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "with jaq and no jq, a mis-tiered dispatch is denied" {
  run_hook_with_parser jaq "$HOOK" "$(agent_payload "$GOAL_BUILD" sonnet)"
  [ "$status" -eq 0 ]
  [[ "$(reason)" == *"TIER: build requires model 'opus'"* ]]
}

@test "with jq and no jaq, a mis-tiered dispatch is denied as it is with jaq" {
  assert_same_deny_with_jq "$HOOK" "$(agent_payload "$GOAL_BUILD" sonnet)"
}

@test "with a jaq that fails, the guard blocks naming its own failure" {
  run_hook_with_parser broken "$HOOK" "$(agent_payload "$GOAL_BUILD" opus)"
  assert_parser_block guard-internal-error
  [[ $REASON == "model-tier-guard failed [guard-internal-error] at line "* ]]
}
