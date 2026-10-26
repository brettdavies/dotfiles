#!/usr/bin/env bats
# Tests for the Taildrive mount helpers in config/shell/taildrive.sh
#
# Run: bats tests/taildrive.bats
#
# Everything the helper touches outside the shell is replaced with a function:
# `uname` (the file defines nothing off macOS, so the stub lets Linux CI run
# these), `curl` and `osascript` (the endpoint probe and the Finder mount),
# `diskutil`, and `_taildrive_mounted` (the mount table). Nothing here reaches
# the network or /Volumes.

TAILDRIVE_SH="$BATS_TEST_DIRNAME/../config/shell/taildrive.sh"

setup() {
  export OSASCRIPT_LOG="$BATS_TEST_TMPDIR/osascript.log"
  export MOUNT_TABLE="$BATS_TEST_TMPDIR/mount-table"
  export TAILDRIVE_SHARES="ns/host-a/alpha,ns/host-b/beta"
  : >"$MOUNT_TABLE"
}

# Put a share's mount point in the table before the helper runs.
given_mounted() {
  printf '%s\n' "$1" >>"$MOUNT_TABLE"
}

# One stub block for every wrapper below, written so bash and zsh both read
# it. A successful osascript adds the share's mount point to the table, the
# way a real mount does. Each stub succeeds unless a test sets its knob:
# CURL_EXIT, OSASCRIPT_EXIT (or OSASCRIPT_FAIL_FOR, a substring of the one
# share URL that should fail), DISKUTIL_EXIT, and MOUNT_LANDS=0 for a mount
# Finder accepts but puts somewhere else. Set a knob as a prefix on the `run`
# call so it also reaches the zsh child.
STUBS='
  uname() { echo Darwin; }
  curl() { return "${CURL_EXIT:-0}"; }
  osascript() {
    _url=""
    for _a in "$@"; do _url=$_a; done
    printf "%s\n" "$_url" >>"$OSASCRIPT_LOG"
    if [ -n "${OSASCRIPT_FAIL_FOR:-}" ]; then
      case "$_url" in *"$OSASCRIPT_FAIL_FOR"*) return 1 ;; esac
    fi
    [ "${OSASCRIPT_EXIT:-0}" -eq 0 ] || return "${OSASCRIPT_EXIT}"
    [ "${MOUNT_LANDS:-1}" -eq 1 ] &&
      printf "/Volumes/%s\n" "${_url##*/}" >>"$MOUNT_TABLE"
    return 0
  }
  diskutil() { echo "diskutil $*"; return "${DISKUTIL_EXIT:-0}"; }
'

# The mount-table probe reads /sbin/mount by absolute path, so the seam the
# tests replace is the helper around it. Sourcing the file defines the real
# one, so each override lands after the `.` below.
MOUNT_TABLE_STUB='
  _taildrive_mounted() { grep -qxF -- "$1" "$MOUNT_TABLE" 2>/dev/null; }
'

# Stubs must be defined in the same shell that sources the helper, so each
# test goes through a wrapper rather than sourcing at file scope.
mount_with() {
  eval "$STUBS"
  # shellcheck disable=SC1090
  . "$TAILDRIVE_SH"
  eval "$MOUNT_TABLE_STUB"
  taildrive-mount "$@"
}

unmount_with() {
  eval "$STUBS"
  # shellcheck disable=SC1090
  . "$TAILDRIVE_SH"
  eval "$MOUNT_TABLE_STUB"
  taildrive-unmount
}

# The vault hook reaches the helper through `zsh -c`, so the same stubs are
# also driven from a bare zsh; -f skips every rc file, keeping it hermetic.
mount_with_zsh() {
  zsh -f -c "$STUBS"'
    . "$1"
    '"$MOUNT_TABLE_STUB"'
    shift
    taildrive-mount "$@"
  ' zsh "$TAILDRIVE_SH" "$@"
}

# The real probe, reading the machine's own mount table.
probe_real() {
  eval "$STUBS"
  # shellcheck disable=SC1090
  . "$TAILDRIVE_SH"
  _taildrive_mounted "$1"
}

mount_attempts() {
  [ -f "$OSASCRIPT_LOG" ] || {
    echo 0
    return
  }
  wc -l <"$OSASCRIPT_LOG" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Default: every share
# ---------------------------------------------------------------------------

@test "no arguments mounts every share" {
  run mount_with
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 2 ]
  [[ "$output" == *"mounted: /Volumes/alpha"* ]]
  [[ "$output" == *"mounted: /Volumes/beta"* ]]
}

# ---------------------------------------------------------------------------
# Share-name filter
#
# `mux vault` mounts only the vault share; the other shares' hosts may be
# offline, and each unreachable WebDAV mount stalls before failing.
# ---------------------------------------------------------------------------

