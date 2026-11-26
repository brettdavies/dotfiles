#!/usr/bin/env bats
# Tests for scripts/rexurrect-deploy.sh, which installs a pinned rexurrect release after checking its archive's
# SHA-256 and its GitHub attestation. The release is a fixture archive that a gh stub serves, and the script under test
# is a copy whose pinned hashes are rewritten to the fixture's, so no test reaches the network.
#
# Run: bats tests/rexurrect-deploy.bats
# run-tests: parallel

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/rexurrect-deploy.sh"
ZSHRC="$REPO_ROOT/stow/zsh/dot-zshrc"
CONFIG="$REPO_ROOT/stow/rex/dot-config/rexurrect/config.toml"
ARCHIVE=rexurrect-x86_64-unknown-linux-musl.tar.xz

# sha FILE: FILE's SHA-256.
sha() {
  local sum
  read -r sum _ < <(sha256sum "$1")
  printf '%s' "$sum"
}

# fixture_archive DIR MARK: a release archive in DIR whose binary prints MARK and logs each run to $RAN_LOG.
fixture_archive() {
  local root=$1/rexurrect-x86_64-unknown-linux-musl
  mkdir -p "$root"
  printf '#!/bin/sh\necho run >>"$RAN_LOG"\necho "%s"\n' "$2" >"$root/rexurrect"
  chmod 755 "$root/rexurrect"
  printf 'print -r -- recorder %s\n' "$2" >"$root/rexurrect.plugin.zsh"
  printf 'MIT\n' >"$root/LICENSE"
  tar -cJf "$1/$ARCHIVE" -C "$1" rexurrect-x86_64-unknown-linux-musl
}

# pinned COPY ARCHIVE_SHA BINARY_SHA PLUGIN_SHA: the deploy script copied to COPY with those pins.
pinned() {
  sed -E -e "s/^(REXURRECT_ARCHIVE_SHA256)=.*/\1=$2/" -e "s/^(REXURRECT_BINARY_SHA256)=.*/\1=$3/" \
    -e "s/^(REXURRECT_PLUGIN_SHA256)=.*/\1=$4/" "$SCRIPT" >"$1"
  chmod 555 "$1"
}

setup_file() {
  load lib/platform
  require_linux "the deploy installs a Linux build and checks it with sha256sum"
  local f=$BATS_FILE_TMPDIR root
  fixture_archive "$f/good" "rexurrect 0.6.0"
  fixture_archive "$f/bad" "rexurrect tampered"
  root=$f/good/rexurrect-x86_64-unknown-linux-musl
  GOOD_BINARY=$root/rexurrect GOOD_PLUGIN=$root/rexurrect.plugin.zsh
  pinned "$f/deploy" "$(sha "$f/good/$ARCHIVE")" "$(sha "$GOOD_BINARY")" "$(sha "$GOOD_PLUGIN")"
  pinned "$f/deploy-wrong-binary-pin" "$(sha "$f/good/$ARCHIVE")" "$(printf '0%.0s' {1..64})" "$(sha "$GOOD_PLUGIN")"
  export GOOD_BINARY GOOD_PLUGIN

  mkdir -p "$f/stubs"
  stub_uname "$f/stubs"
  cat >"$f/stubs/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$CALLS"
if [ "$1 $2" = "release download" ]; then
  shift 2
  while [ "$#" -gt 0 ]; do
    case $1 in
      --pattern) pattern=$2 ;;
      --dir) dir=$2 ;;
    esac
    shift
  done
  cp "$STUB_ARCHIVE" "$dir/$pattern"
elif [ "$1 $2" = "attestation verify" ]; then
  exit "${STUB_ATTEST_RC:-0}"
fi
EOF
  chmod 555 "$f/stubs/gh"
}

setup() {
  DEST=$BATS_TEST_TMPDIR/dest
  BIN=$DEST/.local/bin/rexurrect
  PLUGIN=$DEST/.local/share/rexurrect/rexurrect.plugin.zsh
  export CALLS=$BATS_TEST_TMPDIR/calls.log RAN_LOG=$BATS_TEST_TMPDIR/ran.log
  export STUB_ARCHIVE=$BATS_FILE_TMPDIR/good/$ARCHIVE
  export STUB_UNAME=Linux STUB_UNAME_M=x86_64
  export PATH="$BATS_FILE_TMPDIR/stubs:$PATH"
  DEPLOY=$BATS_FILE_TMPDIR/deploy
  : >"$CALLS"
}

# nothing_installed: the deploy left no rexurrect file under DEST.
nothing_installed() {
  [ ! -e "$BIN" ] && [ ! -e "$PLUGIN" ]
}

