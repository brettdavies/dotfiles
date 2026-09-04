#!/usr/bin/env bats
# Tests for scripts/sshd-locale-deploy.sh, which strips LANG and LC_* from
# every AcceptEnv directive so sessions use the server's own locale.
#
# Run: bats tests/sshd-locale-deploy.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sshd-locale-deploy.sh"

setup() {
  WORK="$(mktemp -d)"
  CONFIG="$WORK/sshd_config"
}

teardown() {
  rm -rf "$WORK"
}

@test "stock Ubuntu line is commented out and nothing else changes" {
  printf 'Port 22\n# Allow client to pass locale environment variables\nAcceptEnv LANG LC_*\nSubsystem sftp /usr/lib/openssh/sftp-server\n' > "$CONFIG"
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed LANG and LC_* from AcceptEnv in $CONFIG"* ]]
  expected=$(printf 'Port 22\n# Allow client to pass locale environment variables\n#AcceptEnv LANG LC_*\nSubsystem sftp /usr/lib/openssh/sftp-server')
  [ "$(cat "$CONFIG")" = "$expected" ]
}

@test "non-locale variables on the same line survive" {
  printf 'AcceptEnv LANG GIT_AUTHOR_NAME LC_ALL LC_*\n' > "$CONFIG"
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONFIG")" = "AcceptEnv GIT_AUTHOR_NAME" ]
}

@test "indentation inside a Match block is preserved" {
  printf 'Match User deploy\n    AcceptEnv LANG LC_*\n    AcceptEnv LC_CTYPE TZ\n' > "$CONFIG"
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  expected=$(printf 'Match User deploy\n#    AcceptEnv LANG LC_*\n    AcceptEnv TZ')
  [ "$(cat "$CONFIG")" = "$expected" ]
}

@test "drop-ins beside the config are rewritten; non-.conf files are not" {
  mkdir -p "$WORK/sshd_config.d"
  printf 'Port 22\n' > "$CONFIG"
  printf 'AcceptEnv LANG LC_*\n' > "$WORK/sshd_config.d/50-locale.conf"
  printf 'AcceptEnv LANG\n' > "$WORK/sshd_config.d/README"
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/sshd_config.d/50-locale.conf")" = "#AcceptEnv LANG LC_*" ]
  [ "$(cat "$WORK/sshd_config.d/README")" = "AcceptEnv LANG" ]
  [ "$(cat "$CONFIG")" = "Port 22" ]
}

@test "second run reports nothing to change and leaves the file alone" {
  printf 'AcceptEnv LANG LC_*\n' > "$CONFIG"
  "$SCRIPT" --config "$CONFIG" >/dev/null
  before=$(cat "$CONFIG")
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to change"* ]]
  [ "$(cat "$CONFIG")" = "$before" ]
}

@test "already-commented and unrelated AcceptEnv lines are untouched" {
  printf '#AcceptEnv LANG LC_*\nAcceptEnv TZ COLORTERM\n' > "$CONFIG"
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to change"* ]]
  [ "$(cat "$CONFIG")" = "$(printf '#AcceptEnv LANG LC_*\nAcceptEnv TZ COLORTERM')" ]
}

@test "missing config fails the pre-flight (exit 1)" {
  run "$SCRIPT" --config "$WORK/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "unknown flag and a bare --config are usage errors (exit 2)" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --config
  [ "$status" -eq 2 ]
}
