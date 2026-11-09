#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-review-cap.sh, the Claude hook that caps a slot's review rounds per PR: a call
# of the ce-code-review skill is one round for the PR on the slot's current branch, and a third is denied.
#
# Run: bats tests/slot-review-cap.bats
#
# The fixtures are those of tests/slot-unattended.bats: a pane shell that records its own pid as the pane's
# #{pane_pid}, then `claude` (a symlink to bash, so /proc comm reads claude), then the hook.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-review-cap.sh"
RUNS='"$@"; exit $?'
REVIEW=compound-engineering:ce-code-review

setup_file() {
  load lib/platform
  require_linux "the hook finds the pane's top-level Claude through /proc"
}

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" TMUX_PANE=%3
  FAKE=$T/fake
  mkdir -p "$FAKE"
  ln -s "$(command -v bash)" "$FAKE/claude"
  printf '%s' repo-1 >"$STUBS/pane-session"
  printf '#!/usr/bin/env bash\nprintf %%s "$$" >"$STUBS/pane-pid"\n"$@"\nexit $?\n' >"$T/pane-shell"
  chmod +x "$T/pane-shell"
  stub tmux '
case " $* " in
  *" display "*) printf "%s\t%s\t%s\n" "$(cat "$STUBS/pane-session")" "$(cat "$STUBS/pane-pid")" /dev/null ;;
esac'
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  slot repo 1 '{"created_at": "2020-01-01T00:00:00Z"}'
  git -C "$SLOT" symbolic-ref HEAD refs/heads/feat/one
  git -C "$SLOT" commit -q --allow-empty -m seed
  SHA=$(git -C "$SLOT" rev-parse --short HEAD)
  HOOKS_LOG=$AGENT_SLOT_STATE_DIR/logs/hooks.log
}

fire() { "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK"; }

# skill NAME [CWD]: a PreToolUse payload for the Skill tool, from the slot's Claude, which works in CWD (default: the
# slot).
skill() {
  jaq -n -c --arg cwd "${2:-$SLOT}" --arg s "$1" '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd,
    tool_name: "Skill", tool_input: {skill: $s, args: "mode:report-only"}, tool_use_id: "tu1"}' | fire
}

# bash COMMAND: a PreToolUse payload for the Bash tool, from the slot's Claude.
bash_call() {
  jaq -n -c --arg cwd "$SLOT" --arg c "$1" '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd,
    tool_name: "Bash", tool_input: {command: $c, run_in_background: true}, tool_use_id: "tu2"}' | fire
}

# A review as the agent-slot skill runs it: `claude -p` from a throwaway clone of the pushed head.
CLONE_REVIEW='cd /tmp/rv && CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 timeout -s INT -k 30 2400 claude -p --model claude-opus-5-5 --effort high "/compound-engineering:ce-code-review PR #12, base dev" >review.json'

ledger() { jaq -c "select(.event == \"$1\")" "$LEDGER" 2>/dev/null || true; }

# review: a ce-code-review call that the hook allows, so it prints nothing.
review() {
  run skill "$REVIEW" "${1:-}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# grant: the operator's grant of one more round for the slot's current branch, run outside the slot and its tmux.
grant() { env -u TMUX -u TMUX_PANE bash -c 'cd "$1" && shift && exec "$@" --output json' _ "$T" "$AGENT_SLOT" grant-review repo/1; }

@test "two review rounds are allowed and each is recorded for the slot's branch" {
  review
  review
  run ledger review-round
  [ "$(wc -l <<<"$output")" -eq 2 ]
  jaq -e '.repo == "repo" and .slot == 1 and .branch == "feat/one" and .session_id == "s1"' <<<"${lines[0]}"
}

@test "the third round is denied with the rule, the count, and the step that goes on" {
  review
  review
  run skill "$REVIEW"
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"at most 2 review rounds per PR"* ]]
  [[ $reason == *"feat/one has had 2"* ]]
  [[ $reason == *"a second only to review round 1's P0 and P1 fixes"* ]]
  [[ $reason == *"coordinating session the PR, its head SHA ($SHA), and why, as one"* ]]
  [[ $reason == *"If your brief names no such session"* ]]
  [[ $reason == *"it or the operator can allow one more round by running \`agent-slot grant-review repo/1\`"* ]]
  [[ $reason == *"you cannot run yourself"* ]]
  [[ $reason == *"branch feat/one"* ]]
  [ "$(ledger review-round | wc -l)" -eq 2 ]
}

@test "the denial names the PR the slot's record holds" {
  jaq -c '.prs = [12, 463]' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  review
  review
  run skill "$REVIEW"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"coordinating session PR #463, its head SHA ($SHA), and why"* ]]
}

@test "a grant allows exactly one more round on that branch" {
  review
  review
  run grant
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .verb == "grant-review" and .branch == "feat/one" and .rounds == 2 and .allowed == 3' \
    <<<"$output"
  jaq -e '.repo == "repo" and .slot == 1 and .branch == "feat/one"' <<<"$(ledger review-grant)"
  review
  run skill "$REVIEW"
  jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"allows 2 review rounds per PR plus 1 granted"* ]]
  [[ $reason == *"feat/one has had 3"* ]]
}

@test "a skill name with a leading slash or surrounding space is counted as the same skill" {
  local name
  for name in "/$REVIEW" " $REVIEW " "/ $REVIEW"; do
    : >"$LEDGER"
    run skill "$name"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(ledger review-round | wc -l)" -eq 1 ]
  done
}

