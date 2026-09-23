#!/usr/bin/env bats
# Tests for stow/local/dot-local/bin/mac-open-here, the Mac half of the yazi
# hand-off.
#
# Run: bats tests/mac-open-here.bats
#
# Every macOS command the receiver touches is a stub in a PATH-prepended
# directory: `uname` (so Linux CI passes the Darwin guard), `open`, `zsh` (the
# Taildrive mount helper runs through it), `ls` (the share-root access probe),
# and `mkdir` / `mv`, which pass through to the real commands unless a test
# makes them fail. Each stub appends its argv to CALLS. The VS Code CLI is a
# stub reached through MAC_OPEN_CODE_CLI. Nothing here reaches /Volumes or a
# real Downloads folder: each receiver run gets HOME=RECV_HOME, a per-test
# directory, and the bats process keeps its own HOME.

SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/mac-open-here"

bats_require_minimum_version 1.5.0

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  RECV_HOME="$BATS_TEST_TMPDIR/home"
  export MAC_OPEN_CODE_CLI="$STUBS/code"
  mkdir -p "$STUBS" "$RECV_HOME"
  : >"$CALLS"

  stub uname 'echo "${STUB_UNAME:-Darwin}"'
  stub open 'log open "$@"
    [ -z "${OPEN_ERR:-}" ] || { echo "$OPEN_ERR" >&2; exit 1; }'
  stub zsh 'log zsh "$@"
    [ -z "${MOUNT_ERR:-}" ] || { echo "$MOUNT_ERR" >&2; exit 1; }
    echo "  already mounted: /Volumes/dev"'
  stub ls 'log ls "$@"
    [ -z "${LS_ERR:-}" ] || { echo "$LS_ERR" >&2; exit 1; }'
  stub code 'exec 3>&-
    log code "$@"
    sleep "${CODE_SLEEP:-0}"'
  passthrough mkdir MKDIR_ERR
  passthrough mv MV_ERR
  passthrough cat CAT_ERR
}

# stub NAME BODY: an executable NAME whose body can call `log`.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
log() { printf '%s\n' "\$*" >>"\$CALLS"; }
$2
EOF
  chmod +x "$STUBS/$1"
}

# passthrough NAME KNOB: runs the real NAME unless KNOB holds an error line.
passthrough() {
  local real
  real=$(command -v "$1")
  stub "$1" "[ -z \"\${$2:-}\" ] || { echo \"\$$2\" >&2; exit 1; }
    exec $real \"\$@\""
}

