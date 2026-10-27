#!/usr/bin/env bats
# Trusting slot paths through Claude's own trust dialog: the screen check in launch, and agent-slot warm.
#
# Run: bats tests/agent-slot-trust.bats
#
# The scratch Claude runs in a stubbed tmux whose capture-pane prints $STUBS/screen; the fixture screens below copy
# the dialog Claude Code 2.1.310 shows. An Enter on the trust socket swaps in $STUBS/screen-after.

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/projects AGENT_SLOT_TRUST_TIMEOUT=3
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  prime repoa
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
}

untrust_prime() {
  jaq --arg p "$(realpath -m "$AGENT_SLOT_DEV/repoa")" 'del(.projects[$p])' "$AGENT_SLOT_CLAUDE_STATE" >"$T/state.new"
  mv "$T/state.new" "$AGENT_SLOT_CLAUDE_STATE"
}

# dialog_screen PATH [yes]: Claude's trust dialog naming PATH, with "No, exit" highlighted, or "Yes" with a second
# argument. The pre-approval warning is what Claude adds when the folder carries local permission rules.
dialog_screen() {
  local no='❯ No, exit' yes='  Yes, I trust this folder'
  if [ -n "${2:-}" ]; then
    no='  No, exit' yes='❯ Yes, I trust this folder'
  fi
  cat <<EOF
────────────────────────────────────────────────────────────────────────────────────────────────
 Accessing workspace:

 $1

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
 project, or work from your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 ⚠ This folder pre-approves 3 tool permissions in .claude/settings.local.json:
   Bash(ls:*), Read(//$1/**), and 1 more
 These will apply without asking. Only proceed if you trust this configuration.

 Security guide

 $no
 $yes

 Enter to confirm · Esc to cancel
EOF
}

prompt_screen() {
  cat <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.310
────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF
}

# dialog_fixture PATH: the dialog with No highlighted, Yes after a Down, and Claude's prompt after Enter.
dialog_fixture() {
  dialog_screen "$1" >"$STUBS/screen"
  dialog_screen "$1" yes >"$STUBS/screen-down"
  prompt_screen >"$STUBS/screen-after"
}

@test "AE15: a dialog naming the slot path is accepted with Down then Enter, and launch expects no prompt" {
  dialog_fixture "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.trust_prompt_expected == false' <<<"$output"
  grep -qF -- "-L agent-slot-trust -f /dev/null new-session -d -s trust-" "$CALLS"
  grep -qF -- "-c $AGENT_SLOT_ROOT/repoa/1 $STUBS/claude" "$CALLS"
  keys=$(grep -F -- '-L agent-slot-trust send-keys' "$CALLS" | awk '{ print $NF }' | paste -sd ' ')
  [ "$keys" = "Down Enter" ]
}

@test "launch of a repo whose prime checkout is untrusted sends no keys and expects the prompt" {
  untrust_prime
  dialog_fixture "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-untrusted --output json
  [ "$status" -eq 0 ]
  jaq -e '.trust_prompt_expected == true and .key == "repoa/1"' <<<"$output"
  [ "$(grep -cF -- '-L agent-slot-trust' "$CALLS")" -eq 0 ]
}

@test "warm of a repo whose prime checkout is untrusted trusts nothing and says why" {
  untrust_prime
  prompt_screen >"$STUBS/screen"
  run --separate-stderr "$AGENT_SLOT" warm repoa --count 2 --output json
  [ "$status" -eq 0 ]
  [ "$(jaq -c '[.paths[].result]' <<<"$output")" = '["prime-untrusted","prime-untrusted"]' ]
  [ "$(grep -cF -- '-L agent-slot-trust' "$CALLS")" -eq 0 ]
}

@test "a Down the dialog misses is sent again, and Enter goes only to a highlighted Yes" {
  dialog_fixture "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  touch "$STUBS/drop-first-down"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-lost --output json
  [ "$status" -eq 0 ]
  jaq -e '.trust_prompt_expected == false' <<<"$output"
  keys=$(grep -F -- '-L agent-slot-trust send-keys' "$CALLS" | awk '{ print $NF }' | paste -sd ' ')
  [ "$keys" = "Down Down Enter" ]
}

@test "a dialog naming another path sends no keys, and launch goes on expecting the prompt" {
  dialog_screen /somewhere/else >"$STUBS/screen"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r2 --output json
  [ "$status" -eq 0 ]
  jaq -e '.trust_prompt_expected == true and .key == "repoa/1"' <<<"$output"
  [ "$(grep -cF -- '-L agent-slot-trust send-keys' "$CALLS")" -eq 0 ]
  jaq -e '.trust_prompt_expected == true' "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json"
}

@test "an unknown screen sends no keys and yields trust-dialog-unrecognized from warm, with the screen in its log" {
  echo 'Something else entirely' >"$STUBS/screen"
  run --separate-stderr "$AGENT_SLOT" warm repoa --count 1 --output json
  [ "$status" -eq 78 ]
  jaq -e --arg p "$AGENT_SLOT_ROOT/repoa/1" '.reason == "trust-dialog-unrecognized" and .value == $p
    and .next_step.command == "cd \($p) && claude" and .next_step.action == "ask-operator"' <<<"$stderr"
  grep -q 'Something else entirely' "$(jaq -r .log <<<"$stderr")"
  [ "$(grep -cF -- '-L agent-slot-trust send-keys' "$CALLS")" -eq 0 ]
}

@test "Claude's prompt with no dialog counts the path as trusted and sends no keys" {
  prompt_screen >"$STUBS/screen"
  run --separate-stderr "$AGENT_SLOT" warm repoa --count 1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.paths == [{key: "repoa/1", path: .paths[0].path, result: "trusted"}]' <<<"$output"
  [ "$(grep -cF -- '-L agent-slot-trust send-keys' "$CALLS")" -eq 0 ]
}

@test "a dialog naming the slot's realpath is accepted when the slot root is reached through a symlink" {
  mkdir -p "$T/real-slots"
  ln -s "$T/real-slots" "$T/linked-slots"
  dialog_fixture "$T/real-slots/repoa/1"
  AGENT_SLOT_ROOT=$T/linked-slots run --separate-stderr "$AGENT_SLOT" warm repoa --count 1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.paths[0].result == "trusted"' <<<"$output"
}

@test "warm trusts paths 1-3, creating the empty directories, and leaves a path holding a clone alone" {
  slot repoa 2
  printf 'repoa-2\nrepoa-2-files\nrepoa-2-git\n' >"$STUBS/tmux-sessions"
  prompt_screen >"$STUBS/screen"
  run --separate-stderr "$AGENT_SLOT" warm repoa --count 3 --output json
  [ "$status" -eq 0 ]
  [ "$(jaq -c '[.paths[] | [.key, .result]]' <<<"$output")" = '[["repoa/1","trusted"],["repoa/2","in-use"],["repoa/3","trusted"]]' ]
  [ -d "$AGENT_SLOT_ROOT/repoa/1" ] && [ -d "$AGENT_SLOT_ROOT/repoa/3" ]
  [ "$(grep -c -- "-c $AGENT_SLOT_ROOT/repoa/2 " "$CALLS")" -eq 0 ]
}

@test "a warmed empty path is still free: the next launch clones into it" {
  prompt_screen >"$STUBS/screen"
  "$AGENT_SLOT" warm repoa --count 2 --output json >/dev/null
  trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r3 --output json
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1"' <<<"$output"
  [ -d "$AGENT_SLOT_ROOT/repoa/1/.git" ]
}

@test "launch skips the trust step for a path Claude already marks trusted" {
  trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r4 --output json
  [ "$status" -eq 0 ]
  [ "$(grep -cF -- '-L agent-slot-trust' "$CALLS")" -eq 0 ]
}
