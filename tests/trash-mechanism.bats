#!/usr/bin/env bats
# The `trash` command the repo requires in place of `rm` must be a real binary.
#
# An alias reaches interactive shells only. The callers that most need it are the
# ones that read no startup files at all: scripts with their own shebang, systemd
# units, cron, git hooks, and the agent Bash tool. On a host where `trash`
# resolves to nothing, those either fail or fall back to `rm`, which is the exact
# outcome the rule exists to prevent.
#
# macOS ships /usr/bin/trash. Linux gets trash-cli from the Brewfile.
#
# Run: bats tests/trash-mechanism.bats

bats_require_minimum_version 1.5.0

CONFIG_DIR="$BATS_TEST_DIRNAME/../config/shell"
BREWFILE="$BATS_TEST_DIRNAME/../stow/brew/Brewfile"

@test "platform-linux.sh does not alias trash" {
  run ! grep -qE "^[[:space:]]*alias[[:space:]]+trash=" "$CONFIG_DIR/platform-linux.sh"
}

@test "no config/shell file aliases trash" {
  # Moving the alias to another fragment would reintroduce the same gap.
  run ! grep -rqE "^[[:space:]]*alias[[:space:]]+trash=" "$CONFIG_DIR"
}

@test "the Brewfile installs trash-cli on Linux" {
  grep -qE '^brew "trash-cli" if OS\.linux\?$' "$BREWFILE"
}

@test "trash resolves as a binary in a shell that reads no startup files" {
  command -v trash >/dev/null 2>&1 || skip "trash not installed on this host"
  # env -i plus a bare `bash -c` is the launcher shape that gets no rc files, so
  # anything resolving here is on PATH as a real executable.
  run env -i PATH="$PATH" bash -c 'command -v trash'
  [ "$status" -eq 0 ]
  [ -x "$output" ] || {
    echo "trash resolved to '$output', which is not an executable file"
    false
  }
}
