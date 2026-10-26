#!/usr/bin/env bash
# Warns when macOS fseventsd has grown far past the memory budget launchd gives it. After a flood of file events the
# daemon can hold gigabytes it never gives back, keep a core busy for days, and stall every FSEvents client that
# registers, Claude Code's startup included, until it is restarted
# (https://github.com/anthropics/claude-code/issues/98769).
#
# The warning starts at ten times the daemon's jetsam budget (30 MB on macOS 26 and 27), measured as resident memory:
# its footprint needs root and `top` takes most of a second, both too slow or too privileged for a check that runs at
# every Claude Code session start. A healthy daemon's resident memory, shared library pages included, stays in the
# single digits to low tens of megabytes; a runaway one passes a gigabyte within hours. When launchctl does not report
# the budget, the check assumes 30 MB.
#
# Usage: fseventsd-check.sh [--claude-hook]
#   Prints nothing and exits 0 when fseventsd is within bounds, is not running, or the host is not macOS. Otherwise it
#   prints one WARNING: line on stderr and exits 1, or with --claude-hook prints that line as Claude Code SessionStart
#   hook JSON on stdout: systemMessage shows it to the user, additionalContext gives it to Claude.

set -euo pipefail

hook=false
case "${1-}" in
  '') ;;
  --claude-hook) hook=true ;;
  *)
    echo "ERROR: unknown argument: $1 (usage: fseventsd-check.sh [--claude-hook])" >&2
    exit 2
    ;;
esac

[ "$(uname -s)" = Darwin ] || exit 0

pid=$(pgrep -x fseventsd | head -n 1) || true
[ -n "$pid" ] || exit 0
rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ') || true
[ -n "$rss_kb" ] || exit 0

budget_mb=$(launchctl print system/com.apple.fseventsd 2>/dev/null \
  | sed -n 's/.*jetsam memory limit (active[^=]*= *\([0-9][0-9]*\) MB.*/\1/p' | head -n 1) || true
budget_mb=${budget_mb:-30}

[ "$rss_kb" -gt $((budget_mb * 1024 * 10)) ] || exit 0

warning="WARNING: fseventsd holds $((rss_kb / 1024)) MB against its $budget_mb MB launchd budget; reset it with: sudo killall fseventsd"
if $hook; then
  # Exit 0 is the code Claude Code documents for hook JSON output. The warning holds no quote or backslash to escape.
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$warning" "$warning"
  exit 0
fi
echo "$warning" >&2
exit 1
