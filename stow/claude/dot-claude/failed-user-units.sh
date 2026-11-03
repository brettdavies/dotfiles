#!/usr/bin/env bash
# Prints the failed systemd user units as a session-context section, or nothing when none has failed or there is no
# user manager to ask. A oneshot job that fails stays failed until its next run succeeds, so a stalled scheduled job,
# such as vault-agent-sync-check on a stalled NAS mirror, shows at the start of every Claude session on the host.

command -v systemctl >/dev/null 2>&1 || exit 0
# Claude Code's environment can lack XDG_RUNTIME_DIR, and without it systemctl --user cannot find the user bus.
units=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} \
  systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null | awk '{ print $1 }')
[ -n "$units" ] || exit 0
echo ''
echo '--- Failed systemd user units (systemctl --user status <unit>) ---'
printf '%s\n' "$units" | paste -sd, - | sed 's/,/, /g'
