#!/usr/bin/env bats
# Tests for scripts/playwright-deps-deploy.sh: it deploys the browser set on
# every host and runs the Linux-only steps only on Linux.
#
# Run: bats tests/playwright-deps-deploy.bats
#
# The script runs from a copy of the scripts beside the test pin, so the deploy
# it calls reads fixture hashes. sudo is a stub that logs its arguments.
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

setup_file() { bs_build_archives; }

setup() {
  bs_sandbox
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/scripts" "$repo/config/playwright"
  cp "$BS_ROOT/scripts/playwright-deps-deploy.sh" "$BS_ROOT/scripts/playwright-browsers-deploy.sh" "$repo/scripts/"
  cp -R "$BS_ROOT/scripts/playwright-browsers" "$repo/scripts/"
  cp "$BS_TEST_PIN" "$repo/config/playwright/browsers.pin"
  DEPS="$repo/scripts/playwright-deps-deploy.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$BATS_TEST_TMPDIR/sudo.log" >"$BATS_TEST_TMPDIR/stubs/sudo"
  chmod +x "$BATS_TEST_TMPDIR/stubs/sudo"
}

@test "with no flag on Linux it deploys the set, then the AppArmor profile through sudo" {
  run --separate-stderr "$DEPS"
  [ "$status" -eq 0 ]
  [ -f "$BP/chromium-8103038/INSTALLATION_COMPLETE" ]
  [ -L "$BP/chromium-1228" ]
  [ "$(cat "$BATS_TEST_TMPDIR/sudo.log")" = "$BATS_TEST_TMPDIR/repo/scripts/apparmor-deploy.sh" ]
  [[ "$output" == *"binaries=yes apparmor=yes"* ]]
}

@test "on a Mac it deploys the set and skips the Linux-only steps without calling sudo" {
  bs_as_mac 27.0.0
  run --separate-stderr "$DEPS"
  [ "$status" -eq 0 ]
  [ -x "$BP/chromium-8103038/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.log" ]
  [[ "$output" == *"not Linux"* ]]
}

@test "on a Mac the system-library flags are accepted and do nothing" {
  bs_as_mac 27.0.0
  run --separate-stderr "$DEPS" --all
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.log" ]
}

@test "root is refused on every platform" {
  printf '#!/usr/bin/env bash\necho 0\n' >"$BATS_TEST_TMPDIR/stubs/id"
  chmod +x "$BATS_TEST_TMPDIR/stubs/id"
  bs_as_mac 27.0.0
  run --separate-stderr "$DEPS"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not root"* ]]
  [ ! -e "$BP" ]
}
