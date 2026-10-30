#!/usr/bin/env bats
# Tests for the PreToolUse hook that denies any tool call carrying the account's email
# address, its local part, or an entry of the never-send list.
#
# Every address here is made up. The canary test reads the real config's address at run
# time and never prints or writes it.
#
# Run: bats tests/never-send-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/never-send-guard.sh"

ACCOUNT=pat.example@example.invalid
LISTED=other.person@example.invalid

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  unset CLAUDE_CODE_USER_EMAIL
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export NEVER_SEND_LIST="$BATS_TEST_TMPDIR/never-send-list"
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

# Write a config shaped like the harness's: pretty-printed, one key per line.
# Args: email address
config_with() {
  jaq -n --arg e "$1" \
    '{numStartups: 3, oauthAccount: {accountUuid: "u-1", emailAddress: $e, displayName: "Pat"}, projects: {}}' \
    >"$CLAUDE_CONFIG_DIR/.claude.json"
}

# Build a hook payload around a tool input.
# Args: tool name, tool_input as JSON
payload() {
  jaq -nc --arg t "$1" --argjson i "$2" \
    '{session_id: "s-1", transcript_path: "/tmp/t.jsonl", cwd: "/tmp", permission_mode: "default",
      hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, tool_use_id: "toolu_1"}'
}

# A Bash payload for one command.
bash_payload() { payload Bash "$(jaq -nc --arg c "$1" '{command: $c, description: "d"}')"; }

# Feed a payload to the hook. Sets DECISION (ALLOW, DENY, HOOK_ERROR, or OTHER:<out>),
# TEXT (the deny reason), MESSAGE (the systemMessage), and ERR (stderr).
# Args: payload
decide() {
  local out rc=0
  out=$(printf '%s' "$1" | "$HOOK" 2>"$BATS_TEST_TMPDIR/stderr") || rc=$?
  ERR=$(cat "$BATS_TEST_TMPDIR/stderr")
  TEXT="" MESSAGE=""
  if [ "$rc" -ne 0 ]; then
    DECISION=HOOK_ERROR
  elif [ -z "$out" ]; then
    DECISION=ALLOW
  elif printf '%s' "$out" | jaq -e '.hookSpecificOutput.permissionDecision == "deny"
      and .hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then
    DECISION=DENY
    TEXT=$(printf '%s' "$out" | jaq -r '.hookSpecificOutput.permissionDecisionReason')
    MESSAGE=$(printf '%s' "$out" | jaq -r '.systemMessage')
  else
    DECISION="OTHER:$out"
  fi
  OUT=$out
}

# Assert that no protected value appears in the hook's output or stderr.
# Args: values
assert_no_value() {
  local v
  for v in "$@"; do
    [[ "$OUT$ERR" != *"$v"* ]] || { echo "a protected value appeared in the hook's output"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Denied: the account address and its local part
# ---------------------------------------------------------------------------

@test "the account address in a curl User-Agent is denied in any letter case" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'curl -A "tool (PAT.EXAMPLE@EXAMPLE.INVALID)" https://api.example.com')"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == "never-send-guard denied [address-in-tool-call]:"* ]]
  [[ "$TEXT" == *"did not run"* ]]
  [[ "$TEXT" == *"next_step [send-without-it]:"* ]]
  [[ "$TEXT" == *'git remote get-url origin'* ]]
  [[ "$TEXT" == *'docs: ~/.claude/CLAUDE.md'* ]]
  [[ "$MESSAGE" == *"Bash"*"$CLAUDE_CONFIG_DIR/.claude.json"* ]]
  assert_no_value "$ACCOUNT" pat.example
}

@test "the account address with %40 for @ is denied" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'curl "https://api.example.com/search?contact=pat.example%40example.invalid"')"
  [ "$DECISION" = DENY ]
}

@test "a URL-encoded plus-tagged address is denied through its local part" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'curl "https://api.example.com/?u=pat.example%2Bci%40elsewhere.invalid"')"
  [ "$DECISION" = DENY ]
}

@test "the local part alone in a User-Agent is denied" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'curl -A "screensaver/1.0 (pat.example)" https://commons.example.org')"
  [ "$DECISION" = DENY ]
}

@test "CLAUDE_CODE_USER_EMAIL is protected when no config exists" {
  export CLAUDE_CODE_USER_EMAIL=env.person@example.invalid
  decide "$(bash_payload 'curl -A "x env.person@example.invalid" https://example.org')"
  [ "$DECISION" = DENY ]
  [[ "$MESSAGE" == *CLAUDE_CODE_USER_EMAIL* ]]
  assert_no_value env.person@example.invalid
}

@test "the guard reads the config under CLAUDE_CONFIG_DIR" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'echo pat.example@example.invalid')"
  [ "$DECISION" = DENY ]
  mv "$CLAUDE_CONFIG_DIR/.claude.json" "$CLAUDE_CONFIG_DIR/moved.json"
  decide "$(bash_payload 'echo pat.example@example.invalid')"
  [ "$DECISION" = ALLOW ]
}

