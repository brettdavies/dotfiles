#!/usr/bin/env bats
# Tests for the macOS LaunchAgents in stow/launchagent/.
#
# Run: bats tests/launchagents.bats
#
# launchd starts an agent with its own user PATH, never the shell config chain,
# so each agent sets the PATH its command needs before it execs. Agent-specific
# PATH rules (the qmd dispatcher ordering) live in tests/qmd-serve.bats.

bats_require_minimum_version 1.5.0

AGENT_DIR="$BATS_TEST_DIRNAME/../stow/launchagent/Library/LaunchAgents"
AGENT_PATH='PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"; exec '

@test "every LaunchAgent runs through /bin/sh and sets the shared PATH before it execs" {
  missing=""
  for plist in "$AGENT_DIR"/*.plist; do
    grep -q '<string>/bin/sh</string>' "$plist" \
      && grep -qF "<string>$AGENT_PATH" "$plist" \
      || missing="$missing $(basename "$plist")"
  done
  [ -z "$missing" ] || {
    echo "LaunchAgents without /bin/sh -c '$AGENT_PATH...':$missing" >&2
    return 1
  }
}

@test "the dev-port tunnel keeps ssh -N to its host entry running, throttled, with standard error logged" {
  plist="$AGENT_DIR/com.user.bd-tunnel.plist"
  grep -A1 '<key>Label</key>' "$plist" | grep -qF '<string>com.user.bd-tunnel</string>'
  grep -qF "<string>$AGENT_PATH\"\$HOME/dotfiles/scripts/launchd-run.sh\" bd-tunnel.log ssh -N bd-tunnel</string>" "$plist"
  grep -A1 '<key>RunAtLoad</key>' "$plist" | grep -qF '<true/>'
  grep -A1 '<key>KeepAlive</key>' "$plist" | grep -qF '<true/>'
  grep -A1 '<key>ThrottleInterval</key>' "$plist" | grep -qE '<integer>[1-9][0-9]*</integer>'
}

@test "every LaunchAgent plist parses" {
  command -v plutil >/dev/null 2>&1 || skip "plutil is macOS-only"
  for plist in "$AGENT_DIR"/*.plist; do
    plutil -lint "$plist"
  done
}
