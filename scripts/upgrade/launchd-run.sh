#!/bin/sh
# Starts one upgrade job for its LaunchAgent: brew.sh appends its JSON Lines to ~/Library/Logs/brew-upgrade.jsonl and
# its stderr to brew-upgrade.error.log, and uv-tools.sh likewise under uv-tools-upgrade. launchd never rotates a log, so
# a log past 1 MiB moves to <log>.1, replacing the one before, ahead of the run.
#
# Usage: launchd-run.sh <brew.sh | uv-tools.sh>    UPGRADE_LOG_DIR overrides ~/Library/Logs, UPGRADE_PERL the perl

set -eu
script=$1
job=${script%.sh}-upgrade
logs="${UPGRADE_LOG_DIR:-$HOME/Library/Logs}"
for log in "$logs/$job.jsonl" "$logs/$job.error.log"; do
  if [ -f "$log" ] && [ "$(wc -c <"$log")" -gt 1048576 ]; then
    mv -f "$log" "$log.1"
  fi
done
# launchd sends SIGTERM to the job process alone, a terminal's Ctrl-C reaches a background job that ignores SIGINT,
# and bash runs a trap only once the command it is waiting on ends, so left alone the job would sit on brew and never
# write its run.end. perl starts the job in a process group of its own, and the wrapper turns either signal into a
# SIGTERM for that group: it ends the tool the job is waiting on, and reaches nothing outside the job wherever the
# wrapper itself runs. The wrapper then exits with the job's status.
perl=${UPGRADE_PERL:-perl}
if ! command -v "$perl" >/dev/null 2>&1; then
  {
    echo "launchd-run: perl not found; it starts the job in its own process group so a stop reaches it"
    echo "             install with: brew install perl"
  } >>"$logs/$job.error.log"
  exit 3
fi
# shellcheck disable=SC2016 # the $ARGV and $! in single quotes are perl's
"$perl" -e 'setpgrp; exec @ARGV or die "launchd-run: exec $ARGV[0]: $!\n"' "$(dirname "$0")/$script" \
  >>"$logs/$job.jsonl" 2>>"$logs/$job.error.log" &
pid=$!
trap 'trap "" INT TERM; kill -TERM "-$pid"' INT TERM
status=0
wait "$pid" || status=$?
while kill -0 "$pid" 2>/dev/null; do
  status=0
  wait "$pid" || status=$?
done
exit "$status"
