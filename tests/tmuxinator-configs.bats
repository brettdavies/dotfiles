#!/usr/bin/env bats
# Tests for the tmuxinator project configs
#
# Run: bats tests/tmuxinator-configs.bats

CONFIG_DIR="$BATS_TEST_DIRNAME/../stow/tmuxinator/dot-config/tmuxinator"
STOW_DEPLOY="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

# Read the `name:` field, trimming trailing space and surrounding quotes.
config_name() {
  sed -n 's/^name:[[:space:]]*//p' "$1" | head -1 |
    sed 's/[[:space:]]*$//; s/^"//; s/"$//'
}

# Session names appearing in `tmux resize-pane -t <session>:main.N` targets.
resize_targets() {
  sed -n 's/.*resize-pane -t "\{0,1\}\([^":]*\):main\.[0-9]*.*/\1/p' "$1"
}

# ---------------------------------------------------------------------------
# Config directory
# ---------------------------------------------------------------------------

@test "config directory exists and holds projects" {
  [ -d "$CONFIG_DIR" ]
  run bash -c "ls '$CONFIG_DIR'/*.yml | wc -l"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Required fields
# ---------------------------------------------------------------------------

@test "every config declares name and root" {
  failures=()
  for cfg in "$CONFIG_DIR"/*.yml; do
    base=$(basename "$cfg")
    [ -n "$(config_name "$cfg")" ] || failures+=("$base: missing 'name:'")
    grep -q '^root:[[:space:]]*[^[:space:]]' "$cfg" || failures+=("$base: missing 'root:'")
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Session-name consistency
#
# `tmuxinator copy` duplicates a config verbatim, leaving the source project's
# `name:` and resize targets behind. A mismatched target silently resizes a
# different session, or nothing at all.
# ---------------------------------------------------------------------------

@test "resize targets reference each config's own session name" {
  failures=()
  for cfg in "$CONFIG_DIR"/*.yml; do
    base=$(basename "$cfg")
    name=$(config_name "$cfg")
    [ -n "$name" ] || continue
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      [ "$target" = "$name" ] ||
        failures+=("$base: resize target '$target' does not match name '$name'")
    done < <(resize_targets "$cfg")
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

@test "session names are unique across configs" {
  run bash -c "
    for cfg in '$CONFIG_DIR'/*.yml; do
      sed -n 's/^name:[[:space:]]*//p' \"\$cfg\" | head -1 | sed 's/[[:space:]]*\$//; s/^\"//; s/\"\$//'
    done | sort | uniq -d
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Single source of truth
#
# tmuxinator searches ~/.config/tmuxinator in `start`/`stop` but not in `list`,
# so a config deployed there shadows the repo: it runs but never shows up.
# TMUXINATOR_CONFIG points at the repo directly, so nothing is stowed.
# ---------------------------------------------------------------------------

@test "tmuxinator is not a stow package" {
  run grep -E '^SHARED_PACKAGES=' "$STOW_DEPLOY"
  [ "$status" -eq 0 ]
  [[ "$output" != *" tmuxinator "* ]]
}

@test "no shadow configs at the XDG default path" {
  if [ ! -d "$HOME/.config/tmuxinator" ]; then
    skip "XDG tmuxinator directory does not exist"
  fi
  run bash -c "ls '$HOME/.config/tmuxinator'/*.yml 2>/dev/null | wc -l"
  [ "$output" -eq 0 ]
}