receiver() { HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" "$@"; }

cache_dir() { printf '%s\n' "$RECV_HOME/Downloads/mac-open"; }

# The CLI stub runs detached, so its log line lands after the receiver exits.
wait_for_calls() {
  for _ in $(seq 1 40); do
    [ -s "$CALLS" ] && return 0
    sleep 0.05
  done
}

@test "mac-open-here passes shellcheck" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" stow/local/dot-local/bin/mac-open-here
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Usage and platform
# ---------------------------------------------------------------------------

@test "an unknown subcommand prints usage and exits 2" {
  receiver frobnicate
  [ "$status" -eq 2 ]
  [[ $stderr == *"usage:"* ]]
}

@test "no subcommand prints usage and exits 2" {
  receiver
  [ "$status" -eq 2 ]
  [[ $stderr == *"usage:"* ]]
}

@test "a non-Darwin host exits non-zero naming macOS and runs nothing" {
  STUB_UNAME=Linux receiver edit srv /a.md
  [ "$status" -ne 0 ]
  [[ $stderr == *"not-macos"* ]]
  [ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# edit
# ---------------------------------------------------------------------------

@test "edit opens every path in one CLI call through the server's Remote-SSH authority" {
  receiver edit srv /a.md /b.md
  [ "$status" -eq 0 ]
  wait_for_calls
  [ "$(cat "$CALLS")" = "code --reuse-window --remote ssh-remote+srv /a.md /b.md" ]
}

@test "edit addresses an extension-less file by vscode-remote file URI" {
  receiver edit srv "/home/u/Makefile" "/home/u/.bashrc" "/home/u/my notes"
  [ "$status" -eq 0 ]
  wait_for_calls
  expected="code --reuse-window --remote ssh-remote+srv"
  expected+=" --file-uri vscode-remote://ssh-remote+srv/home/u/Makefile"
  expected+=" --file-uri vscode-remote://ssh-remote+srv/home/u/.bashrc"
  expected+=" --file-uri vscode-remote://ssh-remote+srv/home/u/my%20notes"
  [ "$(cat "$CALLS")" = "$expected" ]
}

@test "edit sends a trailing-dot name by URI and percent-encodes each byte of a non-ASCII name" {
  receiver edit srv "/home/u/notes." "/home/u/café"
  [ "$status" -eq 0 ]
  wait_for_calls
  expected="code --reuse-window --remote ssh-remote+srv"
  expected+=" --file-uri vscode-remote://ssh-remote+srv/home/u/notes."
  expected+=" --file-uri vscode-remote://ssh-remote+srv/home/u/caf%C3%A9"
  [ "$(cat "$CALLS")" = "$expected" ]
}

@test "edit with no VS Code CLI names code-cli-missing and its fix, and launches nothing" {
  MAC_OPEN_CODE_CLI="$BATS_TEST_TMPDIR/nowhere/code" receiver edit srv /a.md
  [ "$status" -ne 0 ]
  [[ $stderr == *"code-cli-missing"* ]]
  [[ $stderr == *"MAC_OPEN_CODE_CLI"* ]]
  [ ! -s "$CALLS" ]
}

@test "edit returns before a slow CLI exits" {
  start=$(date +%s%N)
  CODE_SLEEP=5 receiver edit srv /a.md
  elapsed_ms=$((($(date +%s%N) - start) / 1000000))
  [ "$status" -eq 0 ]
  [ "$elapsed_ms" -lt 2000 ]
  wait_for_calls
  grep -q '^code ' "$CALLS"
}

# ---------------------------------------------------------------------------
# view
# ---------------------------------------------------------------------------

@test "view mounts the share, checks it can read it, then opens the paths, in that order" {
  receiver view dev /Volumes/dev/x.pdf /Volumes/dev/y.png
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "zsh -c taildrive-mount \"\$1\" zsh dev" ]
  [ "$(sed -n 2p "$CALLS")" = "ls /Volumes/dev" ]
  [ "$(sed -n 3p "$CALLS")" = "open /Volumes/dev/x.pdf /Volumes/dev/y.png" ]
  [ -z "$output" ]
}

@test "view forwards the mount helper's failure and never opens" {
  MOUNT_ERR="  FAILED: /Volumes/dev — taildrive not permitted" receiver view dev /Volumes/dev/x.pdf
  [ "$status" -ne 0 ]
  [[ $stderr == *"mount-failed: FAILED: /Volumes/dev — taildrive not permitted"* ]]
  run ! grep -q '^open' "$CALLS"
}

@test "view without full disk access names the Remote Login setting and never opens" {
  LS_ERR="ls: /Volumes/dev: Operation not permitted" receiver view dev /Volumes/dev/x.pdf
  [ "$status" -ne 0 ]
  [[ $stderr == *"no-disk-access"* ]]
  [[ $stderr == *"Allow full disk access for remote users"* ]]
  run ! grep -q '^open' "$CALLS"
}

@test "view reports a failed open with its line" {
  OPEN_ERR="The file /Volumes/dev/x.pdf does not exist." receiver view dev /Volumes/dev/x.pdf
  [ "$status" -ne 0 ]
  [[ $stderr == *"open-failed: The file /Volumes/dev/x.pdf does not exist."* ]]
}

# ---------------------------------------------------------------------------
# receive
# ---------------------------------------------------------------------------

@test "receive writes the streamed bytes, leaves no part file, and opens the copy" {
  printf 'png-bytes\x00\x01\x02' >"$BATS_TEST_TMPDIR/shot.png"
  size=$(wc -c <"$BATS_TEST_TMPDIR/shot.png" | tr -d ' ')
  HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" receive shot.png "$size" <"$BATS_TEST_TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  copies=("$(cache_dir)"/*-shot.png)
  [ "${#copies[@]}" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/shot.png" "${copies[0]}"
  [ -z "$(find "$(cache_dir)" -name '*.part')" ]
  grep -qxF "open ${copies[0]}" "$CALLS"
  # The receiver prints the path as the operator reads it on the Mac.
  # shellcheck disable=SC2088
  [ "$output" = "~/Downloads/mac-open/${copies[0]##*/}" ]
}

@test "receive of a short stream reports short-copy, opens nothing, and leaves nothing" {
  printf 'only-part' >"$BATS_TEST_TMPDIR/cut"
  HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" receive shot.png 4096 <"$BATS_TEST_TMPDIR/cut"
  [ "$status" -ne 0 ]
  [[ $stderr == *"short-copy: 9 of 4096 bytes arrived"* ]]
  run ! grep -q '^open' "$CALLS"
  [ -z "$(find "$(cache_dir)" -type f)" ]
}

@test "receive never prunes an older copy" {
  mkdir -p "$(cache_dir)"
  old="$(cache_dir)/1000000000-annotated.pdf"
  echo kept >"$old"
  touch -d '2 days ago' "$old"
  printf 'x' >"$BATS_TEST_TMPDIR/one"
  HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" receive one 1 <"$BATS_TEST_TMPDIR/one"
  [ "$status" -eq 0 ]
  [ "$(cat "$old")" = "kept" ]
}

@test "receive of two same-named files in one second keeps both" {
  printf 'a' >"$BATS_TEST_TMPDIR/a"
  printf 'b' >"$BATS_TEST_TMPDIR/b"
  HOME="$RECV_HOME" PATH="$STUBS:$PATH" "$SCRIPT" receive shot.png 1 <"$BATS_TEST_TMPDIR/a"
  HOME="$RECV_HOME" PATH="$STUBS:$PATH" "$SCRIPT" receive shot.png 1 <"$BATS_TEST_TMPDIR/b"
  [ "$(for f in "$(cache_dir)"/*shot.png; do cat "$f"; echo; done | sort | tr -d '\n')" = "ab" ]
}

@test "receive refused by macOS at each step names the Remote Login setting" {
  refusal="Operation not permitted"
  for knob in MKDIR_ERR CAT_ERR MV_ERR OPEN_ERR; do
    : >"$CALLS"
    printf 'x' >"$BATS_TEST_TMPDIR/one"
    env "$knob=mac: $refusal" HOME="$RECV_HOME" PATH="$STUBS:$PATH" "$SCRIPT" receive one 1 \
      <"$BATS_TEST_TMPDIR/one" 2>"$BATS_TEST_TMPDIR/err" && false
    grep -q "no-disk-access" "$BATS_TEST_TMPDIR/err"
    grep -q "Allow full disk access for remote users" "$BATS_TEST_TMPDIR/err"
  done
}

@test "receive removes the part file when the rename fails" {
  printf 'x' >"$BATS_TEST_TMPDIR/one"
  MV_ERR="mv: disk full" HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" receive one 1 <"$BATS_TEST_TMPDIR/one"
  [ "$status" -ne 0 ]
  [[ $stderr == *"copy-failed: mv: disk full"* ]]
  [ -z "$(find "$(cache_dir)" -name '*.part')" ]
}

@test "receive removes the part file when the streaming write fails" {
  printf 'x' >"$BATS_TEST_TMPDIR/one"
  CAT_ERR="cat: write error: No space left on device" HOME="$RECV_HOME" PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" receive one 1 <"$BATS_TEST_TMPDIR/one"
  [ "$status" -ne 0 ]
  [[ $stderr == *"copy-failed: cat: write error"* ]]
  [ -z "$(find "$(cache_dir)" -name '*.part')" ]
}

@test "receive rejects a size that is not a byte count" {
  receiver receive shot.png 12k
  [ "$status" -eq 2 ]
  [[ $stderr == *"usage:"* ]]
}

@test "receive rejects a name that is a path" {
  receiver receive ../shot.png 1
  [ "$status" -eq 2 ]
}
