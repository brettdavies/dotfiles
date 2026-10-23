#!/bin/sh
# Starts one upgrade job for its LaunchAgent: brew.sh appends its JSON Lines to ~/Library/Logs/brew-upgrade.jsonl and
# its stderr to brew-upgrade.error.log, and uv-tools.sh likewise under uv-tools-upgrade. launchd never rotates a log, so
# a log past 1 MiB moves to <log>.1, replacing the one before, ahead of the run.
#
# Usage: launchd-run.sh <brew.sh | uv-tools.sh>    UPGRADE_LOG_DIR overrides ~/Library/Logs

set -eu
script=$1
job=${script%.sh}-upgrade
logs="${UPGRADE_LOG_DIR:-$HOME/Library/Logs}"
for log in "$logs/$job.jsonl" "$logs/$job.error.log"; do
  if [ -f "$log" ] && [ "$(wc -c <"$log")" -gt 1048576 ]; then
    mv -f "$log" "$log.1"
  fi
done
# launchd sends SIGTERM to the job process alone, and bash runs a trap only once the command it is waiting on ends, so
# the job would sit on brew until launchd's SIGKILL and never write its run.end. The wrapper stays the job and passes
# the signal to its whole process group, which ends that command too; it then exits with the job's status.
"$(dirname "$0")/$script" >>"$logs/$job.jsonl" 2>>"$logs/$job.error.log" &
pid=$!
trap 'trap "" TERM; kill -TERM 0' TERM
status=0
wait "$pid" || status=$?
while kill -0 "$pid" 2>/dev/null; do
  status=0
  wait "$pid" || status=$?
done
exit "$status"
