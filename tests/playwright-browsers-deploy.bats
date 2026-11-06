#!/usr/bin/env bats
# Tests for scripts/playwright-browsers-deploy.sh: the set a deploy provisions from the pin, its aliases, and what
# a failed fetch, a wrong hash, or a relabelled version leave in place.
#
# Run: bats tests/playwright-browsers-deploy.bats
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

links() {
  local l
  for l in "$BP"/*; do [ -L "$l" ] && echo "${l##*/} -> $(readlink "$l")"; done
  return 0
}


@test "a first deploy fetches four archives from the two fixed hosts, over https, following no redirect" {
  deploy
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BS_CURL_LOG")" -eq 4 ]
  [ "$(grep -c -- "--proto =https" "$BS_CURL_LOG")" -eq 4 ]
  [ "$(grep -cE ' https://(storage.googleapis.com/chrome-for-testing-public/157.0.8103.38/linux64|cdn.playwright.dev/builds/(webkit/2388|ffmpeg/1013))/[^/]+$' "$BS_CURL_LOG")" -eq 4 ]
  [[ "$output" == *"OK: browser set deployed"* ]]
  run ! grep -qE '(^| )(-L|--location)( |$)' "$BS_CURL_LOG"
}

@test "real directories are numbered from the CfT build and patch, with markers and a record of archive and URL" {
  deploy
  [ "$status" -eq 0 ]
  for d in chromium-8103038 chromium_headless_shell-8103038 webkit-2388 ffmpeg-1013; do
    [ -d "$BP/$d" ]
    [ ! -L "$BP/$d" ]
    [ -f "$BP/$d/INSTALLATION_COMPLETE" ]
    [ -f "$BP/$d/DEPENDENCIES_VALIDATED" ]
  done
  [ "$(cat "$BP/chromium-8103038/.dotfiles-record")" = "sha256 $(bs_sha256 "$BS_ARCHIVES/chrome-linux64.zip")
url https://storage.googleapis.com/chrome-for-testing-public/157.0.8103.38/linux64/chrome-linux64.zip" ]
}

@test "every released revision is an alias to the real directory, and no WebKit alias reaches above the set's" {
  deploy
  [ "$status" -eq 0 ]
  run links
  [[ "$output" == *"chromium-1228 -> chromium-8103038"* ]]
  [[ "$output" == *"chromium_headless_shell-1254 -> chromium_headless_shell-8103038"* ]]
  [[ "$output" == *"webkit-2311 -> webkit-2388"* ]]
  [[ "$output" == *"ffmpeg-1011 -> ffmpeg-1013"* ]]
  [ "$(links | wc -l)" -eq 27 ]
  # A Playwright newer than the set's WebKit finds no directory, so it fails with
  # "Executable doesn't exist" and not with a protocol error midway through a run.
  [ ! -e "$BP/webkit-2400" ]
  [ ! -e "$BP/webkit-2389" ]
  for d in "$BP"/webkit-*; do [ "${d##*-}" -le 2388 ]; done
}

@test "a second deploy fetches nothing and writes no client" {
  deploy
  [ "$status" -eq 0 ]
  : >"$BS_CURL_LOG"
  touch -t 200001020000 "$BATS_TEST_TMPDIR/ref"
  find "$BP/.links" "$BP/.dotfiles/clients" -type f -exec touch -t 200001010000 {} +
  local before
  before="$(links)"
  deploy
  [ "$status" -eq 0 ]
  [ ! -s "$BS_CURL_LOG" ]
  [ -z "$(find "$BP/.links" "$BP/.dotfiles/clients" -type f -newer "$BATS_TEST_TMPDIR/ref")" ]
  [ "$(links)" = "$before" ]
}

@test "--check passes on a deployed set, naming the versions on stdout" {
  deploy
  [ "$status" -eq 0 ]
  deploy --check
  [ "$status" -eq 0 ]
  [[ "$output" == "OK: browser set "*"CfT 157.0.8103.38, WebKit 2388, ffmpeg 1013: 27 aliases, 31 clients" ]]
}

@test "a hash that differs from the pin stops the deploy, names both hashes, and leaves the set in place" {
  deploy
  [ "$status" -eq 0 ]
  local before
  before="$(links)"
  sed 's/^cft-version .*/cft-version 157.0.8103.99/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/next.pin"
  BS_CURL_SERVE="$BS_ARCHIVES/ffmpeg-linux.zip" run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/next.pin"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chrome-linux64.zip hashes to $(bs_sha256 "$BS_ARCHIVES/ffmpeg-linux.zip") and the pin names $(bs_sha256 "$BS_ARCHIVES/chrome-linux64.zip")"* ]]
  [[ "$stderr" == *"reason: archive-hash-mismatch; nothing moved; the existing set stays in place; next: curl -fsS https://storage.googleapis.com/chrome-for-testing-public/157.0.8103.99/linux64/chrome-linux64.zip | sha256sum" ]]
  [ ! -e "$BP/chromium-8103099" ]
  [ "$(links)" = "$before" ]
  deploy --check
  [ "$status" -eq 0 ]
}

