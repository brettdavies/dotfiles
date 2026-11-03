#!/usr/bin/env bats
# scripts/vault-agent-sync-check.sh: the hourly check that the vault's agent-workspace mirror to the NAS still succeeds.
# Each test writes a sync log in the shape the vault's sync-to-pool.sh leaves, with timestamps relative to now.
#
# Run: bats tests/vault-agent-sync-check.bats

bats_require_minimum_version 1.5.0

CHECK="$BATS_TEST_DIRNAME/../scripts/vault-agent-sync-check.sh"

setup_file() {
  load lib/platform
  require_linux "the check reads its timestamps with GNU date -d, and the job runs only on the Linux server"
}

setup() {
  export VAULT_SYNC_LOG="$BATS_TEST_TMPDIR/sync-pool.log"
}

# Usage: logged <hours ago> <line>; one sync log line stamped that many hours ago.
logged() {
  printf '[%s] %s\n' "$(date -d "-$1 hours" '+%Y-%m-%d %H:%M:%S')" "$2" >>"$VAULT_SYNC_LOG"
}

@test "a success within three hours passes with one OK line and nothing on stderr" {
  logged 9 "✅ Sync completed successfully"
  logged 2 "✅ Sync completed successfully"
  logged 1 "rsync error: unexplained error (code 255)"
  run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ $output =~ ^\[[0-9-]{10}\ [0-9:]{8}\]\ OK:\ Last\ sync\ [0-9-]{10}\ [0-9:]{8}\ \(2h\ ago\)$ ]]
}

@test "a last success more than three hours old fails and puts the alert on stderr" {
  logged 5 "✅ Sync completed successfully"
  logged 1 "rsync error: unexplained error (code 255)"
  run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [[ $output == *"ALERT: last successful sync was 5h ago ("*")" ]]
  [[ $stderr == "vault-agent-sync-check: ALERT: last successful sync was 5h ago ("*"); see $VAULT_SYNC_LOG" ]]
}

@test "a log with no success, or no log at all, fails" {
  logged 1 "rsync error: unexplained error (code 255)"
  run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [[ $output == *"ERROR: no successful sync found in the sync log" ]]
  [ "$stderr" = "vault-agent-sync-check: ERROR: no successful sync found in the sync log; see $VAULT_SYNC_LOG" ]

  export VAULT_SYNC_LOG="$BATS_TEST_TMPDIR/missing.log"
  run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [ "$stderr" = "vault-agent-sync-check: ERROR: no successful sync found in the sync log; see $VAULT_SYNC_LOG" ]
}
