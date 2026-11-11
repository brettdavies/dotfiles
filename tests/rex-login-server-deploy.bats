#!/usr/bin/env bats
# Tests for scripts/rex-login-server-deploy.sh, which renders the Rex accounts
# file from config/rex/, copies the tailnet listener drop-in, and enables
# rex-login-server.service. Every test writes under a sandbox --root.
#
# Run: bats tests/rex-login-server-deploy.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/rex-login-server-deploy.sh"
DROPIN_SRC="$REPO_ROOT/config/systemd/system/rex-login-server.service.d/tailnet-listen.conf"
PACKAGED_UNIT=/usr/lib/systemd/system/rex-login-server.service
LOGIN=someone@example.com

setup_file() {
  load lib/platform
  require_linux "the deploy enables a systemd unit and checks the account with getent"
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT"
  ACCOUNTS="$ROOT/etc/rex/accounts.jsonc"
  DROPIN="$ROOT/etc/systemd/system/rex-login-server.service.d/tailnet-listen.conf"
  ME="$(id -un)"
  unset SUDO_USER
}

@test "--root renders the accounts file for the login and the current user" {
  run "$SCRIPT" --login "$LOGIN" --root "$ROOT"
  [ "$status" -eq 0 ]
  run python3 -B -I -c '
import json, sys
f = json.load(open(sys.argv[1]))
assert f["accounts"] == {sys.argv[3]: {"principals": ["tailscale:" + sys.argv[2]]}}, f
assert f["defaults"] == {"tailscale:" + sys.argv[2]: sys.argv[3]}, f
' "$ACCOUNTS" "$LOGIN" "$ME"
  [ "$status" -eq 0 ]
  [ -n "$(find "$ACCOUNTS" -perm 0644)" ]
}

@test "the account defaults to SUDO_USER, and --account overrides it" {
  SUDO_USER=root run "$SCRIPT" --login "$LOGIN" --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qF '"root": { "principals": ["tailscale:someone@example.com"] }' "$ACCOUNTS"
  SUDO_USER=root run "$SCRIPT" --login "$LOGIN" --account "$ME" --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qF "\"$ME\": { \"principals\"" "$ACCOUNTS"
}

@test "--root copies the drop-in byte for byte, mode 0644" {
  run "$SCRIPT" --login "$LOGIN" --root "$ROOT"
  [ "$status" -eq 0 ]
  cmp "$DROPIN_SRC" "$DROPIN"
  [ -n "$(find "$DROPIN" -perm 0644)" ]
  [[ "$output" == *"NOTE: wrote $DROPIN"* ]]
}

@test "a second run reports nothing to copy" {
  "$SCRIPT" --login "$LOGIN" --root "$ROOT" >/dev/null
  run "$SCRIPT" --login "$LOGIN" --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to copy"* ]]
  [[ "$output" != *"NOTE: wrote"* ]]
}

@test "a new login rewrites only the accounts file" {
  "$SCRIPT" --login "$LOGIN" --root "$ROOT" >/dev/null
  run "$SCRIPT" --login other@example.com --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: wrote $ACCOUNTS"* ]]
  [[ "$output" != *"NOTE: wrote $DROPIN"* ]]
  grep -qF 'tailscale:other@example.com' "$ACCOUNTS"
}

@test "the drop-in clears ExecStart, adds the tailnet listener, and needs tailscaled" {
  run grep -Ev '^[[:space:]]*(#|$)' "$DROPIN_SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Requires=tailscaled.service\n'* ]]
  [[ "$output" == *$'After=tailscaled.service\n'* ]]
  [[ "$output" == *$'ExecStart=\nExecStart=/usr/bin/rex login-server '* ]]
  [[ "$output" == *" --extra-listen tailnet://:7297" ]]
}

@test "the drop-in repeats the packaged ExecStart before its listener" {
  [ -f "$PACKAGED_UNIT" ] || skip "the rex package is not installed"
  packaged=$(sed -n 's/^ExecStart=//p' "$PACKAGED_UNIT")
  ours=$(sed -n 's/^ExecStart=\(.\)/\1/p' "$DROPIN_SRC")
  [ "$ours" = "$packaged --extra-listen tailnet://:7297" ]
}

@test "logins and account names that could break the JSON are usage errors (exit 2)" {
  for bad in 'no-at-sign' 'a b@example.com' 'a"b@example.com' 'a|b@example.com' 'a\b@example.com'; do
    run "$SCRIPT" --login "$bad" --root "$ROOT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a Tailscale login"* ]]
  done
  run "$SCRIPT" --login "$LOGIN" --account 'Bad"Name' --root "$ROOT"
  [ "$status" -eq 2 ]
  [ ! -e "$ACCOUNTS" ]
}

@test "an account that does not exist fails the pre-flight (exit 1)" {
  run "$SCRIPT" --login "$LOGIN" --account no-such-user-rex --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: no account named no-such-user-rex"* ]]
  [ ! -e "$ACCOUNTS" ]
}

@test "an account with a nologin shell fails the pre-flight (exit 1)" {
  shell=$(getent passwd nobody | cut -d: -f7)
  [[ "$shell" == */nologin || "$shell" == */false ]] || skip "nobody has a login shell here"
  run "$SCRIPT" --login "$LOGIN" --account nobody --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the login server refuses it"* ]]
}

@test "--root into a missing directory fails the pre-flight (exit 1)" {
  run "$SCRIPT" --login "$LOGIN" --root "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"root directory not found"* ]]
}

@test "deploying without root fails the pre-flight and names sudo (exit 1)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run "$SCRIPT" --login "$LOGIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: This script must be run as root (use sudo)"* ]]
}

@test "a missing --login, a bare flag, and an unknown flag are usage errors (exit 2)" {
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login is required"* ]]
  run "$SCRIPT" --login
  [ "$status" -eq 2 ]
  run "$SCRIPT" --login "$LOGIN" --bogus
  [ "$status" -eq 2 ]
}
