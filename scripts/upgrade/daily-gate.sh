#!/usr/bin/env bash
# Runs a scheduled job at most once a day on a Mac that sleeps through its schedule. launchd fires the job every hour,
# and a fire runs it only when it has not succeeded in the last 20 hours and the network answers: a dark wake hands the
# job a few seconds with no network, which otherwise ends the day's run in a DNS or ssh failure. A skipped fire prints
# nothing, so the job's run log holds only real runs. A success is recorded only when the job exits 0.
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
curl -fsS --max-time 10 -o /dev/null https://www.apple.com/library/test/success.html 2>/dev/null || exit 0

"$@"
mkdir -p "$state"
touch "$stamp"
