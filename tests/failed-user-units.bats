#!/usr/bin/env bats
# stow/claude/dot-claude/failed-user-units.sh: the session-context section that lists failed systemd user units, so a
# scheduled job that fails (vault-agent-sync-check on a stalled NAS mirror) shows at the start of every Claude session.
# systemctl is a stub that answers the list query from STUB_FAILED.
#
# Run: bats tests/failed-user-units.bats

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SECTION="$REPO_ROOT/stow/claude/dot-claude/failed-user-units.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
printf '%b' "${STUB_FAILED-}"
EOF
  chmod +x "$STUBS/systemctl"
}

@test "failed user units print as one comma-separated section" {
  STUB_FAILED='vault-agent-sync-check.service loaded failed failed Alert when the vault mirror has stalled\nbrew-upgrade.service loaded failed failed Update Homebrew\n' \
    PATH="$STUBS:$PATH" run "$SECTION"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '\n%s\n%s' '--- Failed systemd user units (systemctl --user status <unit>) ---' \
    'vault-agent-sync-check.service, brew-upgrade.service')" ]
  [ "$(cat "$SYSTEMCTL_LOG")" = '--user list-units --state=failed --no-legend --plain' ]
}

@test "no failed user unit prints nothing" {
  PATH="$STUBS:$PATH" run "$SECTION"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-context.sh ends with the section, resolved beside its own target" {
  [ "$(tail -n 1 "$REPO_ROOT/stow/claude/dot-claude/session-context.sh")" = \
    '"$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/failed-user-units.sh"' ]
}
