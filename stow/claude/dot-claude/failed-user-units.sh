#!/usr/bin/env bash
# Claude Code SessionStart hook: names the failed systemd user units, each with its own status text when it set one, in
# one JSON object, whose systemMessage shows under the startup banner and whose additionalContext reaches Claude. A oneshot job that fails stays failed until its next run
# succeeds, so a stalled scheduled job, such as vault-agent-sync-check on a stalled NAS mirror, shows at the start of
# every session on the host. Prints nothing when no unit has failed or there is no user manager to ask (macOS has no
# systemctl). Every path exits 0, so the hook never blocks or fails a session start.

command -v systemctl >/dev/null 2>&1 || exit 0

# Claude Code's environment can lack XDG_RUNTIME_DIR, and without it systemctl --user cannot find the user bus. A user
# manager that does not answer within 2 s is treated as having nothing to report.
listing=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID} \
  timeout 2 systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null) || exit 0

units=()
while read -r unit _; do
  [ -n "$unit" ] && units+=("$unit")
done <<<"$listing"
[ "${#units[@]}" -gt 0 ] || exit 0

# A unit can say why it failed in its status text (systemd-notify --status), which follows its name. `show` prints one
# block per unit, in the order asked, with an empty line between blocks and none after the last, so the read adds one;
# a block whose Id is not the unit asked for gives its unit no status text.
shown=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID} \
  timeout 2 systemctl --user show -p Id -p StatusText "${units[@]}" 2>/dev/null) || shown=''
names='' i=0 id='' text=''
while IFS= read -r line; do
  case $line in
    Id=*) id=${line#Id=} ;;
    StatusText=*) text=${line#StatusText=} ;;
    '')
      if [ "$i" -lt "${#units[@]}" ]; then
        unit=${units[$i]}
        [ "$id" = "$unit" ] || text=''
        names+="${names:+, }$unit${text:+ ($text)}"
      fi
      i=$((i + 1)) id='' text=''
      ;;
  esac
done <<<"$shown"$'\n'
for (( ; i < ${#units[@]}; i++)); do
  names+="${names:+, }${units[$i]}"
done

# A unit name may hold a backslash (systemd's \x2d escapes); a status text may also hold quotes or control characters.
message="WARNING: failed systemd user units: $names; inspect with: systemctl --user status <unit>"
message=${message//[[:cntrl:]]/}
message=${message//\\/\\\\}
message=${message//\"/\\\"}
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$message" "$message"
exit 0