@test "the bare skill name ce-code-review is counted too, since Claude Code runs it as an alias" {
  run skill ce-code-review
  [ -z "$output" ]
  run skill "/ce-code-review"
  [ -z "$output" ]
  [ "$(ledger review-round | wc -l)" -eq 2 ]
  run skill ce-code-review
  [[ $output == *'"deny"'* ]]
}

@test "a detached head counts its rounds under the commit" {
  git -C "$SLOT" checkout -q --detach
  review
  review
  jaq -e --arg sha "$(git -C "$SLOT" rev-parse HEAD)" '.branch == $sha' <<<"$(ledger review-round | head -n 1)"
  run skill "$REVIEW"
  [[ $output == *'"deny"'* ]]
}

@test "a round that cannot be written is logged and the call is allowed" {
  review
  chmod 444 "$LEDGER"
  run skill "$REVIEW"
  [ -z "$output" ]
  grep -q 'review-round line not written' "$HOOKS_LOG"
}

@test "a review called from a directory outside the slot counts for the slot the pane belongs to" {
  mkdir -p "$T/scratch"
  run skill "$REVIEW" "$T/scratch"
  [ -z "$output" ]
  review
  run skill "$REVIEW" "$T/scratch"
  [[ $output == *'"deny"'* ]]
  jaq -e '.repo == "repo" and .slot == 1 and .branch == "feat/one"' <<<"$(ledger review-round | head -n 1)"
}

@test "a line in the ledger that is not JSON does not stop the count" {
  review
  printf '%s\n' 'not json {' >>"$LEDGER"
  review
  run skill "$REVIEW"
  [[ $output == *'"deny"'* ]]
}

@test "a slot whose record cannot be read has its call allowed and uncounted" {
  review
  review
  rm "$SLOT/.git/agent-slot.json"
  run skill "$REVIEW"
  [ -z "$output" ]
  [ "$(ledger review-round | wc -l)" -eq 2 ]
}

@test "a different branch counts its rounds separately" {
  review
  review
  git -C "$SLOT" symbolic-ref HEAD refs/heads/feat/two
  review
  review
  run skill "$REVIEW"
  [[ $output == *'"deny"'* ]]
  [[ $output == *"feat/two has had 2"* ]]
}

@test "another slot counts its rounds separately" {
  review
  review
  slot repo 2
  git -C "$AGENT_SLOT_ROOT/repo/2" symbolic-ref HEAD refs/heads/feat/one
  printf '%s' repo-2 >"$STUBS/pane-session"
  review "$AGENT_SLOT_ROOT/repo/2"
  review "$AGENT_SLOT_ROOT/repo/2"
  run skill "$REVIEW" "$AGENT_SLOT_ROOT/repo/2"
  [[ $output == *"repo/2"* ]]
}

@test "rounds from before the slot was made do not count against a reused slot" {
  review
  review
  jaq -c '.created_at = "2999-01-01T00:00:00Z"' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  review
}

@test "a skill other than ce-code-review is never counted" {
  for name in compound-engineering:ce-compound devex-review cso compound-engineering:ce-code-reviewer; do
    run skill "$name"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$LEDGER" ]
}

@test "a review started as claude -p from a Bash call counts as a round" {
  run bash_call "$CLONE_REVIEW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jaq -e '.repo == "repo" and .slot == 1 and .branch == "feat/one"' <<<"$(ledger review-round)"
}

@test "a third review started from a Bash call is denied, after rounds from either path" {
  review
  run bash_call "$CLONE_REVIEW"
  [ -z "$output" ]
  run bash_call "$CLONE_REVIEW"
  jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
  [ "$(ledger review-round | wc -l)" -eq 2 ]
}

@test "a Bash call that only names ce-code-review, or starts no claude, is not counted" {
  local c
  for c in 'rg -n ce-code-review ~/.claude/plugins' 'cat ~/.claude/skills/ce-code-review/SKILL.md' \
    'gh pr comment 12 --body-file /tmp/ce-code-review-round-1.md' 'claude -p "/compound-engineering:ce-code-reviewer x"' \
    'claude -p "/devex-review"' 'jaq .result review.json'; do
    run bash_call "$c"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$LEDGER" ]
}

@test "a subagent's review call counts as the slot's round" {
  review
  run fire < <(jaq -n -c --arg cwd "$SLOT" --arg s "$REVIEW" \
    '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd, tool_name: "Skill", tool_input: {skill: $s},
      agent_id: "a7", agent_type: "general-purpose"}')
  [ -z "$output" ]
  [ "$(ledger review-round | wc -l)" -eq 2 ]
}

@test "outside a slot the hook prints nothing and records nothing" {
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run skill "$REVIEW"
  [ -z "$output" ]
  run skill "$REVIEW"
  run skill "$REVIEW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unset TMUX
  run skill "$REVIEW"
  [ -z "$output" ]
  printf '%s' repo-1-files >"$STUBS/pane-session"
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0"
  run skill "$REVIEW"
  run skill "$REVIEW"
  run skill "$REVIEW"
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
}

@test "a ledger that cannot be read or written leaves the call allowed" {
  mkdir -p "$LEDGER" "$LEDGER.lock"
  run skill "$REVIEW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a malformed payload prints nothing and exits 0" {
  run fire <<<'not json {'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
