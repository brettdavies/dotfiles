#!/usr/bin/env bats
# Tests for tmux-new-session script
#
# Run: bats tests/tmux-new-session.bats

SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/tmux-new-session"

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "tmux-new-session passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "tmux-new-session is executable" {
  [ -x "$SCRIPT" ]
}

@test "tmux-new-session uses bash" {
  head -1 "$SCRIPT" | grep -q "bash"
}

@test "tmux-new-session uses strict mode" {
  grep -q "set -euo pipefail" "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing arguments exits with error" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing repo path exits with error" {
  run "$SCRIPT" "test-session"
  [ "$status" -ne 0 ]
}

@test "nonexistent repo path exits with error" {
  run "$SCRIPT" "test-session" "/nonexistent/path/should/fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# ---------------------------------------------------------------------------
# Layout structure (verify generated tmuxinator YAML has expected panes)
#
# PR #67 refactored the script to generate a tmuxinator YAML config instead
# of issuing tmux commands directly. The tests below check the YAML template
# embedded in the heredoc inside the script.
# ---------------------------------------------------------------------------

@test "script generates main-vertical 3-pane layout" {
  # The generated YAML has three pane entries under `panes:` — yazi, an
  # empty placeholder, and lazygit. Count lines that look like pane entries.
  grep -q 'layout: main-vertical' "$SCRIPT"
  pane_count=$(awk '/panes:/{flag=1; next} flag && /^[^[:space:]]/{flag=0} flag && /^[[:space:]]+-/' "$SCRIPT" | wc -l)
  [ "$pane_count" -eq 3 ]
}

@test "script puts yazi in the first pane" {
  # First pane runs `y` (the exit-cd wrapper from shell-functions) with a
  # silent fallback to plain `yazi` if `y` isn't defined in the pane's shell.
  grep -qFe '- command -v y >/dev/null && y || yazi' "$SCRIPT"
}

@test "script puts lazygit in the third pane" {
  # `- lazygit` is the third pane entry in the YAML
  grep -q '^[[:space:]]*- lazygit$' "$SCRIPT"
}