@test "a failed fetch reports curl's own message above the reason and moves nothing" {
  BS_CURL_404=ffmpeg-linux deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"curl: (22) The requested URL returned error: 404"*"ffmpeg-linux.zip could not be fetched from https://cdn.playwright.dev/builds/ffmpeg/1013/ffmpeg-linux.zip; reason: archive-fetch-failed; "* ]]
  [ -z "$(links)" ]
}

@test "a failure after some directories arrived names them and says no alias moved" {
  BS_CURL_404=webkit deploy
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: archive-fetch-failed; no alias moved; chromium-8103038 chromium_headless_shell-8103038 arrived and a rerun fetches the rest; next: ~/dotfiles/"* ]]
  [ -f "$BP/chromium-8103038/INSTALLATION_COMPLETE" ]
  [ ! -e "$BP/webkit-2388" ]
  [ -z "$(links)" ]
  deploy
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BS_CURL_LOG")" -eq 5 ]
}

@test "a version relabelled onto an older build's number fetches from its own URL and moves nothing" {
  sed 's/^cft-version .*/cft-version 156.0.8078.4/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/a.pin"
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/a.pin"
  [ "$status" -eq 0 ]
  deploy
  [ "$status" -eq 0 ]
  local before
  before="$(links)"
  sed 's/^cft-version .*/cft-version 158.0.8078.4/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/c.pin"
  : >"$BS_CURL_LOG"
  BS_CURL_404=/158.0.8078.4/ run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/c.pin"
  [ "$status" -eq 1 ]
  grep -q '/158.0.8078.4/linux64/chrome-linux64.zip$' "$BS_CURL_LOG"
  [[ "$stderr" == *"archive-fetch-failed"* ]]
  [ "$(links)" = "$before" ]
  grep -q '/156.0.8078.4/' "$BP/chromium-8078004/.dotfiles-record"
}

@test "a directory whose executable is gone is fetched again, and --check names it first" {
  deploy
  [ "$status" -eq 0 ]
  rm "$BP/chromium-8103038/chrome-linux64/chrome"
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chromium-8103038 is missing or incomplete; reason: directory-incomplete"* ]]
  : >"$BS_CURL_LOG"
  deploy
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"NOTE: replacing chromium-8103038, whose executable or install marker is gone"* ]]
  [ "$(wc -l <"$BS_CURL_LOG")" -eq 1 ]
  deploy --check
  [ "$status" -eq 0 ]
}

@test "an unrecorded directory at a set name is announced before the deploy replaces it" {
  bs_seed webkit-2388
  deploy
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"NOTE: replacing webkit-2388, which is not from this pin"* ]]
}

@test "the deploy's own scratch directory never survives it" {
  deploy
  [ "$status" -eq 0 ]
  [ -z "$(find "$BP/.dotfiles" -maxdepth 1 -name 'stage.*')" ]
  sed 's/^cft-version .*/cft-version 157.0.8103.99/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/n.pin"
  BS_CURL_404=chrome-linux64 run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/n.pin"
  [ "$status" -eq 1 ]
  [ -z "$(find "$BP/.dotfiles" -maxdepth 1 -name 'stage.*')" ]
}
