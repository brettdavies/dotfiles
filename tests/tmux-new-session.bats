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

# ---------------------------------------------------------------------------
# Config resolution
#
# The script writes configs into the dotfiles tmuxinator package and then calls
# `tmuxinator start`. tmuxinator only finds them via TMUXINATOR_CONFIG, which
# config/shell/tmuxinator.sh exports at shell startup. Callers that never source
# the dotfiles profile — launchd, cron, `ssh host tmux-new-session ...` — reach
# the script with that variable unset, so it must export it itself.
# ---------------------------------------------------------------------------

@test "script exports TMUXINATOR_CONFIG rather than relying on the caller" {
  grep -q '^export TMUXINATOR_CONFIG=' "$SCRIPT"
}

@test "script resolves its config dir with no dotfiles profile in the environment" {
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  stub_dir="$(mktemp -d)"

  # Stub tmux so has-session reports "not running" without touching a real
  # server, and stub tmuxinator so it reports the variable it was handed.
  cat >"$stub_dir/tmux" <<'STUB'
#!/bin/sh
[ "$1" = "has-session" ] && exit 1
exit 0
STUB
  cat >"$stub_dir/tmuxinator" <<'STUB'
#!/bin/sh
echo "TMUXINATOR_CONFIG=${TMUXINATOR_CONFIG:-UNSET}"
STUB
  chmod +x "$stub_dir/tmux" "$stub_dir/tmuxinator"

  # `dotfiles` already has a config, so this exercises the start path without
  # writing a new YAML into the repo.
  run env -i HOME="$HOME" PATH="$stub_dir:/usr/bin:/bin" DOTFILES="$repo_root" \
    bash "$SCRIPT" dotfiles "$repo_root"
  rm -rf "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"TMUXINATOR_CONFIG=$repo_root/stow/tmuxinator/dot-config/tmuxinator"* ]] || {
    echo "output: $output"
    false
  }
}
