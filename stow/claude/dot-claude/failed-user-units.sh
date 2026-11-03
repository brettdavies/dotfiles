#!/usr/bin/env bash
# Claude Code SessionStart hook: names the failed systemd user units in one JSON object, whose systemMessage shows under
# the startup banner and whose additionalContext reaches Claude. A oneshot job that fails stays failed until its next run
# succeeds, so a stalled scheduled job, such as vault-agent-sync-check on a stalled NAS mirror, shows at the start of
# every session on the host. Prints nothing when no unit has failed or there is no user manager to ask (macOS has no
# systemctl). Every path exits 0, so the hook never blocks or fails a session start.

command -v systemctl >/dev/null 2>&1 || exit 0

# Claude Code's environment can lack XDG_RUNTIME_DIR, and without it systemctl --user cannot find the user bus. A user
# manager that does not answer within 2 s is treated as having nothing to report.
listing=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID} \
  timeout 2 systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null) || exit 0

units=''
while read -r unit _; do
  [ -n "$unit" ] && units+="${units:+, }$unit"
done <<<"$listing"
[ -n "$units" ] || exit 0

# A unit name may hold a backslash (systemd's \x2d escapes) but never a quote or a control character.
message="WARNING: failed systemd user units: $units; inspect with: systemctl --user status <unit>"
message=${message//\\/\\\\}
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$message" "$message"
exit 0
