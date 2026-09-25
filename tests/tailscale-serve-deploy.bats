#!/usr/bin/env bats
# Tests for scripts/tailscale-serve-deploy.sh, which renders and installs the
# unit that re-runs scripts/tailscale-serve-setup.sh on every tailscaled start.
#
# Run: bats tests/tailscale-serve-deploy.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/tailscale-serve-deploy.sh"

setup() {
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "--render fills in the operator and runs that user's ~/dotfiles" {
  me="$(id -un)"
  home="$(getent passwd "$me" | cut -d: -f6)"
  run "$SCRIPT" --render "$me"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nUser='"$me"$'\n'* ]]
  [[ "$output" == *$'\nExecStart='"$home"$'/dotfiles/scripts/tailscale-serve-setup.sh\n'* ]]
  [[ "$output" != *"@OPERATOR@"* ]]
  [[ "$output" != *"@CHECKOUT@"* ]]
}

@test "--render for a user with no account fails" {
  run "$SCRIPT" --render no-such-user-tailscale-serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: no account for operator user no-such-user-tailscale-serve"* ]]
}

@test "the rendered unit re-runs with tailscaled and retries on failure" {
  run "$SCRIPT" --render "$(id -un)"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nPartOf=tailscaled.service\n'* ]]
  [[ "$output" == *$'\nWantedBy=tailscaled.service'* ]]
  [[ "$output" == *$'\nRestart=on-failure\n'* ]]
}

@test "the rendered unit passes systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  # ExecStart names the canonical checkout, absent on a CI runner; verify the rest.
  "$SCRIPT" --render "$(id -un)" | sed 's|^ExecStart=.*|ExecStart=/bin/true|' > "$WORK/tailscale-serve-setup.service"
  run systemd-analyze verify "$WORK/tailscale-serve-setup.service"
  [ "$status" -eq 0 ]
}

@test "the setup script the unit runs is executable" {
  [ -x "$REPO_ROOT/scripts/tailscale-serve-setup.sh" ]
}

@test "--render without an operator is a usage error" {
  run "$SCRIPT" --render
  [ "$status" -eq 2 ]
}

@test "an unknown argument is a usage error" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "installing without root is refused before touching systemd" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: This script must be run as root"* ]]
}
