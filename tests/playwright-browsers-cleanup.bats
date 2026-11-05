#!/usr/bin/env bats
# Playwright's own install-time cleanup against a deployed set: a real
# playwright-core at the library version the pin names, fetched by the hash the
# pin records, runs `install` and `uninstall` against a sandbox cache. Nothing
# here re-implements the cleanup.
#
# Run: bats tests/playwright-browsers-cleanup.bats
#
# These cases fetch the pinned library on first use (BS_CORE_CACHE keeps it).
# They fail on an HTTP error or a hash that differs from the pin, and skip only
# when node is missing or the npm registry cannot be reached at all.
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

setup_file() { bs_build_archives; }
setup() { bs_sandbox; }

fake_fetch() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$BATS_TEST_TMPDIR/fetch-curl"
  chmod +x "$BATS_TEST_TMPDIR/fetch-curl"
  export BS_FETCH_CURL="$BATS_TEST_TMPDIR/fetch-curl" BS_CORE_CACHE="$BATS_TEST_TMPDIR/core"
}

@test "an HTTP error on the pinned library fails, no route to the registry skips, and wrong bytes fail" {
  fake_fetch 'exit 22'
  run --separate-stderr bs_core_fetch
  [ "$status" -eq 1 ]
  fake_fetch 'exit 7'
  run --separate-stderr bs_core_fetch
  [ "$status" -eq 77 ]
  [[ "$stderr" == *"no route to the npm registry"* ]]
  fake_fetch 'echo wrong >"$6"'
  run --separate-stderr bs_core_fetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not hash to the pin's"* ]]
}

@test "the library version and hash in the pin fetch from the registry and unpack to playwright-core" {
  bs_need_core
  [ -f "$CORE/cli.js" ]
  [ -f "$CORE/browsers.json" ]
}

@test "every revision the pinned library asks for resolves to a finished install in the set" {
  bs_need_core
  deploy
  [ "$status" -eq 0 ]
  local dir
  while read -r dir; do
    [ -f "$BP/$dir/INSTALLATION_COMPLETE" ] || {
      echo "the library asks for $dir and the set has none" >&2
      return 1
    }
  done < <(jq -r '.browsers[] | select(.name == "chromium" or .name == "chromium-headless-shell" or .name == "webkit" or .name == "ffmpeg")
    | "\(.name | gsub("-"; "_"))-\(.revision)"' "$CORE/browsers.json")
}

@test "a real playwright install of chromium downloads nothing, and deletes nothing it does not own" {
  bs_need_core
  deploy
  [ "$status" -eq 0 ]
  # A decoy no client names: its removal shows the cleanup ran at all.
  mkdir "$BP/firefox-9999"
  local before
  before="$(cd "$BP" && find . -path ./.links -prune -o -print | sort | grep -v firefox-9999)"
  bs_playwright install chromium
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing unused browser at "*"firefox-9999"* ]]
  [[ "$output" != *"Removing unused browser at "*"/chromium"* ]]
  [[ "$output" != *"Downloading"* ]]
  [ "$(cd "$BP" && find . -path ./.links -prune -o -print | sort)" = "$before" ]
  deploy --check
  [ "$status" -eq 0 ]
}

@test "a real playwright uninstall removes no directory, alias or client of the set" {
  bs_need_core
  deploy
  [ "$status" -eq 0 ]
  bs_playwright install chromium
  local before clients
  before="$(cd "$BP" && find . -path ./.links -prune -o -print | sort)"
  clients="$(cat "$BP"/.links/dotfiles-* | cksum)"
  touch -t 200001020000 "$BATS_TEST_TMPDIR/ref"
  find "$BP/.links" "$BP/.dotfiles/clients" -type f -exec touch -t 200001010000 {} +
  bs_playwright uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"browsers left, used by other Playwright installations"* ]]
  [ "$(cd "$BP" && find . -path ./.links -prune -o -print | sort)" = "$before" ]
  [ "$(cat "$BP"/.links/dotfiles-* | cksum)" = "$clients" ]
  [ -z "$(find "$BP/.dotfiles/clients" -type f -newer "$BATS_TEST_TMPDIR/ref")" ]
  deploy --check
  [ "$status" -eq 0 ]
}