@test "a verified archive installs the binary and the zsh recorder under --dest" {
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$GOOD_BINARY" "$BIN"
  [ -n "$(find "$BIN" -perm 0755)" ]
  cmp "$GOOD_PLUGIN" "$PLUGIN"
  grep -qx "gh release download v0.6.0 --repo cemcatik/rexurrect --pattern $ARCHIVE --dir .*" "$CALLS"
  grep -qx "gh attestation verify .*/$ARCHIVE --repo cemcatik/rexurrect" "$CALLS"
  [[ $output == *"OK: rexurrect 0.6.0 installed at $BIN"* ]]
  [ ! -e "$RAN_LOG" ]
}

@test "a checksum mismatch installs nothing and names the archive, the pin, and both hashes" {
  export STUB_ARCHIVE=$BATS_FILE_TMPDIR/bad/$ARCHIVE
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 1 ]
  nothing_installed
  [[ $output == *"FATAL: $ARCHIVE (rexurrect 0.6.0)"* ]]
  [[ $output == *"$(sha "$BATS_FILE_TMPDIR/good/$ARCHIVE")"* ]]
  [[ $output == *"$(sha "$STUB_ARCHIVE")"* ]]
  [[ $output == *"nothing was installed"* ]]
  [[ $output == *"scripts/rexurrect-deploy.sh"* ]]
  [ "$(grep -c '^gh attestation' "$CALLS")" -eq 0 ]
}

@test "a failed attestation installs nothing and prints the verify command to rerun" {
  export STUB_ATTEST_RC=1
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 1 ]
  nothing_installed
  [[ $output == *"FATAL: $ARCHIVE (rexurrect 0.6.0)"* ]]
  [[ $output == *"nothing was installed"* ]]
  [[ $output == *"gh attestation verify $ARCHIVE --repo cemcatik/rexurrect"* ]]
}

@test "an archive whose binary differs from the pinned binary installs nothing" {
  run "$BATS_FILE_TMPDIR/deploy-wrong-binary-pin" --dest "$DEST"
  [ "$status" -eq 1 ]
  nothing_installed
  [[ $output == *"nothing was installed"* ]]
}

@test "a rerun over its own install reports nothing to do, without downloading or running the binary" {
  "$DEPLOY" --dest "$DEST" >/dev/null
  : >"$CALLS"
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to do"* ]]
  [ ! -s "$CALLS" ]
  [ ! -e "$RAN_LOG" ]
}

@test "a binary at the target with another checksum is replaced without being run, whatever version it reports" {
  mkdir -p "${BIN%/*}"
  printf '#!/bin/sh\necho run >>"$RAN_LOG"\necho "rexurrect 0.6.0"\n' >"$BIN"
  chmod 755 "$BIN"
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$GOOD_BINARY" "$BIN"
  [ ! -e "$RAN_LOG" ]
}

@test "off Linux the deploy does nothing" {
  export STUB_UNAME=Darwin
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 0 ]
  [[ $output == *"NOTE:"*"Darwin"* ]]
  nothing_installed
  [ ! -s "$CALLS" ]
}

@test "a machine with no pinned build installs nothing and names its architecture" {
  export STUB_UNAME_M=aarch64
  run "$DEPLOY" --dest "$DEST"
  [ "$status" -eq 1 ]
  [[ $output == *"FATAL:"*"aarch64"* ]]
  nothing_installed
}

@test "zshrc sources the recorder from where the deploy installs it, only when it is there" {
  command -v zsh >/dev/null || skip "zsh not installed"
  local line home=$BATS_TEST_TMPDIR/home
  [ "$(grep -cF 'rexurrect.plugin.zsh' "$ZSHRC")" -eq 1 ]
  line=$(grep -F 'rexurrect.plugin.zsh' "$ZSHRC")
  [[ $line == *'"$HOME/.local/share/rexurrect/rexurrect.plugin.zsh"'* ]]
  line=${line//\$HOME/$home}
  run zsh -fc "$line; print -r -- end"
  [ "$output" = end ]
  mkdir -p "$home/.local/share/rexurrect"
  printf 'print -r -- sourced\n' >"$home/.local/share/rexurrect/rexurrect.plugin.zsh"
  run zsh -fc "$line; print -r -- end"
  [ "$output" = "sourced
end" ]
}

@test "the rexurrect installed here accepts the stowed config, which it reads before it reaches a server" {
  local bin=$HOME/.local/bin/rexurrect
  [ -x "$bin" ] || skip "rexurrect not installed"
  REXURRECT_STATE_DIR=$BATS_TEST_TMPDIR/state REXURRECT_CONFIG=$CONFIG REX_SERVER=unix://$BATS_TEST_TMPDIR/no.sock \
    run "$bin" restore --dry-run </dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"$BATS_TEST_TMPDIR/no.sock"* ]]
  [[ $output != *"$CONFIG"* ]]
}
