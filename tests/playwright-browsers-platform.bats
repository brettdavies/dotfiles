#!/usr/bin/env bats
# Tests for scripts/playwright-browsers-deploy.sh on a Mac, on a platform with no build, and at the command line: the
# archives each platform fetches, the usage errors, the refusals that come before any work, and the one line a failure
# nothing anticipated prints.
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

@test "a Mac the pin hashes no WebKit for, newer than the ones it does, is told so rather than to upgrade" {
  bs_as_mac 25.1.0
  sed '/^sha256 webkit-mac-26-arm64.zip /d' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/no26.pin"
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/no26.pin"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"this pin hashes no WebKit build for macOS 26; reason: mac-release-unsupported; value: Darwin 25.1.0; nothing downloaded"* ]]
  [ ! -s "$BS_CURL_LOG" ]
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

@test "a next step that reruns the deploy keeps the pin it was given, as an absolute path" {
  cp "$BS_TEST_PIN" "$BATS_TEST_TMPDIR/my edited.pin"
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr "$BS_SCRIPT" --pin "my edited.pin" --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin $(printf %q "$BATS_TEST_TMPDIR/my edited.pin")"* ]]
}

@test "--pin=PATH names the pin too, and a flag is never taken for its path" {
  run --separate-stderr "$BS_SCRIPT" --pin="$BS_TEST_PIN" --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin $(printf %q "$BS_TEST_PIN")"* ]]
  run --separate-stderr "$BS_SCRIPT" --pin --help
  [ "$status" -eq 2 ]
  [[ "$stderr" == "ERROR: --pin needs a path; reason: usage;"* ]]
}

@test "an empty --pin is a usage error, and a path ending in a slash is reported as given" {
  run --separate-stderr "$BS_SCRIPT" --pin=
  [ "$status" -eq 2 ]
  [[ "$stderr" == "ERROR: --pin needs a path; reason: usage;"* ]]
  run --separate-stderr "$BS_SCRIPT" --pin ""
  [ "$status" -eq 2 ]
  run --separate-stderr "$BS_SCRIPT" --pin ./missing-dir/
  [ "$status" -eq 1 ]
  [[ "$stderr" == "ERROR: no readable pin at ./missing-dir/; reason: pin-not-found;"* ]]
  [[ "$stderr" == *"next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin ./missing-dir/ --help" ]]
}

@test "a run from a checkout other than ~/dotfiles names its own pin in every next step" {
  run --separate-stderr "$BS_SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin $(printf %q "$BS_PIN")"* ]]
}

@test "a missing curl is named with the command that installs it, and nothing is changed" {
  # An exported `command` that does not find curl, in a subshell, rather than a PATH without it.
  status=0
  (
    # shellcheck disable=SC2329 # the child bash calls it, through the exported function
    command() { if [ "$1 $2" = "-v curl" ]; then return 1; fi; builtin command "$@"; }
    export -f command
    "$BASH" "$BS_SCRIPT" --pin "$BS_TEST_PIN" 2>"$BATS_TEST_TMPDIR/err"
  ) || status=$?
  stderr="$(cat "$BATS_TEST_TMPDIR/err")"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"curl is required to fetch and unpack the archives; reason: tool-missing; value: curl; nothing changed; next: ask the operator to run sudo apt-get install -y curl" ]]
  [ ! -e "$BP" ]
}

@test "a step the script did not anticipate ends with the tool's own message, then unexpected-failure and exit 1" {
  touch "$BP"
  deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"mkdir: "*"a step failed unexpectedly at playwright-browsers-deploy.sh:"[0-9]*"; the failing tool's own message is above; reason: unexpected-failure; value: mkdir; the set may be partly updated; rerun once the cause above is fixed; next: ~/dotfiles/"* ]]
}

@test "a library step that fails names its file, and a failure inside \$(...) prints one line" {
  mkdir -p "$BP/.dotfiles/clients"
  touch "$BP/.dotfiles/clients/chromium-8103038"
  deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"a step failed unexpectedly at clients.sh:"[0-9]*"; "*"reason: unexpected-failure; value: mkdir;"* ]]
  printf '#!/usr/bin/env bash\necho "sha256sum: I/O error" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/stubs/sha256sum"
  chmod +x "$BATS_TEST_TMPDIR/stubs/sha256sum"
  rm -rf "${BP:?}"
  deploy
  [ "$status" -eq 1 ]
  [ "$(grep -c 'reason: unexpected-failure' <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *"sha256sum: I/O error"* ]]
}
