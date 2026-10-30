#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/settings.json, which deploys to every
# machine as ~/.claude/settings.json.
#
# Run: bats tests/claude-settings.bats
#
# CLAUDE_SETTINGS_FILE points the checks at another copy of the file, which is
# how a captured regression is replayed against them.

SETTINGS="${CLAUDE_SETTINGS_FILE:-$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json}"
REPO="$BATS_TEST_DIRNAME/.."

# A hook command runs through /bin/sh on every machine this file deploys to.
# A path under one machine's $HOME (/home/<user> on Linux, /Users/<user> on
# macOS) resolves nowhere else, and Claude Code reports the miss on every
# event that fires the hook. gstack's ./setup registers its hooks with exactly
# such a path by design, so its entries must never be synced into this file;
# a $HOME-relative form expands under sh and travels.
@test "hook commands carry no machine-absolute home paths" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.hooks // {} | .[][] | .hooks[]? | .command // empty' "$SETTINGS"
  [ "$status" -eq 0 ]
  commands="$output"
  run grep -nE '/(home|Users)/' <<<"$commands"
  echo "hook commands with a machine-absolute home path:"
  echo "$output"
  [ "$status" -eq 1 ]
}

# A running Claude Code session holds this file in memory and can serialize that
# snapshot back over ~/.claude/settings.json, which is a symlink into this repo
# on a deployed host. A session that started before an `env` key landed writes
# that key back out of existence, and the loss is silent: the file stays valid
# JSON, so the only symptom is the live config quietly no longer carrying the
# setting.
#
# The expected keys come from HEAD instead of a list held here, so adding,
# renaming or removing an `env` key needs no change to this test. That also
# bounds where the check has signal: it compares the working tree against the
# commit, so it can only fire where the two differ, which is a developer
# machine. CI checks out one tree and passes trivially.
@test "env block keeps every key committed in HEAD" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  git -C "$REPO" rev-parse --verify HEAD >/dev/null 2>&1 || skip "not a git checkout"

  committed="$(git -C "$REPO" show HEAD:stow/claude/dot-claude/settings.json 2>/dev/null)"
  [ -n "$committed" ] || skip "settings.json absent from HEAD"

  run jaq -r '.env // {} | keys[]' <<<"$committed"
  [ "$status" -eq 0 ]
  committed_keys="$output"

  run jaq -r '.env // {} | keys[]' "$SETTINGS"
  [ "$status" -eq 0 ]
  current_keys="$output"

  missing=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" <<<"$current_keys" || missing+=("$key")
  done <<<"$committed_keys"

  echo "env keys committed in HEAD but missing from $SETTINGS: ${missing[*]:-none}"
  [ "${#missing[@]}" -eq 0 ]
}

# Permission rules match the command text an agent types. A rule keyed on one
# machine's $HOME never matches on another, so it silently re-prompts there
# and the allow-list drifts apart per host; the `~` form matches on every
# machine. /home/linuxbrew is Linuxbrew's fixed prefix, not a user home, and
# stays.
@test "permission rules carry no machine-absolute home paths" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.permissions // {} | (.allow // []) + (.deny // []) + (.ask // []) | .[]' "$SETTINGS"
  [ "$status" -eq 0 ]
  rules="$output"
  run bash -c 'grep -nE "/(home|Users)/" | grep -v "/home/linuxbrew/"' <<<"$rules"
  echo "permission rules with a machine-absolute home path:"
  echo "$output"
  [ "$status" -eq 1 ]
}

# Hook scripts deploy into ~/.claude through the claude stow package, and the
# `~` form is the one path that resolves on every machine.
@test "hook commands name scripts under ~/.claude by the ~ path" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.hooks // {} | .[][] | .hooks[]? | .command // empty' "$SETTINGS"
  [ "$status" -eq 0 ]
  commands="$output"
  run bash -c "grep -oE '[^[:space:]\"(]*\\.claude/' | grep -vxF '~/.claude/'" <<<"$commands"
  echo "hook commands reaching ~/.claude by another path:"
  echo "$output"
  [ "$status" -eq 1 ]
}

# Async Claude hooks can finish out of order, and the slot status hook is
# written for that; registered synchronously it would hold up every tool call.
@test "slot-status.sh is registered async on every status event" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -c '["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Elicitation", "PreToolUse",
      "Stop", "StopFailure", "SessionEnd"]
    - [.hooks | to_entries[]
       | select(any(.value[]; any(.hooks[]; .command == "~/.claude/slot-status.sh" and .async == true)))
       | .key]' "$SETTINGS"
  echo "events without an async slot-status.sh: $output"
  [ "$output" = "[]" ]
  run jaq -c '[.hooks.PreToolUse[] | select(any(.hooks[]; .command == "~/.claude/slot-status.sh")) | .matcher]' \
    "$SETTINGS"
  [ "$output" = '["AskUserQuestion"]' ]
  run jaq -c '[.hooks.SessionStart[] | .hooks[] | select(.command == "~/.claude/slot-context.sh")] | length' "$SETTINGS"
  [ "$output" = 1 ]
}

