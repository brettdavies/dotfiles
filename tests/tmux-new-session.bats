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
# Layout structure (verify script creates expected panes)
# ---------------------------------------------------------------------------

@test "script creates 3-pane layout" {
  # Verify split-window is called twice (creating 3 total panes)
  count=$(grep -c 'split-window' "$SCRIPT")
  [ "$count" -eq 2 ]
}

@test "script starts yazi in first pane" {
  grep -q 'send-keys.*yazi' "$SCRIPT"
}

@test "script starts lazygit in third pane" {
  grep -q 'send-keys.*lazygit' "$SCRIPT"
}
