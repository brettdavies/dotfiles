#!/usr/bin/env bats
# Tests for the PreToolUse WebFetch hook that redirects the first fetch of an
# HTML page to defuddle and lets a retry through.
#
# Run: bats tests/defuddle-webfetch.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/defuddle-webfetch.sh"

load lib/json-parser

PAGE='https://fail-closed-guard-test.invalid/article'

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  export DEFUDDLE_MARKER_DIR="$BATS_TEST_TMPDIR/markers"
}

fetch_payload() {
  jaq -nc --arg u "$1" '{tool_name: "WebFetch", tool_input: {url: $u, prompt: "summarize"}}'
}

reason() { jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"; }

markers() { find "$DEFUDDLE_MARKER_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }

@test "the first fetch of an HTML page is denied with the defuddle command" {
  run "$HOOK" <<<"$(fetch_payload "$PAGE")"
  [ "$status" -eq 0 ]
  [[ "$(reason)" == *"defuddle parse $PAGE --md"* ]]
  [ "$(markers)" -eq 1 ]
}

@test "a second fetch of the same page is allowed" {
  run "$HOOK" <<<"$(fetch_payload "$PAGE")"
  run "$HOOK" <<<"$(fetch_payload "$PAGE")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "binary files, localhost, and private addresses are allowed" {
  local url
  for url in https://example.invalid/paper.PDF http://localhost:8080/ http://192.168.1.10/status; do
    run "$HOOK" <<<"$(fetch_payload "$url")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ "$(markers)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Without a working JSON parser the guard blocks what it checks, never allows it
# ---------------------------------------------------------------------------

@test "with neither jaq nor jq, a fetch is blocked naming the fix and writes no marker" {
  run_hook_with_parser none "$HOOK" "$(fetch_payload "$PAGE")"
  assert_parser_block json-parser-missing
  [[ $REASON == "defuddle-webfetch blocked [json-parser-missing]: "* ]]
  [ "${REASON##*$'\n'}" = 'brew install jaq' ]
  [ "$(markers)" -eq 0 ]
}

@test "with jq and no jaq, the first fetch of an HTML page is denied" {
  run_hook_with_parser jq "$HOOK" "$(fetch_payload "$PAGE")"
  [ "$status" -eq 0 ]
  [[ "$(reason)" == *"defuddle parse $PAGE --md"* ]]
}

@test "with a jaq that fails, the guard blocks naming its own failure and writes no marker" {
  run_hook_with_parser broken "$HOOK" "$(fetch_payload "$PAGE")"
  assert_parser_block guard-internal-error
  [[ $REASON == "defuddle-webfetch failed [guard-internal-error] at line "* ]]
  [ "$(markers)" -eq 0 ]
}