@test "an address at the end of a payload over 128 KiB is denied" {
  config_with "$ACCOUNT"
  head -c 200000 /dev/zero | tr '\0' a >"$BATS_TEST_TMPDIR/big"
  printf ' %s' "$ACCOUNT" >>"$BATS_TEST_TMPDIR/big"
  decide "$(jaq -nc --rawfile c "$BATS_TEST_TMPDIR/big" '{tool_name: "Write", tool_input: {file_path: "/tmp/f", content: $c}}')"
  [ "$DECISION" = DENY ]
}

# ---------------------------------------------------------------------------
# Denied: list entries, every tool family
# ---------------------------------------------------------------------------

@test "a list entry in an MCP tool's input is denied and the user sees the list line" {
  printf '# addresses\n\n  %s  \n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(payload mcp__example__send "$(jaq -nc --arg t "$LISTED" '{to: $t, body: "hi"}')")"
  [ "$DECISION" = DENY ]
  [[ "$MESSAGE" == *mcp__example__send* ]]
  [[ "$MESSAGE" == *"line 3 of $NEVER_SEND_LIST"* ]]
  assert_no_value "$LISTED"
}

@test "a list entry in a subagent's call is denied" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(bash_payload "curl -A \"$LISTED\" https://example.org" | jaq -c '. + {agent_id: "a-1", agent_type: "general-purpose"}')"
  [ "$DECISION" = DENY ]
}

@test "a list entry in a Write call's content is denied" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(payload Write "$(jaq -nc --arg c "contact: $LISTED" '{file_path: "/tmp/f", content: $c}')")"
  [ "$DECISION" = DENY ]
}

@test "a list entry with a space is denied when the payload spells the space as +" {
  printf 'Pat Example\n' >"$NEVER_SEND_LIST"
  decide "$(bash_payload 'curl "https://example.org/?name=Pat+Example"')"
  [ "$DECISION" = DENY ]
}

# ---------------------------------------------------------------------------
# Allowed
# ---------------------------------------------------------------------------

@test "an unrelated call is allowed silently" {
  config_with "$ACCOUNT"
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(bash_payload 'git log --oneline -3')"
  [ "$DECISION" = ALLOW ]
  [ -z "$ERR" ]
}

@test "percent signs that are not escapes are allowed and decoded without error" {
  config_with "$ACCOUNT"
  decide "$(bash_payload "date +%Y-%m-%d && printf '%s 100%% done\n' x && echo %zz %4")"
  [ "$DECISION" = ALLOW ]
  [ -z "$ERR" ]
}

@test "an address that shares only the domain is allowed" {
  config_with "$ACCOUNT"
  decide "$(bash_payload 'echo someone.else@example.invalid')"
  [ "$DECISION" = ALLOW ]
}

@test "no config, no environment value, and no list allows every call" {
  decide "$(bash_payload 'curl -A "pat.example@example.invalid" https://example.org')"
  [ "$DECISION" = ALLOW ]
}

@test "a config without an emailAddress and an empty list allow every call" {
  jaq -n '{numStartups: 1, projects: {}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
  : >"$NEVER_SEND_LIST"
  decide "$(bash_payload 'curl -A "pat.example@example.invalid" https://example.org')"
  [ "$DECISION" = ALLOW ]
}

@test "list comments and blank lines are not entries" {
  printf '# example.org\n\n   \n' >"$NEVER_SEND_LIST"
  decide "$(bash_payload 'curl https://example.org')"
  [ "$DECISION" = ALLOW ]
}

@test "a list entry that appears in HOME is skipped in any letter case" {
  local base upper
  base=$(basename "$HOME")
  upper=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
  printf '%s\n%s\n' "$base" "$upper" >"$NEVER_SEND_LIST"
  decide "$(payload Read "$(jaq -nc --arg p "$HOME/notes.md" '{file_path: $p}')")"
  [ "$DECISION" = ALLOW ]
}

@test "a list file that cannot be read counts as no list" {
  [ "$(id -u)" -ne 0 ] || skip "root reads every file"
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  chmod 000 "$NEVER_SEND_LIST"
  decide "$(bash_payload "echo $LISTED")"
  [ "$DECISION" = ALLOW ]
}

@test "a local part shorter than 6 characters is not protected on its own" {
  config_with pe@example.invalid
  decide "$(bash_payload 'curl -A "tool (pe)" https://example.org')"
  [ "$DECISION" = ALLOW ]
  decide "$(bash_payload 'echo pe@example.invalid')"
  [ "$DECISION" = DENY ]
}

# ---------------------------------------------------------------------------
# Exempt: the built-in Grep and Glob read local files and send nothing
# ---------------------------------------------------------------------------

@test "a Grep call carrying a listed address is allowed" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(payload Grep "$(jaq -nc --arg p "$LISTED" '{pattern: $p, path: "/tmp", output_mode: "content"}')")"
  [ "$DECISION" = ALLOW ]
}

