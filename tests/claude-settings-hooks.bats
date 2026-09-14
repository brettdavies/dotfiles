#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/settings.json, which deploys to every
# machine as ~/.claude/settings.json.
#
# Run: bats tests/claude-settings-hooks.bats

SETTINGS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json"

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
