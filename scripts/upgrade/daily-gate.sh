#!/usr/bin/env bash
# Runs a scheduled job at most once a day on a Mac that sleeps through its schedule. launchd fires the job every hour,
# and a fire runs it only when it has not succeeded in the last 20 hours and the network answers: a dark wake hands the
# job a few seconds with no network, which otherwise ends the day's run in a DNS or ssh failure. A skipped fire prints
# nothing, so the job's run log holds only real runs, except that an offline fire with no success in the last 48 hours
# warns on stderr: a network check that never passes would otherwise stop the upgrades with both logs empty. A success
# is recorded only when the job exits 0.
#
# Usage: daily-gate.sh <job> <command> [args...]    UPGRADE_STATE_DIR overrides ${XDG_STATE_HOME:-~/.local/state}/dotfiles

set -euo pipefail
job=$1
shift
state="${UPGRADE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles}"
stamp="$state/$job.last-success"

if [ -n "$(find "$stamp" -mmin -1200 2>/dev/null)" ]; then
  exit 0
fi
# The URL macOS itself uses to test for a working connection.
if ! curl -fsS --max-time 10 -o /dev/null https://www.apple.com/library/test/success.html 2>/dev/null; then
  if [ -z "$(find "$stamp" -mmin -2880 2>/dev/null)" ]; then
    echo "WARNING: $job: skipped because the network check failed, and the job has not succeeded in 48 hours" >&2
  fi
  exit 0
fi

"$@"
mkdir -p "$state"
touch "$stamp"
