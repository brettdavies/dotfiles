#!/usr/bin/env bats
# Tests for the .links clients scripts/playwright-browsers-deploy.sh keeps: when it writes one, how it repairs one, what
# it removes, and what it leaves alone because it did not make it.
#
# Run: bats tests/playwright-browsers-clients.bats
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
