# shellcheck shell=bash
# Background processes a test starts, and the guard that fails a test which leaves one running. A leaked process keeps
# the working directory bats ran from, so a run inside an agent slot leaves the slot held against teardown, by a process
# whose temp directory is already gone.
#
# A suite that starts a background process starts it with spawn and ends its teardown with stop_spawned, then
# assert_no_leaks. Without /proc, the guard passes. scripts/run-tests sources this file for the same scan over each
# whole suite.

# Usage: spawn <command> [args...]; starts the command in the background in a session of its own, so stop_spawned
# stops it with every process it starts, however deep and whichever parent each ends up with. $! is its pid, which is
# also its session and process group id once setsid has run. perl makes the setsid call, because macOS has no setsid
# command; a background child of a shell without job control never leads a process group, so the call succeeds.
spawn() {
  # shellcheck disable=SC2016 # the $! and @ARGV in single quotes are perl's
  perl -MPOSIX -e 'defined POSIX::setsid() or die "spawn: setsid: $!\n";
    exec { $ARGV[0] } @ARGV or die "spawn: $ARGV[0]: $!\n"' -- "$@" &
  SPAWNED+=("$!")
}

# Usage: stop_spawned; kills each spawned process's group. Before setsid runs, the group does not exist yet and the
# process has started nothing, so killing its pid is enough. The wait reaps it, so bash prints no "Killed" for the job.
stop_spawned() {
  local pid
  for pid in "${SPAWNED[@]}"; do
    kill -KILL -- "-$pid" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

# Usage: processes_with <NAME=value>; prints "<pid> <command>" for each live process whose environment holds exactly
# that entry. The environment /proc shows is the one a process was started with, so a process that only set the
# variable in its own shell lacks it. grep runs without the variable and reads the entry from stdin, so it never matches
# itself.
processes_with() {
  local file pid
  [ -d /proc/self ] || return 0
  for file in $(env -u "${1%%=*}" grep -lsazxF -f - /proc/[0-9]*/environ <<<"$1"); do
    pid=${file#/proc/}
    pid=${pid%%/*}
    printf '%s %s\n' "$pid" "$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | cut -c1-160)"
  done
}

# Usage: stop_leaks <NAME=value> <who> <when>; gives each process whose environment holds the entry up to 3 s to exit,
# then kills whatever is left, lists it under "processes WHO started were still running after WHEN, and were killed:"
# on stderr, and fails.
stop_leaks() {
  local left pid _ i
  for ((i = 0; i < 30; i++)); do
    left=$(processes_with "$1")
    [ -n "$left" ] || return 0
    sleep 0.1
  done
  while read -r pid _; do kill -KILL "$pid" 2>/dev/null || true; done <<<"$left"
  printf 'processes %s started were still running after %s, and were killed:\n%s\n' "$2" "$3" "$left" >&2
  return 1
}

# Usage: assert_no_leaks; last in teardown. bats exports BATS_TEST_TMPDIR to every command a test runs, and bats's own
# processes were started before it was set, so the processes that carry it are the ones this test started.
assert_no_leaks() {
  stop_leaks "BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR" "this test" teardown
}
