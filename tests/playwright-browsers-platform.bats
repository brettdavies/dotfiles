#!/usr/bin/env bats
# Tests for scripts/playwright-browsers-deploy.sh on a Mac, on a platform with no build, and at the command line: the
# archives each platform fetches, the usage errors, and the refusals that come before any work.
#
# Run: bats tests/playwright-browsers-platform.bats
#
# curl and uname are stubs (tests/lib/browser-set.bash): the archives are tiny
# fixtures whose hashes the test pin carries, and the script never reaches the
# network.
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

setup_file() { bs_build_archives; }
setup() { bs_sandbox; }


@test "on a Mac the archives are the macOS ones, and WebKit is the build for that release" {
  bs_as_mac 27.0.0
  deploy
  [ "$status" -eq 0 ]
  grep -q 'chrome-for-testing-public/157.0.8103.38/mac-arm64/chrome-mac-arm64.zip$' "$BS_CURL_LOG"
  grep -q 'builds/webkit/2388/webkit-mac-26-arm64.zip$' "$BS_CURL_LOG"
  grep -q 'builds/ffmpeg/1013/ffmpeg-mac-arm64.zip$' "$BS_CURL_LOG"
  [ -x "$BP/chromium-8103038/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ]
  deploy --check
  [ "$status" -eq 0 ]
}

@test "a Mac picks WebKit the way Playwright's registry does: Darwin 24 is macOS 15, 25 and later 26" {
  bs_as_mac 24.6.0
  deploy
  [ "$status" -eq 0 ]
  grep -q 'webkit-mac-15-arm64.zip$' "$BS_CURL_LOG"
}

@test "a Mac the pin's WebKit does not support is refused naming the release, before anything downloads" {
  bs_as_mac 23.6.0
  deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"this pin's WebKit needs macOS 15 or later; reason: mac-release-unsupported; value: Darwin 23.6.0; nothing downloaded"* ]]
  [ ! -s "$BS_CURL_LOG" ]
  [ ! -e "$BP" ]
}

@test "a platform with no build is refused before anything downloads" {
  BS_ARCH=aarch64 deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: unsupported-platform; value: Linux aarch64"* ]]
  [ ! -s "$BS_CURL_LOG" ]
}

@test "the Playwright version argument is gone: exit 2 naming the pin, before any work" {
  run --separate-stderr "$BS_SCRIPT" 1.62.1
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"the set comes from the pin at $BS_PIN; reason: version-argument-removed; value: 1.62.1; nothing changed; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --help"* ]]
  [ ! -e "$BP" ]
}

@test "a usage error exits 2, --pin without a path included, and --help prints the header's usage" {
  run --separate-stderr "$BS_SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == "ERROR: unknown option; reason: usage; value: --frobnicate; nothing changed; next: "* ]]
  run --separate-stderr "$BS_SCRIPT" --pin
  [ "$status" -eq 2 ]
  run --separate-stderr "$BS_SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage:"*"--pin PATH"*"first deploy on a host"* ]]
}

@test "a pin that is missing is named by its path, and the next step does not discard it" {
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/my edited.pin"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no readable pin at "*"my\\ edited.pin; reason: pin-not-found"* ]]
  [[ "$stderr" != *"git checkout"* ]]
}

@test "root is refused" {
  printf '#!/usr/bin/env bash\necho 0\n' >"$BATS_TEST_TMPDIR/stubs/id"
  chmod +x "$BATS_TEST_TMPDIR/stubs/id"
  deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: running-as-root"* ]]
}