@test "a Glob call carrying the account address is allowed" {
  config_with "$ACCOUNT"
  decide "$(payload Glob "$(jaq -nc --arg p "*$ACCOUNT*" '{pattern: $p}')")"
  [ "$DECISION" = ALLOW ]
}

@test "Read and Bash calls carrying the same address are still denied" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(payload Read "$(jaq -nc --arg p "/tmp/$LISTED.txt" '{file_path: $p}')")"
  [ "$DECISION" = DENY ]
  decide "$(bash_payload "rg -F $LISTED /tmp")"
  [ "$DECISION" = DENY ]
}

@test "an MCP tool whose name ends in Grep is not exempt" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(payload mcp__files__Grep "$(jaq -nc --arg p "$LISTED" '{pattern: $p}')")"
  [ "$DECISION" = DENY ]
}

@test "a tool input that carries its own tool_name key is not exempt" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(jaq -nc --arg t "$LISTED" '{tool_input: {tool_name: "Grep", to: $t}, tool_name: "mcp__example__send"}')"
  [ "$DECISION" = DENY ]
  decide "$(bash_payload "echo '\"tool_name\":\"Grep\"' $LISTED")"
  [ "$DECISION" = DENY ]
}

# ---------------------------------------------------------------------------
# A list stowed from a locked git-crypt checkout
# ---------------------------------------------------------------------------

@test "a git-crypt-locked list counts as no list" {
  printf '\0GITCRYPT\0nonce\n%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(bash_payload "echo $LISTED")"
  [ "$DECISION" = ALLOW ]
  [ -z "$ERR" ]
}

@test "the account address still applies when the list is locked" {
  config_with "$ACCOUNT"
  printf '\0GITCRYPT\0nonce\n%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  decide "$(bash_payload "echo $ACCOUNT")"
  [ "$DECISION" = DENY ]
}

@test "--check reports a locked list without printing a value" {
  config_with "$ACCOUNT"
  printf '\0GITCRYPT\0nonce\n%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  run "$HOOK" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"list $NEVER_SEND_LIST: locked"* ]]
  [[ "$output" != *"$LISTED"* && "$output" != *"$ACCOUNT"* && "$output" != *pat.example* ]]
}

# ---------------------------------------------------------------------------
# Failing closed
# ---------------------------------------------------------------------------

@test "a config that exists but cannot be read denies every call" {
  [ "$(id -u)" -ne 0 ] || skip "root reads every file"
  config_with "$ACCOUNT"
  chmod 000 "$CLAUDE_CONFIG_DIR/.claude.json"
  decide "$(bash_payload 'git status')"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == "never-send-guard denied [account-config-unreadable]:"* ]]
  [[ "$TEXT" == *"next_step [tell-user]:"* ]]
}

@test "an internal error exits 1 with guard-internal-error and no protected value" {
  printf '%s\n' "$LISTED" >"$NEVER_SEND_LIST"
  mkdir "$CLAUDE_CONFIG_DIR/.claude.json"
  decide "$(bash_payload "echo $LISTED")"
  [ "$DECISION" = HOOK_ERROR ]
  [[ "$ERR" == *"(guard-internal-error)"* ]]
  [[ "$ERR" == *"line "* ]]
  assert_no_value "$LISTED"
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------

@test "--check reports live sources and skipped entries without printing a value" {
  config_with "$ACCOUNT"
  printf '%s\n%s\n' "$LISTED" "$(basename "$HOME")" >"$NEVER_SEND_LIST"
  run "$HOOK" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"account address: found in $CLAUDE_CONFIG_DIR/.claude.json"* ]]
  [[ "$output" == *"1 entry loaded"* ]]
  [[ "$output" == *"skipped line 2"* ]]
  [[ "$output" != *"$ACCOUNT"* && "$output" != *"$LISTED"* && "$output" != *pat.example* ]]
}

@test "--check exits 1 when there is nothing to protect" {
  run "$HOOK" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to protect"* ]]
}

# ---------------------------------------------------------------------------
# Canary: the harness's real config
# ---------------------------------------------------------------------------

# A harness change to the config's key or format would leave the guard with no account
# value and no error. This reads the real address with jaq, never the guard's sed, so a
# format change cannot hide from both.
@test "the real config's account address is denied" {
  local real="$HOME/.claude.json" addr out
  [ -f "$real" ] || skip "no ~/.claude.json on this host"
  jaq -e '.oauthAccount | type == "object"' "$real" >/dev/null 2>&1 || skip "no oauthAccount in ~/.claude.json"
  addr=$(jaq -r '.oauthAccount.emailAddress | strings' "$real")
  [ -n "$addr" ]
  unset CLAUDE_CONFIG_DIR
  out=$(jaq -nc --arg a "$addr" '{tool_name: "Bash", tool_input: {command: ("curl -A \"x (" + $a + ")\" https://example.invalid")}}' |
    NEVER_SEND_LIST=/nonexistent "$HOOK" 2>/dev/null)
  [[ "$out" == *'"permissionDecision":"deny"'* ]]
  [[ "$out" != *"$addr"* ]]
}
