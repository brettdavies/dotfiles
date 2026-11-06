#!/usr/bin/env bats
# Tests for scripts/playwright-browsers-deploy.sh: the set a deploy provisions from the pin and its aliases; what a failed
# fetch, a wrong hash, or a relabelled version leave in place; the cache it did not make, the .links clients it keeps,
# and what it will and will not delete; and the Mac, the command line, and the refusals that come before any work.
#
# Run: bats tests/playwright-browsers-deploy.bats
#
# curl and uname are stubs (tests/lib/browser-set.bash): the archives are tiny
# fixtures whose hashes the test pin carries, and the script never reaches the
# network. The cases that run Playwright's own cleanup are in
# playwright-browsers-cleanup.bats.
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

setup_file() { bs_build_archives; }
setup() { bs_sandbox; }

# The inode of a path: a file replaced by rename gets a new one, one written in place keeps it.
inode() {
  # shellcheck disable=SC2012 # stat's flag differs between GNU and BSD
  ls -i "$1" | cut -d' ' -f1
}

# alias name -> target, for every alias a Linux deploy of the pin makes.
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

@test "a real directory at an alias name, as a --force install leaves it, is replaced by the alias" {
  deploy
  [ "$status" -eq 0 ]
  rm "$BP/chromium-1228"
  bs_seed chromium-1228 chrome-linux64/chrome
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"chromium-1228 is a real directory where the pin puts an alias to chromium-8103038; reason: alias-real-directory"* ]]
  deploy
  [ "$status" -eq 0 ]
  [ "$(readlink "$BP/chromium-1228")" = chromium-8103038 ]
  deploy --check
  [ "$status" -eq 0 ]
}

