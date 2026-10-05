#!/usr/bin/env bats
# Tests for scripts/launchd-user-path.sh, which compares the PATH launchd hands
# GUI applications and LaunchAgents with the value declared in
# config/launchd/user-path.
#
# Run: bats tests/launchd-user-path.bats
#
# Every macOS command the script touches is a stub in a PATH-prepended
# directory: `uname` (so Linux CI passes the Darwin gate), `plutil` (reads the
# value from PLUTIL_STATE), `stat` and `sysctl` (the plist mtime and boot time
# behind the pending-reboot note), and `sudo` (logs its argv to CALLS and writes
# the new value to PLUTIL_STATE). Nothing reads or writes the host's launchd
# config: LAUNCHD_USER_PLIST points at a per-test file.

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SCRIPT="$REPO_ROOT/scripts/launchd-user-path.sh"
DECLARED_FILE="$REPO_ROOT/config/launchd/user-path"
STOW_DEPLOY="$REPO_ROOT/scripts/stow-deploy"
LINT_SHELL="$REPO_ROOT/scripts/lint-shell"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export PLUTIL_STATE="$BATS_TEST_TMPDIR/plutil-state"
  export LAUNCHD_USER_PLIST="$BATS_TEST_TMPDIR/user.plist"
  mkdir -p "$STUBS"
  : >"$CALLS"
  : >"$LAUNCHD_USER_PLIST"
  DECLARED=$(cat "$DECLARED_FILE")

  stub uname 'echo "${STUB_UNAME:-Darwin}"'
  stub plutil 'log plutil "$@"
    [ -s "$PLUTIL_STATE" ] || { echo "Could not extract value" >&2; exit 1; }
    cat "$PLUTIL_STATE"'
  stub stat 'echo "${STUB_MTIME:-100}"'
  stub sysctl 'echo "{ sec = ${STUB_BOOT:-200}, usec = 0 } Thu Jan  1 00:03:20 1970"'
  stub sudo 'log sudo "$@"
    printf "%s\n" "${@: -1}" >"$PLUTIL_STATE"'
  PATH="$STUBS:$PATH"
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

# --- Declared value ---

@test "the declared PATH puts Homebrew ahead of /usr/bin and keeps launchd's default dirs" {
  [ "$(grep -c . "$DECLARED_FILE")" -eq 1 ]
  case ":$DECLARED:" in
    :/opt/homebrew/bin:*) ;;
    *)
      echo "declared PATH does not lead with /opt/homebrew/bin: $DECLARED" >&2
      return 1
      ;;
  esac
  for dir in /usr/bin /bin /usr/sbin /sbin; do
    [[ ":$DECLARED:" == *":$dir:"* ]] || {
      echo "declared PATH drops launchd default $dir" >&2
      return 1
    }
  done
}

# --- Report mode ---

@test "an in-sync value reports in sync and exits 0" {
  printf '%s\n' "$DECLARED" >"$PLUTIL_STATE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  [[ "$output" != *"reboot"* ]]
}

@test "an in-sync value written after the last boot notes the pending reboot" {
  printf '%s\n' "$DECLARED" >"$PLUTIL_STATE"
  STUB_MTIME=300 STUB_BOOT=200 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  [[ "$output" == *"next reboot"* ]]
}

@test "a drifted value prints the exact fix and the reboot note, and exits 1" {
  printf '%s\n' "/usr/bin:/bin:/usr/sbin:/sbin" >"$PLUTIL_STATE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"current:  /usr/bin:/bin:/usr/sbin:/sbin"* ]]
  [[ "$output" == *"sudo launchctl config user path $DECLARED"* ]]
  [[ "$output" == *"reboot"* ]]
}

@test "a missing config file reports the value unset and exits 1" {
  LAUNCHD_USER_PLIST="$BATS_TEST_TMPDIR/absent.plist" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"current:  <unset>"* ]]
  [[ "$output" == *"sudo launchctl config user path $DECLARED"* ]]
}

@test "report mode never runs sudo" {
  printf '%s\n' "/usr/bin:/bin" >"$PLUTIL_STATE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  run ! grep -q '^sudo' "$CALLS"
}

@test "a non-macOS host is a no-op that exits 0 without reading launchd config" {
  STUB_UNAME=Linux run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"macOS-only"* ]]
  run ! grep -q '^plutil' "$CALLS"
}

@test "an unknown argument is a usage error" {
  run "$SCRIPT" --force
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

# --- Apply mode ---

@test "--apply on a drifted value runs the launchctl fix through sudo" {
  printf '%s\n' "/usr/bin:/bin" >"$PLUTIL_STATE"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -qx "sudo launchctl config user path $DECLARED" "$CALLS"
  [[ "$output" == *"reboot"* ]]
}

@test "--apply on an in-sync value runs nothing" {
  printf '%s\n' "$DECLARED" >"$PLUTIL_STATE"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  run ! grep -q '^sudo' "$CALLS"
}

# --- Wiring ---

@test "stow-deploy runs the check and never applies it" {
  grep -q 'scripts/launchd-user-path.sh"' "$STOW_DEPLOY"
  run ! bash -c "grep -v '^[[:space:]]*#' '$STOW_DEPLOY' | grep -q 'launchd-user-path.sh.*--apply'"
}

@test "the script is executable and enumerated as a lint target" {
  [ -x "$SCRIPT" ]
  # Present in both _is_target and _all_targets, or lint skips it silently.
  [ "$(grep -c 'scripts/launchd-user-path.sh' "$LINT_SHELL")" -ge 2 ]
}
