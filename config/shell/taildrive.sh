# shellcheck shell=bash
# Taildrive mount helpers — macOS only.
# Linux clients should mount via SMB/cifs-utils from the SMB-exposing hosts.
[ "$(uname -s)" = "Darwin" ] || return 0

# Why AppleScript instead of `mount_webdav` directly: Finder mounts WebDAV
# through an SUID helper that has permission to create /Volumes/<name>.
# Direct `mount_webdav` from a user shell can't mkdir under /Volumes and
# silently fails. `osascript -e 'mount volume "..."'` delegates to that same
# helper.
#
# The share list lives in $TAILDRIVE_SHARES (set in ~/.secrets, which is
# git-crypt encrypted at rest). Format: comma-separated owner-namespace/host/
# sharename entries. Refresh with `tailscale drive list` on each host whenever
# the set changes. Mount points use the share's last path component as the
# volume name — keep share names unique across hosts.

_taildrive_shares() {
  if [ -z "${TAILDRIVE_SHARES:-}" ]; then
    echo "taildrive: TAILDRIVE_SHARES env var not set; configure in ~/.secrets" >&2
    return 1
  fi
  # Surrounding space is easy to write in the list and would otherwise survive
  # into the URL, where it mounts nothing while still printing a mount point.
  printf '%s\n' "$TAILDRIVE_SHARES" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# A share's mount point: the last path component under /Volumes.
_taildrive_mountpoint() {
  printf '/Volumes/%s\n' "${1##*/}"
}

# Absolute path because a hook's PATH may lack /sbin, and an empty mount table
# reads as "not mounted" — which would remount a share that is already up.
# -F because a share name is not a pattern: an unescaped `.` in one would
# alias a different volume.
_taildrive_mounted() {
  /sbin/mount | grep -qF " on ${1} "
}

# taildrive-mount [sharename...]: mount shares from $TAILDRIVE_SHARES at
# /Volumes/<sharename> — every share by default, only the named ones when
# arguments are given. A name that matches no share is an error and nothing
# is mounted. Idempotent — shares already mounted are left alone, and when
# every requested share is up it returns without probing the endpoint, so a
# reconnecting tailnet cannot fail a session that is already working. Bails
# early if the local Taildrive endpoint at 100.100.100.100:8080 is
# unreachable. Returns non-zero unless every requested share ends up mounted.
taildrive-mount() {
  local endpoint="100.100.100.100:8080"

  local shares names dupes
  shares=$(_taildrive_shares) || return 1
  names=$(printf '%s\n' "$shares" | sed 's|.*/||' | grep -v '^$')

  # Two hosts sharing a name collapse onto one mount point, where the second
  # reports the first's mount as its own.
  dupes=$(printf '%s\n' "$names" | sort | uniq -d | tr '\n' ' ')
  if [ -n "${dupes% }" ]; then
    echo "taildrive-mount: share names collide under /Volumes: ${dupes% }" >&2
    return 1
  fi

  local arg missing=""
  for arg in "$@"; do
    if [ -z "$arg" ] || ! printf '%s\n' "$names" | grep -qxF -- "$arg"; then
      missing="${missing} '${arg}'"
    fi
  done
  if [ -n "$missing" ]; then
    echo "taildrive-mount: not in TAILDRIVE_SHARES:${missing}" >&2
    return 1
  fi

  local share mp pending=""
  while IFS= read -r share; do
    [ -z "$share" ] && continue
    if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qxF -- "${share##*/}"; then
      continue
    fi
    mp=$(_taildrive_mountpoint "$share")
    if _taildrive_mounted "$mp"; then
      printf '  already mounted: %s\n' "$mp"
    else
      pending="${pending}${share}
"
    fi
  done <<<"$shares"
  [ -n "$pending" ] || return 0

  if ! curl -sS -m 3 -o /dev/null "http://${endpoint}/" 2>/dev/null; then
    echo "taildrive-mount: ${endpoint} unreachable; is tailscaled running?" >&2
    return 1
  fi

  local url out failed=0
  while IFS= read -r share; do
    [ -z "$share" ] && continue
    mp=$(_taildrive_mountpoint "$share")
    url="http://${endpoint}/${share}"
    # argv form keeps the URL out of the AppleScript source. A zero exit only
    # means Finder accepted the request: it mounts at /Volumes/<name>-1 when
    # the path is taken, so the mount point itself is the proof.
    if out=$(osascript -e 'on run argv' -e 'mount volume item 1 of argv' \
      -e 'end run' -- "$url" 2>&1) && _taildrive_mounted "$mp"; then
      printf '  mounted: %s\n' "$mp"
    else
      out=$(printf '%s' "$out" | head -1)
      printf '  FAILED: %s%s\n' "$mp" "${out:+ — $out}" >&2
      failed=$((failed + 1))
    fi
  done <<<"$pending"
  [ "$failed" -eq 0 ]
}

# taildrive-unmount: detach every Taildrive volume managed by taildrive-mount.
# Returns non-zero unless every mounted volume detached — diskutil refuses
# while a process holds a reference, and a session rooted at the share is
# exactly such a process.
taildrive-unmount() {
  local shares
  shares=$(_taildrive_shares) || return 1

  local share mp out failed=0
  while IFS= read -r share; do
    [ -z "$share" ] && continue
    mp=$(_taildrive_mountpoint "$share")
    _taildrive_mounted "$mp" || continue
    if out=$(diskutil unmount "$mp" 2>&1); then
      printf '  unmounted: %s\n' "$mp"
    else
      out=$(printf '%s' "$out" | head -1)
      printf '  FAILED: %s%s\n' "$mp" "${out:+ — $out}" >&2
      failed=$((failed + 1))
    fi
  done <<<"$shares"
  [ "$failed" -eq 0 ]
}
