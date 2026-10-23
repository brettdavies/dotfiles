#!/bin/sh
# Starts a LaunchAgent's job with its output in ~/Library/Logs: stdout appends to the named log, and stderr to the same
# name with .error.log in place of its extension (brew-upgrade.jsonl and brew-upgrade.error.log). launchd never rotates
# a log, so a log past 1 MiB moves to <log>.1, replacing the one before, ahead of the run.
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
    mv -f "$log" "$log.1"
  fi
done
exec "$@" >>"$out" 2>>"$err"
