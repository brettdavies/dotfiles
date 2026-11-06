#!/usr/bin/env bats
# Tests for `scripts/playwright-browsers-deploy.sh --check`: every difference
# between the cache and the pin is a finding with a stable reason, and the check
# changes nothing.
#
# Run: bats tests/playwright-browsers-check.bats
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

setup_file() { bs_build_archives; }

setup() {
  bs_sandbox
  deploy
  [ "$status" -eq 0 ]
}

# The tree and every symlink's target, so a check that touched anything shows.
state() {
  (cd "$BP" && find . | sort && find . -type l -exec readlink {} \;)
}

@test "a healthy set passes with nothing on stderr but retained builds" {
  deploy --check
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "a host with nothing deployed fails without creating a cache, and pages its findings" {
  local empty="$BATS_TEST_TMPDIR/empty"
  PLAYWRIGHT_BROWSERS_PATH="$empty" deploy --check
  [ "$status" -eq 1 ]
  [ ! -e "$empty" ]
  [ "$(grep -c 'reason: directory-incomplete' <<<"$stderr")" -eq 4 ]
  [ "$(grep -c 'reason: alias-missing' <<<"$stderr")" -eq 5 ]
  [[ "$stderr" == *"NOTE: 14 more findings with reason alias-missing"* ]]
  [[ "$stderr" == *"NOTE: 18 more findings with reason client-missing"* ]]
}

@test "a record that differs from the pin's archive or URL is a provenance finding" {
  sed -i.bak 's|/linux64/|/linux32/|' "$BP/chromium-8103038/.dotfiles-record"
  local before
  before="$(state)"
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chromium-8103038 was not provisioned from the archive and URL the pin names; reason: provenance-mismatch; changed nothing; a deploy fetches it again; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh"* ]]
  [ "$(state)" = "$before" ]
  rm "$BP/webkit-2311/.dotfiles-record"
  deploy --check
  [[ "$stderr" == *"webkit-2311 was not provisioned"* ]]
  sed -i.bak 's|^sha256 .*|sha256 0000000000000000000000000000000000000000000000000000000000000000|' "$BP/ffmpeg-1013/.dotfiles-record"
  deploy --check
  [[ "$stderr" == *"ffmpeg-1013 was not provisioned"* ]]
}

@test "a record naming another hash makes the deploy fetch that archive again and record the pin's" {
  local want
  want="$(sed -n 's/^sha256 ffmpeg-linux.zip //p' "$BS_TEST_PIN")"
  sed -i.bak 's|^sha256 .*|sha256 0000000000000000000000000000000000000000000000000000000000000000|' "$BP/ffmpeg-1013/.dotfiles-record"
  : >"$BS_CURL_LOG"
  deploy
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BS_CURL_LOG")" -eq 1 ]
  [ "$(sed -n 1p "$BP/ffmpeg-1013/.dotfiles-record")" = "sha256 $want" ]
}

@test "an alias that is missing or dangling is named with its target" {
  rm "$BP/ffmpeg-1011"
  rm -rf "${BP:?}/chromium_headless_shell-8103038"
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"alias ffmpeg-1011 to ffmpeg-1013 is missing; reason: alias-missing"* ]]
  [[ "$stderr" == *"alias chromium_headless_shell-1200 does not resolve to a finished install of chromium_headless_shell-8103038; reason: alias-wrong-target"* ]]
}

@test "an alias pointing at the wrong build is a finding even when it resolves" {
  ln -sfn webkit-2311 "$BP/ffmpeg-1011"
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"alias ffmpeg-1011 does not resolve to a finished install of ffmpeg-1013; reason: alias-wrong-target"* ]]
}

@test "a directory with no client is a finding with the deploy as its next step" {
  rm "$BP/.links/dotfiles-chromium-1228"
  rm "$BP/.links/dotfiles-webkit-2311"
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no client registers chromium-1228, so another Playwright's install deletes it; reason: client-missing; changed nothing; a deploy registers it; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh"* ]]
  [[ "$stderr" == *"no client registers webkit-2311"* ]]
}

@test "a build the pin no longer names is retained, not stray, and a bare directory beside it is stray" {
  sed 's/^cft-version .*/cft-version 158.0.8127.1/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/n.pin"
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/n.pin"
  [ "$status" -eq 0 ]
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/n.pin" --check
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"NOTE: retained build chromium-8103038"* ]]
  [[ "$stderr" == *"NOTE: retained build chromium_headless_shell-8103038"* ]]
  [[ "$stderr" != *"stray"* ]]
  bs_seed chromium-8103037 chrome-linux64/chrome
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/n.pin" --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stray-directory; value: chromium-8103037"* ]]
}

@test "the check never writes: a broken cache is the same before and after" {
  rm "$BP/.links/dotfiles-webkit-2311"
  rm -rf "${BP:?}/ffmpeg-1013"
  bs_seed chromium-1155
  local before
  before="$(state)"
  deploy --check
  [ "$status" -eq 1 ]
  [ "$(state)" = "$before" ]
}

@test "every finding names a reason and a next command that runs from a headless shell" {
  rm "$BP/.links/dotfiles-webkit-2311"
  bs_seed chromium-1155
  deploy --check
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^(ERROR|NOTE):\  ]]
    [[ "$line" != ERROR:* ]] || [[ "$line" =~ \;\ reason:\ [a-z-]+(\;\ value:\ [A-Za-z0-9._\ -]+)?\;\ changed\ nothing.*\;\ next:\ (~/dotfiles/scripts/|ls\ -ld\ ) ]]
  done <<<"$stderr"
}
