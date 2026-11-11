#!/usr/bin/env bats
# Tests for scripts/sysctl-deploy.sh, which copies config/sysctl.d/ into
# /etc/sysctl.d/, applies it, and reads every key back from /proc/sys.
#
# `uname` is a PATH-prepended stub reporting Linux, so the --check tests run on
# a Mac too; live values come from a sandbox tree through SYSCTL_PROC_DIR.
#
# Run: bats tests/sysctl-deploy.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sysctl-deploy.sh"
SRC_DIR="$BATS_TEST_DIRNAME/../config/sysctl.d"
PIPE_CONF="$SRC_DIR/60-pipe-user-pages.conf"

setup() {
  DEST="$BATS_TEST_TMPDIR/sysctl.d"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$DEST" "$STUBS"
  printf '#!/usr/bin/env bash\necho "${STUB_UNAME:-Linux}"\n' >"$STUBS/uname"
  chmod +x "$STUBS/uname"
  PATH="$STUBS:$PATH"
}

# Stand in for /proc/sys with every shipped key at the value it ships, so a
# test changes only the key it is about.
fake_proc_matching_repo() {
  export SYSCTL_PROC_DIR="$BATS_TEST_TMPDIR/proc"
  local file key value
  for file in "$SRC_DIR"/*.conf; do
    while IFS='=' read -r key value; do
      key="${key// /}"
      mkdir -p "$SYSCTL_PROC_DIR/$(dirname "${key//.//}")"
      printf '%s\n' "${value# }" >"$SYSCTL_PROC_DIR/${key//.//}"
    done < <(grep -Ev '^[[:space:]]*([#;]|$)' "$file")
  done
}

@test "the pipe drop-in sets only fs.pipe-user-pages-soft, to 0" {
  run grep -Ev '^[[:space:]]*(#|$)' "$PIPE_CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "fs.pipe-user-pages-soft = 0" ]
}

@test "--dest copies every drop-in byte for byte, mode 0644" {
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  for src in "$SRC_DIR"/*.conf; do
    cmp "$src" "$DEST/$(basename "$src")"
    [ -n "$(find "$DEST/$(basename "$src")" -perm 0644)" ]
  done
  [[ "$output" == *"NOTE: copied 60-pipe-user-pages.conf to $DEST"* ]]
}

@test "a second --dest run reports nothing to copy" {
  "$SCRIPT" --dest "$DEST" >/dev/null
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to copy"* ]]
  [[ "$output" != *"NOTE: copied"* ]]
}

@test "--dest overwrites a drop-in that differs from the repo" {
  printf 'fs.pipe-user-pages-soft = 65536\n' >"$DEST/60-pipe-user-pages.conf"
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$PIPE_CONF" "$DEST/60-pipe-user-pages.conf"
}

@test "--dest into a missing directory fails the pre-flight (exit 1)" {
  run "$SCRIPT" --dest "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination not found"* ]]
}

@test "--check passes when the kernel holds every shipped value" {
  fake_proc_matching_repo
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: fs.pipe-user-pages-soft = 0"* ]]
}

@test "--check fails and names the key when the kernel holds the stock limit" {
  fake_proc_matching_repo
  printf '16384\n' >"$SYSCTL_PROC_DIR/fs/pipe-user-pages-soft"
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: fs.pipe-user-pages-soft is 16384, 60-pipe-user-pages.conf sets 0"* ]]
  [[ "$output" == *"systemd-analyze cat-config sysctl.d"* ]]
}

@test "--check fails when the kernel does not expose a shipped key" {
  fake_proc_matching_repo
  rm "$SYSCTL_PROC_DIR/fs/pipe-user-pages-soft"
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"fs.pipe-user-pages-soft from 60-pipe-user-pages.conf is not a setting this kernel exposes"* ]]
}

@test "--check and deploy are no-ops on macOS" {
  export STUB_UNAME=Darwin
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do on Darwin"* ]]
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do on Darwin"* ]]
}

@test "deploying without root fails the pre-flight and names sudo (exit 1)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: This script must be run as root (use sudo)"* ]]
}

@test "unknown flag, bare --dest, and extra arguments are usage errors (exit 2)" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --dest
  [ "$status" -eq 2 ]
  run "$SCRIPT" --check --dest "$DEST"
  [ "$status" -eq 2 ]
}
