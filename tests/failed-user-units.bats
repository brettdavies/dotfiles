#!/usr/bin/env bats
# stow/claude/dot-claude/failed-user-units.sh: the SessionStart hook that names the failed systemd user units to the user
# (systemMessage, under the startup banner) and to Claude (additionalContext), so a scheduled job that fails
# (vault-agent-sync-check on a stalled NAS mirror) shows at the start of every Claude session. It runs at every session
# start on every host, so it must never fail or hold up a session: each failure path below exits 0 and prints nothing.
#
# systemctl is a stub. It logs its arguments and XDG_RUNTIME_DIR, then answers the list query from STUB_FAILED and
# `show` from STUB_STATUS, fails like a missing user bus when STUB_FAIL is set, or never answers when STUB_HANG is set.
#
# Run: bats tests/failed-user-units.bats

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
HOOK="$REPO_ROOT/stow/claude/dot-claude/failed-user-units.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s XDG_RUNTIME_DIR=%s\n' "$*" "${XDG_RUNTIME_DIR-}" >>"$SYSTEMCTL_LOG"
[ -z "${STUB_HANG-}" ] || exec sleep 30
[ -z "${STUB_FAIL-}" ] || { echo 'Failed to connect to bus: No medium found' >&2; exit 1; }
case "$*" in
  *" show "*) printf '%b' "${STUB_STATUS-}" ;;
  *) printf '%b' "${STUB_FAILED-}" ;;
esac
EOF
  chmod +x "$STUBS/systemctl"
}

@test "failed user units reach the user and Claude as one SessionStart JSON object" {
  STUB_FAILED='vault-agent-sync-check.service loaded failed failed Alert when the vault mirror has stalled\nbrew-upgrade.service loaded failed failed Update Homebrew\n' \
    PATH="$STUBS:$PATH" run --separate-stderr env -u XDG_RUNTIME_DIR "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 1 ]
  message=$(jaq -r '.systemMessage' <<<"$output")
  [ "$message" = 'WARNING: failed systemd user units: vault-agent-sync-check.service, brew-upgrade.service; inspect with: systemctl --user status <unit>' ]
  [ "$(jaq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = SessionStart ]
  [ "$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")" = "$message" ]
  [ "$(cat "$SYSTEMCTL_LOG")" = "--user list-units --state=failed --no-legend --plain XDG_RUNTIME_DIR=/run/user/$(id -u)
--user show -p Id -p StatusText vault-agent-sync-check.service brew-upgrade.service XDG_RUNTIME_DIR=/run/user/$(id -u)" ]
}

@test "a failed unit's own status text follows its name, so the notice says why it failed" {
  STUB_FAILED='agent-slot-warm.service loaded failed failed Trust slot paths\nbrew-upgrade.service loaded failed failed Update Homebrew\n' \
    STUB_STATUS='StatusText=prime untrusted in Claude for 2 repos: "a", b\\c; run claude once in each prime\nId=agent-slot-warm.service\n\nStatusText=\nId=brew-upgrade.service\n' \
    PATH="$STUBS:$PATH" run --separate-stderr "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(jaq -r '.systemMessage' <<<"$output")" = 'WARNING: failed systemd user units: agent-slot-warm.service (prime untrusted in Claude for 2 repos: "a", b\c; run claude once in each prime), brew-upgrade.service; inspect with: systemctl --user status <unit>' ]
}

@test "a unit name holding systemd's backslash escape stays valid JSON" {
  STUB_FAILED='mnt-nas\\x2dold.mount loaded failed failed NAS\n' PATH="$STUBS:$PATH" run --separate-stderr "$HOOK"
  [ "$status" -eq 0 ]
  [[ $(jaq -r '.systemMessage' <<<"$output") == *': mnt-nas\x2dold.mount;'* ]]
}

@test "no failed user unit prints nothing" {
  PATH="$STUBS:$PATH" run --separate-stderr "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a systemctl that fails prints nothing and exits 0" {
  STUB_FAIL=1 STUB_FAILED='brew-upgrade.service loaded failed failed Update Homebrew\n' \
    PATH="$STUBS:$PATH" run --separate-stderr "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a user manager that never answers holds the session start about 2 s, then prints nothing and exits 0" {
  local started=$SECONDS
  STUB_HANG=1 PATH="$STUBS:$PATH" run --separate-stderr "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  ((SECONDS - started < 5))
}

@test "a host without systemctl, macOS among them, prints nothing and exits 0" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/empty" "$BASH" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "settings.json runs the hook as a SessionStart entry of its own, and session-context.sh leaves the units to it" {
  run jaq -e '[.hooks.SessionStart[] | select(.hooks == [{type: "command", command: "~/.claude/failed-user-units.sh", timeout: 5}])] | length == 1' \
    "$REPO_ROOT/stow/claude/dot-claude/settings.json"
  [ "$status" -eq 0 ]
  run ! grep -F failed-user-units "$REPO_ROOT/stow/claude/dot-claude/session-context.sh"
}
