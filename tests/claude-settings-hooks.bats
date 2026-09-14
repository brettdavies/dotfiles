#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/settings.json, which deploys to every
# machine as ~/.claude/settings.json.
#
# Run: bats tests/claude-settings-hooks.bats
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
