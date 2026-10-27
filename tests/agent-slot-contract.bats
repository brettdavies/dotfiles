#!/usr/bin/env bats
# The agent-slot output contract: exit codes, the JSON error envelope, --help, bounded calls, and record schemas.
#
# Run: bats tests/agent-slot-contract.bats

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
}

@test "an unknown verb exits 2 with a usage error on stderr" {
  run --separate-stderr "$AGENT_SLOT" frobnicate --output json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  jaq -e '.reason == "usage" and .value == "frobnicate"' <<<"$stderr"
}

@test "--output before the verb is refused, so no flag order slips past the ask rules for sweep and finish" {
  run --separate-stderr "$AGENT_SLOT" --output json sweep --yes
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  jaq -e '.reason == "usage" and .verb == "agent-slot" and (.message | contains("after the verb"))' <<<"$stderr"
  run --separate-stderr "$AGENT_SLOT" --output=json repos
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
}

@test "--help prints the usage header and exits 0" {
  run "$AGENT_SLOT" --help
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "usage: agent-slot <verb>"* ]]
}

@test "every verb answers --help with its usage line and one example" {
  local verb
  for verb in repos list whoami doctor; do
    run "$AGENT_SLOT" "$verb" --help
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "usage: agent-slot $verb"* ]]
    [[ "$output" == *"example: agent-slot $verb"* ]]
  done
}

@test "every verb's help names the JSON fields it returns" {
  local verb
  for verb in repos list whoami launch resume warm check sweep finish doctor schema; do
    run "$AGENT_SLOT" "$verb" --help
    [ "$status" -eq 0 ]
    [[ $output == *$'\nreturns: '* ]] || { echo "no returns line: $verb"; false; }
  done
}

@test "schema prints the success and error envelopes and every reason the contract can return" {
  run --separate-stderr "$AGENT_SLOT" schema --output json
  [ "$status" -eq 0 ]
  expected=$(bash -c 'source "$1"; contract_reasons' _ "$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/contract.sh" | jaq -R -s -c 'split("\n") | map(select(. != ""))')
  jaq -e --argjson r "$expected" '.verb == "schema"
    and .error.properties.reason.enum == $r
    and ([.reasons[].reason] == $r)
    and (.error.required | index("next_step") != null)
    and (.success.required == ["schema", "ok", "verb"])
    and (.reasons[] | select(.reason == "slot-busy") | .exit_code == 1 and .retryable == true)' <<<"$output"
}

@test "with no usable jaq or jq, --output json still gets a complete dependency-missing error object" {
  required=$("$AGENT_SLOT" schema --output json | jaq -c '.error.required')
  run --separate-stderr env AGENT_SLOT_JQ="$T/no-such-jq" "$AGENT_SLOT" repos --output json
  [ "$status" -eq 78 ]
  jaq -e --argjson req "$required" '.reason == "dependency-missing" and .exit_code == 78
    and .next_step.action == "install" and .recovery.retryable == false
    and (keys - $req == [] and $req - keys == [])' <<<"$stderr"
  run --separate-stderr env AGENT_SLOT_JQ="$T/no-such-jq" "$AGENT_SLOT" repos
  [ "$status" -eq 78 ]
  [[ $stderr == "agent-slot: dependency-missing: "* ]]
}

@test "a tmux that never answers yields tmux-unresponsive within its bound" {
  stub tmux 'exec sleep 60'
  SECONDS=0
  run --separate-stderr timeout 30 "$AGENT_SLOT" list --output json
  [ "$status" -eq 1 ]
  ((SECONDS < 20))
  jaq -e '.reason == "tmux-unresponsive" and .recovery.retryable == true and (.log | type == "string")' <<<"$stderr"
  grep -q 'exit: 124' "$(jaq -r .log <<<"$stderr")"
}

@test "every error carries the full envelope, and unknown side effects come with a reconcile command" {
  local invocation
  slot repoa 1 '{"schema": "dotfiles.agent-slot/9"}'
  mkdir -p "$T/elsewhere"
  for invocation in "frobnicate" "whoami --path $T/elsewhere" "list" "list --bogus"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$AGENT_SLOT" $invocation --output json
    [ "$status" -ne 0 ]
    assert_error_shape "$stderr" || {
      echo "incomplete envelope from: $invocation"
      echo "$stderr"
      false
    }
  done
}

@test "a verb that dies unexpectedly reports script-error with a log path" {
  slot repoa 1
  echo 'not json' >"$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json"
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -ne 0 ]
  jaq -e '.reason == "script-error" and .exit_code == 1 and .recovery.side_effects == "unknown" and .recovery.reconcile != null' \
    <<<"$stderr"
  log=$(jaq -r .log <<<"$stderr")
  [ -f "$log" ]
  grep -q '^stopped at: ' "$log"
}

@test "a record from a newer schema is refused with record-schema-newer" {
  slot repoa 1 '{"schema": "dotfiles.agent-slot/2"}'
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "record-schema-newer" and .value == "dotfiles.agent-slot/2"' <<<"$stderr"
}

@test "a record from an older schema is read" {
  slot repoa 1 '{"schema": "dotfiles.agent-slot/0", "task": "old-task"}'
  echo repoa-1 >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '.slots[0].task == "old-task"' <<<"$output"
}

@test "a missing tmux yields dependency-missing naming it" {
  export AGENT_SLOT_TMUX=$T/no-such-tmux
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "dependency-missing" and .value == "tmux" and .next_step.action == "install"' <<<"$stderr"
}

@test "errors in text mode name the reason, the next step, and the help pointer" {
  run --separate-stderr "$AGENT_SLOT" whoami --path /
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"agent-slot: not-in-slot: "* ]]
  [[ "$stderr" == *"next: agent-slot list"* ]]
  [[ "$stderr" == *"see agent-slot whoami --help"* ]]
}

@test "context names AGENT_SLOT variables without their values" {
  export AGENT_SLOT_MARKER=secret-value-xyz
  run --separate-stderr "$AGENT_SLOT" whoami --path / --output json
  jaq -e '.context.env | index("AGENT_SLOT_MARKER") != null' <<<"$stderr"
  [[ "$stderr" != *secret-value-xyz* ]]
}