@test "a share name mounts only that share" {
  run mount_with beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 1 ]
  [[ "$(cat "$OSASCRIPT_LOG")" == *"/ns/host-b/beta"* ]]
  [[ "$output" != *"alpha"* ]]
}

@test "an unknown share name is an error and mounts nothing" {
  run mount_with nope
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"nope"* ]]
}

@test "an unknown name alongside a known one mounts nothing" {
  run mount_with beta nope
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
}

@test "two share names mount exactly those shares" {
  TAILDRIVE_SHARES="ns/host-a/alpha,ns/host-b/beta,ns/host-c/gamma" \
    run mount_with alpha gamma
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 2 ]
  [[ "$(cat "$OSASCRIPT_LOG")" == *"/ns/host-a/alpha"* ]]
  [[ "$(cat "$OSASCRIPT_LOG")" == *"/ns/host-c/gamma"* ]]
  [[ "$(cat "$OSASCRIPT_LOG")" != *"beta"* ]]
}

@test "a name given twice mounts its share once" {
  run mount_with beta beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 1 ]
}

@test "every unknown name is listed in the error" {
  run mount_with nope1 nope2
  [ "$status" -eq 1 ]
  [[ "$output" == *"nope1"* ]]
  [[ "$output" == *"nope2"* ]]
}

# Names match the share's last path component exactly: no prefixes, no other
# components of the owner-namespace/host/sharename entry, no patterns.
@test "a partial share name is rejected" {
  run mount_with alph
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
}

@test "a host component is not a share name" {
  run mount_with host-a
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
}

@test "share names match literally, not as patterns" {
  run mount_with a.pha
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
}

@test "a dash-prefixed name is an unknown share, not an option" {
  run mount_with -x
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"not in TAILDRIVE_SHARES: '-x'"* ]]
}

# A trailing comma leaves an empty entry in the share list; an empty name must
# not match it and quietly mount nothing.
@test "an empty share name is an error even when the list has empty entries" {
  TAILDRIVE_SHARES="ns/host-a/alpha,,ns/host-b/beta," run mount_with ""
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"not in TAILDRIVE_SHARES: ''"* ]]
}

# The loop that selects shares must match names the same way validation does,
# rather than through a word split that the caller's IFS controls.
@test "a caller's IFS does not change which shares are selected" {
  IFS=, run mount_with alpha beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 2 ]
  [[ "$output" == *"mounted: /Volumes/alpha"* ]]
  [[ "$output" == *"mounted: /Volumes/beta"* ]]
}

# ---------------------------------------------------------------------------
# Share list
# ---------------------------------------------------------------------------

# Two hosts exporting the same share name collapse onto one /Volumes path,
# where the second would report the first's mount as its own.
@test "share names that collide under /Volumes are an error" {
  TAILDRIVE_SHARES="ns/host-a/vault,ns/host-b/vault" run mount_with
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"collide"* ]]
  [[ "$output" == *"vault"* ]]
}

# Space around an entry is easy to write and would otherwise reach the URL.
@test "surrounding whitespace in the share list is trimmed" {
  TAILDRIVE_SHARES="ns/host-a/alpha, ns/host-b/beta " run mount_with beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 1 ]
  [[ "$(cat "$OSASCRIPT_LOG")" == *"/ns/host-b/beta"* ]]
  [[ "$(cat "$OSASCRIPT_LOG")" != *" "* ]]
}

@test "unset TAILDRIVE_SHARES is an error" {
  unset TAILDRIVE_SHARES
  run mount_with
  [ "$status" -eq 1 ]
  [[ "$output" == *"TAILDRIVE_SHARES"* ]]
}

@test "unset TAILDRIVE_SHARES is an error for unmount too" {
  unset TAILDRIVE_SHARES
  run unmount_with
  [ "$status" -eq 1 ]
  [[ "$output" == *"TAILDRIVE_SHARES"* ]]
}

@test "empty entries in TAILDRIVE_SHARES are skipped" {
  TAILDRIVE_SHARES="ns/host-a/alpha,,ns/host-b/beta," run mount_with
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Endpoint check
#
# A share list or name problem is reported before the endpoint is probed, so
# a typo gets an immediate answer even while tailscaled is down.
# ---------------------------------------------------------------------------

@test "an unreachable endpoint is an error and mounts nothing" {
  CURL_EXIT=1 run mount_with
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"unreachable"* ]]
}

@test "an unknown share name is reported before the endpoint is probed" {
  CURL_EXIT=1 run mount_with nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in TAILDRIVE_SHARES"* ]]
  [[ "$output" != *"unreachable"* ]]
}

# ---------------------------------------------------------------------------
# Mount outcomes
# ---------------------------------------------------------------------------

