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
run="$(dirname "$0")/$script"

# Run by hand from a terminal, the job stays in the foreground: the terminal delivers Ctrl-C to it and its tools, and a
# password prompt can read the terminal.
if [ -t 0 ]; then
  exec "$run" >>"$logs/$job.jsonl" 2>>"$logs/$job.error.log"
fi

# Under launchd there is no terminal. launchd sends SIGTERM to the job process alone, and bash runs a trap only once the
# command it is waiting on ends, so left alone the job would sit on brew and never write its run.end. perl starts the
# job in a process group of its own, and a stop becomes a SIGTERM, plus a SIGCONT in case the job is stopped, for that
# group: it ends the tool the job is waiting on and reaches nothing outside the job. launchd's own cleanup would miss
# this group, so once the job has exited the wrapper kills whatever of it is left, such as a tool that ignores SIGTERM,
# and a job still running 10 seconds after the stop is killed ahead of launchd's SIGKILL at 20 (ExitTimeOut).
perl=${UPGRADE_PERL:-perl}
if ! command -v "$perl" >/dev/null 2>&1; then
  echo "launchd-run: perl not found, so a stop reaches the job but not the tool it is running;" \
    "install with: brew install perl" >>"$logs/$job.error.log"
  exec "$run" >>"$logs/$job.jsonl" 2>>"$logs/$job.error.log"
fi
# shellcheck disable=SC2016 # the $ARGV and $! in single quotes are perl's
"$perl" -e 'setpgrp; exec { $ARGV[0] } @ARGV or die "launchd-run: exec $ARGV[0]: $!\n"' "$run" \
  >>"$logs/$job.jsonl" 2>>"$logs/$job.error.log" &
pid=$!
killer=''
# shellcheck disable=SC2329 # the INT and TERM trap calls it
stop() {
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || :
  kill -CONT "-$pid" 2>/dev/null || :
  {
    sleep 10
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || :
  } &
  killer=$!
}
trap 'trap "" INT TERM; stop' INT TERM
status=0
wait "$pid" || status=$?
while kill -0 "$pid" 2>/dev/null; do
  status=0
  wait "$pid" || status=$?
done
if [ -n "$killer" ]; then
  kill "$killer" 2>/dev/null || :
  kill -KILL "-$pid" 2>/dev/null || :
fi
exit "$status"
