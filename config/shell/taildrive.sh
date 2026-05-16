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
        echo "taildrive-mount: TAILDRIVE_SHARES env var not set; configure in ~/.secrets" >&2
        return 1
    fi
    printf '%s\n' "$TAILDRIVE_SHARES" | tr ',' '\n'
}

# taildrive-mount: mount every share in $TAILDRIVE_SHARES at /Volumes/<sharename>.
# Idempotent — skips shares already mounted. Bails early if the local Taildrive
# endpoint at 100.100.100.100:8080 is unreachable.
taildrive-mount() {
    local endpoint="100.100.100.100:8080"

    if ! curl -sS -m 3 -o /dev/null "http://${endpoint}/" 2>/dev/null; then
        echo "taildrive-mount: ${endpoint} unreachable; is tailscaled running?" >&2
        return 1
    fi

    local share name mp url
    while IFS= read -r share; do
        [ -z "$share" ] && continue
        name="${share##*/}"
        mp="/Volumes/${name}"
        if /sbin/mount | grep -q " on ${mp} "; then
            printf '  already mounted: %s\n' "$mp"
            continue
        fi
        url="http://${endpoint}/${share}"
        if osascript -e "mount volume \"${url}\"" >/dev/null 2>&1; then
            printf '  mounted: %s\n' "$mp"
        else
            printf '  FAILED: %s\n' "$mp" >&2
        fi
    done < <(_taildrive_shares)
}

# taildrive-unmount: detach every Taildrive volume managed by taildrive-mount.
taildrive-unmount() {
    local share name mp
    while IFS= read -r share; do
        [ -z "$share" ] && continue
        name="${share##*/}"
        mp="/Volumes/${name}"
        if /sbin/mount | grep -q " on ${mp} "; then
            diskutil unmount "$mp" 2>&1 | head -1
        fi
    done < <(_taildrive_shares)
}
