#!/usr/bin/env bats
# Tests for scripts/sync/sync_dev_to_icloud.sh and the com.user.devtosync LaunchAgent that runs it. The script runs
# against a scratch tree through DEVTOSYNC_SOURCE and DEVTOSYNC_DEST, never ~/dev or iCloud Drive.
#
# Run: bats tests/sync-dev-to-icloud.bats

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync/sync_dev_to_icloud.sh"
PLIST="$BATS_TEST_DIRNAME/../stow/launchagent/Library/LaunchAgents/com.user.devtosync.plist"

_scratch_dev() {
  command -v rsync >/dev/null 2>&1 || skip "rsync not installed"
  export DEVTOSYNC_SOURCE="$BATS_TEST_TMPDIR/dev" DEVTOSYNC_DEST="$BATS_TEST_TMPDIR/icloud/dev"
  src=$DEVTOSYNC_SOURCE dest=$DEVTOSYNC_DEST
  mkdir -p "$src/app/src" "$src/app/node_modules/pkg" "$src/app/.build/debug" "$src/app/target/release"
  echo code >"$src/app/src/main.rs"
  echo note >"$src/app/src/target"
  echo dep >"$src/app/node_modules/pkg/index.js"
  echo obj >"$src/app/.build/debug/app.o"
  echo bin >"$src/app/target/release/app"
}

# Every path under a tree, and every file's checksum.
_snapshot() {
  (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort)
}

@test "the mirror copies source files and leaves out node_modules, .build and target directories" {
  _scratch_dev
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$dest/app/src/main.rs")" = code ]
  [ "$(cat "$dest/app/src/target")" = note ]
  [ ! -e "$dest/app/node_modules" ]
  [ ! -e "$dest/app/.build" ]
  [ ! -e "$dest/app/target" ]
}

@test "copies of excluded directories already in the mirror are removed, and the source is left as it was" {
  _scratch_dev
  mkdir -p "$dest/app/node_modules/old" "$dest/app/target/old"
  echo stale >"$dest/app/node_modules/old/index.js"
  echo stale >"$dest/app/target/old/app"
  before=$(_snapshot "$src")
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$dest/app/node_modules" ]
  [ ! -e "$dest/app/target" ]
  [ "$(_snapshot "$src")" = "$before" ]
}

@test "a run logs one summary line, not the files it copied" {
  _scratch_dev
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *": Synced $src to $dest" ]]
}

@test "the LaunchAgent runs the sync hourly through the launchd wrapper" {
  grep -qF 'exec "$HOME/dotfiles/scripts/launchd-run.sh" devtosync.log "$HOME/dotfiles/scripts/sync/sync_dev_to_icloud.sh"</string>' "$PLIST"
  grep -A1 '<key>StartInterval</key>' "$PLIST" | grep -qF '<integer>3600</integer>'
}
