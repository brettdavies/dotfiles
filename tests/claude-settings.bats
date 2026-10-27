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

# agent-slot takes its verb as the first argument, so `agent-slot sweep *`
# catches every flag order after it, and the bare verb too.
@test "agent-slot sweep and finish ask first" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.permissions.ask // [] | .[]' "$SETTINGS"
  [ "$status" -eq 0 ]
  grep -qxF 'Bash(agent-slot sweep *)' <<<"$output"
  grep -qxF 'Bash(agent-slot finish *)' <<<"$output"
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
