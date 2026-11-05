#!/usr/bin/env bats
# Tests for what scripts/playwright-browsers-deploy.sh finds in a cache it did not make, and what it will and will not
# delete: another tool's installs, a cache laid out by the old script, and clients that are wrong or planted.
#
# Run: bats tests/playwright-browsers-cache.bats
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

# The inode of a path: a file replaced by rename gets a new one, one written in place keeps it.
inode() {
  # shellcheck disable=SC2012 # stat's flag differs between GNU and BSD
  ls -i "$1" | cut -d' ' -f1
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

@test "a cache laid out by the old script and by Playwright installs becomes the set in one deploy" {
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

@test "a client link naming a path with .. or a record file, and a symlink out of the cache, survive a deploy" {
  deploy
  [ "$status" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  echo keep >"$BATS_TEST_TMPDIR/outside/file"
  printf '%s' "$BP/.dotfiles/clients/../../../outside" >"$BP/.links/dotfiles-evil"
  printf '%s' "$BP/chromium-8103038/.dotfiles-record" >"$BP/.links/dotfiles-chromium-9999"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BP/chromium-1100"
  deploy
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/outside/file" ]
  [ -f "$BP/chromium-8103038/.dotfiles-record" ]
  [ -e "$BP/.links/dotfiles-evil" ]
  [ -e "$BP/.links/dotfiles-chromium-9999" ]
  [ -L "$BP/chromium-1100" ]
  deploy --check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reason: stray-symlink; value: chromium-1100"* ]]
  [[ "$stderr" == *"reason: client-unrecognised; value: dotfiles-evil"* ]]
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