# The vault session's start hook keys off this exit status, so a share that
# Finder refused must not report success.
@test "a failed mount is reported, the remaining shares still proceed, and the exit is non-zero" {
  OSASCRIPT_EXIT=1 run mount_with
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 2 ]
  [[ "$output" == *"FAILED: /Volumes/alpha"* ]]
  [[ "$output" == *"FAILED: /Volumes/beta"* ]]
  [[ "$output" != *" mounted:"* ]]
}

@test "one failed mount among successes still exits non-zero" {
  OSASCRIPT_FAIL_FOR=/alpha run mount_with
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 2 ]
  [[ "$output" == *"FAILED: /Volumes/alpha"* ]]
  [[ "$output" == *"mounted: /Volumes/beta"* ]]
}

@test "an already-mounted share is skipped without a mount attempt" {
  given_mounted /Volumes/beta
  run mount_with beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"already mounted: /Volumes/beta"* ]]
}

# Finder reports success but mounts at /Volumes/<name>-1 when the path is
# taken, which would leave the session's panes on a stale local directory.
@test "a mount that lands elsewhere is a failure, not a success" {
  MOUNT_LANDS=0 run mount_with beta
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 1 ]
  [[ "$output" == *"FAILED: /Volumes/beta"* ]]
  [[ "$output" != *" mounted: "* ]]
}

# An attach of a working session must not fail because the tailnet is
# reconnecting, so a fully-mounted request never reaches the probe.
@test "every share already mounted returns without probing the endpoint" {
  given_mounted /Volumes/beta
  CURL_EXIT=1 run mount_with beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"already mounted: /Volumes/beta"* ]]
  [[ "$output" != *"unreachable"* ]]
}

@test "a share still unmounted is mounted even when another is up" {
  given_mounted /Volumes/alpha
  run mount_with
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 1 ]
  [[ "$output" == *"already mounted: /Volumes/alpha"* ]]
  [[ "$output" == *"mounted: /Volumes/beta"* ]]
}

# ---------------------------------------------------------------------------
# Unmount
# ---------------------------------------------------------------------------

@test "unmount detaches only the shares that are mounted" {
  given_mounted /Volumes/beta
  run unmount_with
  [ "$status" -eq 0 ]
  [[ "$output" == *"unmounted: /Volumes/beta"* ]]
  [[ "$output" != *"/Volumes/alpha"* ]]
}

# diskutil refuses while a process holds the volume, which is the ordinary
# case with a session rooted there.
@test "a refused unmount is reported and exits non-zero" {
  given_mounted /Volumes/beta
  DISKUTIL_EXIT=1 run unmount_with
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: /Volumes/beta"* ]]
}

# ---------------------------------------------------------------------------
# Under zsh
# ---------------------------------------------------------------------------

@test "under zsh a share name mounts only that share" {
  run mount_with_zsh beta
  [ "$status" -eq 0 ]
  [ "$(mount_attempts)" -eq 1 ]
  [[ "$output" == *"mounted: /Volumes/beta"* ]]
  [[ "$output" != *"alpha"* ]]
}

# The hook's `|| exit 1` keys off this status, and the tail that produces it
# runs through constructs zsh and bash read differently.
@test "under zsh a failed mount exits non-zero" {
  OSASCRIPT_EXIT=1 run mount_with_zsh beta
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: /Volumes/beta"* ]]
}

@test "under zsh an already-mounted share needs no endpoint probe" {
  given_mounted /Volumes/beta
  CURL_EXIT=1 run mount_with_zsh beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"already mounted: /Volumes/beta"* ]]
}

@test "under zsh an unknown share name is an error" {
  run mount_with_zsh nope
  [ "$status" -eq 1 ]
  [ "$(mount_attempts)" -eq 0 ]
  [[ "$output" == *"nope"* ]]
}

# ---------------------------------------------------------------------------
# Mount table
# ---------------------------------------------------------------------------

# A share name is not a pattern: `.` in one must not alias another volume.
@test "the mount-table probe matches literally, not as a pattern" {
  [ -x /sbin/mount ] || skip "no /sbin/mount on this machine"
  run probe_real /
  [ "$status" -eq 0 ]
  run probe_real .
  [ "$status" -ne 0 ]
}

# The hook's PATH is whatever launched it, and `mount` lives only in /sbin on
# macOS: a bare name there reads as "nothing is mounted".
@test "the mount-table probe works without /sbin on PATH" {
  [ -x /sbin/mount ] || skip "no /sbin/mount on this machine"
  PATH=/usr/bin:/bin run probe_real /
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Platform guard
# ---------------------------------------------------------------------------

@test "off macOS the helper defines nothing" {
  run bash -c '
    uname() { echo Linux; }
    . "$1" && ! type taildrive-mount 2>/dev/null
  ' bash "$TAILDRIVE_SH"
  [ "$status" -eq 0 ]
}