@test "a browser directory outside the pin, as a tool below the floor leaves it, survives and --check names it" {
  deploy
  [ "$status" -eq 0 ]
  bs_seed chromium-1155 chrome-linux/chrome
  bs_seed firefox-1497 firefox/firefox
  deploy
  [ "$status" -eq 0 ]
  [ -f "$BP/chromium-1155/INSTALLATION_COMPLETE" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: stray-directory; value: chromium-1155"* ]]
  [[ "$stderr" == *"reason: stray-directory; value: firefox-1497"* ]]
  [[ "$stderr" == *"next: ls -ld "*"/browsers/firefox-1497"* ]]
}

@test "a cache holding per-version and chromium-alias clients beside Playwright's own installs becomes the set in one deploy" {
  local d
  for d in chromium-1234 chromium-1248 chromium_headless_shell-1234 chromium_headless_shell-1248 webkit-2311 webkit-2336 ffmpeg-1011 ffmpeg-1013; do
    bs_seed "$d"
  done
  ln -s chromium-1234 "$BP/chromium-1228"
  ln -s chromium_headless_shell-1234 "$BP/chromium_headless_shell-1228"
  mkdir -p "$BP/.links" "$BP/.dotfiles/playwright-1.62.1" "$BP/.dotfiles/chromium-alias-1228" "$BP/other-package"
  echo '{"browsers": [{"name": "chromium", "revision": "1234"}]}' >"$BP/.dotfiles/playwright-1.62.1/browsers.json"
  echo '{"browsers": [{"name": "chromium", "revision": "1228"}]}' >"$BP/.dotfiles/chromium-alias-1228/browsers.json"
  printf '%s' "$BP/.dotfiles/playwright-1.62.1" >"$BP/.links/dotfiles-playwright-1.62.1"
  printf '%s' "$BP/.dotfiles/chromium-alias-1228" >"$BP/.links/dotfiles-chromium-alias-1228"
  echo '{"browsers": []}' >"$BP/other-package/browsers.json"
  printf '%s' "$BP/other-package" >"$BP/.links/0123456789abcdef"
  touch "$BP/.DS_Store"
  ln -s chromium-1234 "$BP/chromium-1179"
  mkdir -p "$BP/.dotfiles/clients/chromium-1179"
  echo '{"browsers": [{"name": "chromium", "revision": "1179"}]}' >"$BP/.dotfiles/clients/chromium-1179/browsers.json"
  printf '%s' "$BP/.dotfiles/clients/chromium-1179" >"$BP/.links/dotfiles-chromium-1179"
  deploy --check
  [ "$status" -eq 1 ]
  deploy
  [ "$status" -eq 0 ]
  [ ! -L "$BP/chromium-1179" ]
  [ ! -e "$BP/.links/dotfiles-chromium-1179" ]
  [ ! -e "$BP/.dotfiles/clients/chromium-1179" ]
  [[ "$stderr" == *"NOTE: replacing the real directory chromium-1234 with an alias to chromium-8103038"* ]]
  deploy --check
  [ "$status" -eq 0 ]
  [ "$(readlink "$BP/chromium-1234")" = chromium-8103038 ]
  [ "$(readlink "$BP/webkit-2336")" = webkit-2388 ]
  [ ! -e "$BP/.links/dotfiles-playwright-1.62.1" ]
  [ ! -e "$BP/.dotfiles/playwright-1.62.1" ]
  [ ! -e "$BP/.links/dotfiles-chromium-alias-1228" ]
  [ ! -e "$BP/.dotfiles/chromium-alias-1228" ]
  [ -f "$BP/.links/0123456789abcdef" ]
  [ -f "$BP/other-package/browsers.json" ]
}

@test "a symlink to a directory outside the set survives a deploy, and --check names it" {
  deploy
  [ "$status" -eq 0 ]
  bs_seed chromium-1179 chrome-linux/chrome
  ln -s chromium-1179 "$BP/chromium-1187"
  deploy
  [ "$status" -eq 0 ]
  [ -L "$BP/chromium-1187" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: stray-symlink; value: chromium-1187"* ]]
}

@test "a .links entry that is not a readable file is left alone and named, and does not stop the deploy" {
  deploy
  [ "$status" -eq 0 ]
  mkdir "$BP/.links/dotfiles-chromium-7777"
  deploy
  [ "$status" -eq 0 ]
  [ -d "$BP/.links/dotfiles-chromium-7777" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: client-unrecognised; value: dotfiles-chromium-7777"* ]]
}

@test "a client link naming a path with .. or a record file, and a symlink out of the cache, survive a deploy" {
  deploy
  [ "$status" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  echo keep >"$BATS_TEST_TMPDIR/outside/file"
  printf '%s' "$BP/.dotfiles/clients/../../../outside" >"$BP/.links/dotfiles-chromium-9998"
  printf '%s' "$BP/chromium-8103038/.dotfiles-record" >"$BP/.links/dotfiles-chromium-9999"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BP/chromium-1100"
  deploy
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/outside/file" ]
  [ -f "$BP/chromium-8103038/.dotfiles-record" ]
  [ -e "$BP/.links/dotfiles-chromium-9998" ]
  [ -e "$BP/.links/dotfiles-chromium-9999" ]
  [ -L "$BP/chromium-1100" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: stray-symlink; value: chromium-1100"* ]]
  [[ "$stderr" == *"reason: client-unrecognised; value: dotfiles-chromium-9998"* ]]
}

@test "a client directory that is a symlink is neither written through nor deleted through" {
  deploy
  [ "$status" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  echo keep-stale >"$BATS_TEST_TMPDIR/outside/browsers.json"
  echo keep-wanted >"$BATS_TEST_TMPDIR/outside/other.json"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BP/.dotfiles/clients/chromium-9997"
  printf '%s' "$BP/.dotfiles/clients/chromium-9997" >"$BP/.links/dotfiles-chromium-9997"
  rm -rf "${BP:?}/.dotfiles/clients/webkit-2388"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BP/.dotfiles/clients/webkit-2388"
  deploy
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/outside/browsers.json")" = keep-stale ]
  [ -f "$BATS_TEST_TMPDIR/outside/other.json" ]
  [ -e "$BP/.links/dotfiles-chromium-9997" ]
  [ ! -L "$BP/.dotfiles/clients/webkit-2388" ]
  [ -f "$BP/.dotfiles/clients/webkit-2388/browsers.json" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: client-unrecognised; value: dotfiles-chromium-9997"* ]]
}

@test "a .links emptied by another tool is whole again after a deploy, a retained build included" {
  sed 's/^cft-version .*/cft-version 156.0.8078.4/' "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/old.pin"
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/old.pin"
  [ "$status" -eq 0 ]
  deploy
  [ "$status" -eq 0 ]
  [ -f "$BP/.links/dotfiles-chromium-8078004" ]
  deploy --check
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"retained build chromium-8078004"* ]]
  find "$BP/.links" -type f -delete
  deploy --check
  [ "$status" -eq 1 ]
  deploy
  [ "$status" -eq 0 ]
  deploy --check
  [ "$status" -eq 0 ]
  [ -f "$BP/.links/dotfiles-chromium-8078004" ]
  [ -f "$BP/.links/dotfiles-webkit-2388" ]
}

@test "a damaged client is replaced by rename, never rewritten in place" {
  deploy
  [ "$status" -eq 0 ]
  local link="$BP/.links/dotfiles-webkit-2388" json="$BP/.dotfiles/clients/webkit-2388/browsers.json" i j
  i="$(inode "$json")"
  echo '{' >"$json"
  printf '%s\n' "$BP/.dotfiles/clients/webkit-2388" >"$link"
  j="$(inode "$link")"
  deploy
  [ "$status" -eq 0 ]
  [ "$(cat "$json")" = '{"browsers": [{"name": "webkit", "revision": "2388"}]}' ]
  [ "$(cat "$link"; printf x)" = "$BP/.dotfiles/clients/webkit-2388x" ]
  [ "$(inode "$json")" != "$i" ]
  [ "$(inode "$link")" != "$j" ]
}

@test "a new set directory has its client before it is renamed into the cache" {
  local real
  real="$(command -v mv)"
  cat >"$BATS_TEST_TMPDIR/stubs/mv" <<EOF
#!/usr/bin/env bash
case "\$2" in "$BP"/chromium-8103038)
  if [ -f "$BP/.links/dotfiles-chromium-8103038" ]; then echo registered; else echo unregistered; fi >>"$BATS_TEST_TMPDIR/mv.log" ;;
esac
exec "$real" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/mv"
  deploy
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/mv.log")" = registered ]
}

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
