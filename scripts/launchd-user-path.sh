#!/usr/bin/env bash
# Compare the PATH launchd hands GUI applications and LaunchAgents with the
# value declared in config/launchd/user-path.
#
# launchd never reads the shell config chain. Without a configured user PATH,
# every process it starts gets /usr/bin:/bin:/usr/sbin:/sbin, where
# `#!/usr/bin/env bash` finds the system bash 3.2 instead of Homebrew's.
# `launchctl config user path` stores the value in the plist below, and launchd
# reads that plist only at boot.
#
# Usage: scripts/launchd-user-path.sh           report; exit 1 on drift
#        scripts/launchd-user-path.sh --apply   write the declared value (sudo)
#
# Exit codes: 0 in sync or not macOS, 1 drift, 2 usage error, 3 no declared value.
# Env:   LAUNCHD_USER_PLIST  launchd's user config plist (default below). The
#        bats suite points it at a sandbox file.

set -euo pipefail

EXIT_DRIFT=1
EXIT_USAGE=2
EXIT_CONFIG=3

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECLARED_FILE="$REPO_ROOT/config/launchd/user-path"
PLIST="${LAUNCHD_USER_PLIST:-/var/db/com.apple.xpc.launchd/config/user.plist}"

APPLY=false
case "$#:${1:-}" in
  0:) ;;
  1:--apply) APPLY=true ;;
  *)
    echo "usage: $0 [--apply]" >&2
    exit "$EXIT_USAGE"
    ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: the launchd user PATH is macOS-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

declared=""
if [ -r "$DECLARED_FILE" ]; then
  IFS= read -r declared <"$DECLARED_FILE" || true
fi
if [ -z "$declared" ]; then
  echo "ERROR: no PATH declared in $DECLARED_FILE" >&2
  exit "$EXIT_CONFIG"
fi

# The configured value, or nothing when the plist or its key is absent.
current_path() {
  [ -f "$PLIST" ] || return 0
  plutil -extract PathEnvironmentVariable raw "$PLIST" 2>/dev/null || true
}

# True when the plist changed after the last boot, so launchd has not read it.
pending_reboot() {
  local boot mtime
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  mtime=$(stat -f %m "$PLIST" 2>/dev/null) || return 1
  [ -n "$boot" ] && [ -n "$mtime" ] && [ "$mtime" -gt "$boot" ]
}

fix="sudo launchctl config user path $(printf '%q' "$declared")"
current=$(current_path)

if [ "$current" = "$declared" ]; then
  echo "launchd user PATH in sync: $declared"
  if pending_reboot; then
    echo "NOTE: set after the last boot; GUI apps and LaunchAgents get it at the next reboot."
  fi
  exit 0
fi

if [ "$APPLY" = false ]; then
  echo "WARNING: launchd user PATH differs from config/launchd/user-path" >&2
  echo "  declared: $declared" >&2
  echo "  current:  ${current:-<unset>}" >&2
  echo "  fix:      $fix" >&2
  echo "            (scripts/launchd-user-path.sh --apply runs it)" >&2
  echo "  launchd reads this only at boot, so reboot after the fix." >&2
  exit "$EXIT_DRIFT"
fi

echo "==> $fix"
sudo launchctl config user path "$declared"

current=$(current_path)
if [ "$current" != "$declared" ]; then
  echo "ERROR: $PLIST still reads ${current:-<unset>} after launchctl config" >&2
  exit "$EXIT_DRIFT"
fi
echo "launchd user PATH set: $declared"
echo "NOTE: reboot for GUI apps and LaunchAgents to get it; launchd reads it only at boot."