# With no matcher the guard sees every tool, MCP tools and subagents' calls included.
# Without onFailure a guard that crashes, times out, or is missing lets the call through.
@test "never-send-guard.sh runs on every tool call and blocks when it fails" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -c '[.hooks.PreToolUse[] | select(any(.hooks[]; .command == "~/.claude/never-send-guard.sh"))]' "$SETTINGS"
  [ "$status" -eq 0 ]
  groups="$output"
  run jaq -e 'length == 1 and (.[0] | has("matcher") | not)' <<<"$groups"
  echo "PreToolUse groups running the guard: $groups"
  [ "$status" -eq 0 ]
  run jaq -e '.[0].hooks[] | select(.command == "~/.claude/never-send-guard.sh")
    | .onFailure == "block" and (.timeout | type == "number") and (has("async") | not)' <<<"$groups"
  [ "$status" -eq 0 ]
}

# agent-slot takes its verb as the first argument, so `agent-slot sweep *`
# catches every flag order after it, and the bare verb too. An ask rule still
# prompts in bypass permissions mode, which every slot's Claude starts in, so
# these rules are what stop a slot's agent from deleting slots, or reopening a
# torn-down slot's conversation, unasked.
@test "agent-slot sweep, finish, and reopen ask first" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.permissions.ask // [] | .[]' "$SETTINGS"
  [ "$status" -eq 0 ]
  grep -qxF 'Bash(agent-slot sweep *)' <<<"$output"
  grep -qxF 'Bash(agent-slot finish *)' <<<"$output"
  grep -qxF 'Bash(agent-slot reopen *)' <<<"$output"
}

# agent-slot starts every slot's Claude with --dangerously-skip-permissions.
# Without this acceptance on record, each one stops on the bypass permissions
# warning until someone answers it in the slot's tab.
@test "bypass permissions mode stays accepted for agent-slot's Claude sessions" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -e '.skipDangerousModePermissionPrompt == true' "$SETTINGS"
  [ "$status" -eq 0 ]
}

# Slot sessions run with --dangerously-skip-permissions while a session the
# operator opens prompts. Left unset, Claude Code holds a message between the
# two for approval, so a hand-off from a slot sits undelivered until someone
# answers it in the receiving session's terminal.
@test "cross-session messages are delivered without an approval hold" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -e '.crossSessionInbound == "accept"' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "agent-slot's read-only verbs run without a prompt" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.permissions.allow // [] | .[]' "$SETTINGS"
  [ "$status" -eq 0 ]
  local verb
  for verb in repos list whoami check doctor schema; do
    grep -qxF "Bash(agent-slot $verb *)" <<<"$output" || { echo "missing allow rule: $verb"; false; }
  done
}

# adopt changes only a slot's record and its Claude session's name, so it runs
# without a prompt; an ask rule on it would prompt even in bypass mode.
@test "agent-slot adopt runs without a prompt, and nothing asks first" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.permissions.allow // [] | .[]' "$SETTINGS"
  grep -qxF 'Bash(agent-slot adopt *)' <<<"$output"
  run jaq -r '.permissions.ask // [] | .[]' "$SETTINGS"
  [[ $output != *'agent-slot adopt'* ]]
}

# agent-slot reopen resumes a torn-down slot's Claude conversation by its session ID, and Claude Code deletes a
# transcript once it has been idle for cleanupPeriodDays (30 when unset).
@test "Claude Code keeps session transcripts for a year" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -e '.cleanupPeriodDays == 365' "$SETTINGS"
  [ "$status" -eq 0 ]
}

# Without onFailure "block", a guard that crashes, hangs, or is missing lets
# the call through. Hooks that only advise or report must not stop a call
# when they fail, so they are the exemptions.
@test "every PreToolUse guard blocks the call when the guard itself fails" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.hooks.PreToolUse[].hooks[] | select(.type == "command" and .onFailure != "block") | .command' "$SETTINGS"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2088 # settings.json names hooks by the literal ~ path
  local exempt=('~/.claude/slot-status.sh' '~/.claude/skills/1password/hooks/op-skill-nudge.sh')
  local cmd missing=()
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    [[ " ${exempt[*]} " == *" $cmd "* ]] || missing+=("$cmd")
  done <<<"$output"
  echo "PreToolUse hooks without onFailure \"block\": ${missing[*]:-none}"
  echo "add \"onFailure\": \"block\" to each, or add it to this test's exemptions if it never denies"
  [ "${#missing[@]}" -eq 0 ]
  run jaq -r '.hooks.PreToolUse[].hooks[] | select(.command == "~/.claude/slot-status.sh"
    or .command == "~/.claude/skills/1password/hooks/op-skill-nudge.sh") | .onFailure // "unset"' "$SETTINGS"
  [ "$(sort -u <<<"$output")" = unset ]
}

# Under onFailure "block" a missing script blocks every call its matcher names,
# on every host that pulls the change, so each one must be a script the claude
# package ships at the path the command names.
@test "every hook that blocks on failure names an executable script the claude package ships" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.hooks[][].hooks[]? | select(.onFailure == "block") | .command' "$SETTINGS"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local cmd bad=()
  while IFS= read -r cmd; do
    # shellcheck disable=SC2088 # settings.json names hooks by the literal ~ path
    [[ $cmd == '~/.claude/'* && -f "$REPO/stow/claude/dot-claude/${cmd#\~/.claude/}" &&
      -x "$REPO/stow/claude/dot-claude/${cmd#\~/.claude/}" ]] || bad+=("$cmd")
  done <<<"$output"
  echo "block-on-failure hooks naming no executable under stow/claude/dot-claude: ${bad[*]:-none}"
  [ "${#bad[@]}" -eq 0 ]
}
