#!/bin/sh
# Starts a LaunchAgent's job with its output in ~/Library/Logs: stdout appends to the named log, and stderr to the same
# name with .error.log in place of its extension (brew-upgrade.jsonl and brew-upgrade.error.log). launchd never trims a
# log, so ahead of the run a log past 1 MiB is cut down to its last 1 MiB, dropping the partial line the cut leaves at
# the front so a JSON Lines log still parses line by line.
#
# Usage: launchd-run.sh <log-name> <command> [args...]    LAUNCHD_LOG_DIR overrides ~/Library/Logs

set -eu
name=$1
shift
logs="${LAUNCHD_LOG_DIR:-$HOME/Library/Logs}"
out="$logs/$name"
err="$logs/${name%.*}.error.log"
for log in "$out" "$err"; do
  if [ -f "$log" ] && [ "$(wc -c <"$log")" -gt 1048576 ]; then
    tail -c 1048576 "$log" | tail -n +2 >"$log.tmp" && mv -f "$log.tmp" "$log"
  fi
done
exec "$@" >>"$out" 2>>"$err"
