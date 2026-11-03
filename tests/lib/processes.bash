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

# Usage: processes_with <NAME=value> [<test pid>]; prints "<pid> <command>" for each live process whose environment
# holds exactly that entry, other than the timeout watchdog of the bats test running as <test pid>. The environment /proc
# shows is the one a process was started with, so a process that only set the variable in its own shell lacks it. grep
# runs without the variable and reads the entry from stdin, so it never matches itself.
processes_with() {
  local file pid cmd
  [ -d /proc/self ] || return 0
  for file in $(env -u "${1%%=*}" grep -lsazxF -f - /proc/[0-9]*/environ <<<"$1"); do
    pid=${file#/proc/}
    pid=${pid%%/*}
    cmd=$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | cut -c1-160)
    [ -z "${2:-}" ] || ! is_timeout_watchdog "$pid" "$cmd" "$2" || continue
    printf '%s %s\n' "$pid" "$cmd"
  done
}

# Usage: is_timeout_watchdog <pid> <command> <test pid>; true when the process is the `sleep $BATS_TEST_TIMEOUT` with
# which bats times out the test running as <test pid>. bats runs that sleep from a subshell of the test process, starts
# it after exporting BATS_TEST_TMPDIR and before setup, and stops it after teardown. The subshell can exec the sleep
# after the guard starts looking, so each scan checks again.
is_timeout_watchdog() {
  [ -n "${BATS_TEST_TIMEOUT:-}" ] && [ "$2" = "sleep $BATS_TEST_TIMEOUT " ] &&
    [ "$(parent_of "$(parent_of "$1")")" = "$3" ]
}

# Usage: parent_of <pid>; prints the parent pid of a live process, and nothing for one that is gone.
parent_of() {
  local stat _ ppid
  read -r stat 2>/dev/null <"/proc/$1/stat" || return 0
  read -r _ ppid _ <<<"${stat##*) }"
  printf '%s\n' "$ppid"
}

# Usage: stop_leaks <NAME=value> <who> <when> [<test pid>]; gives each process whose environment holds the entry, other
# than the timeout watchdog of <test pid>, at least 3 s of wall clock to exit, then kills whatever is left, lists it
# under "processes WHO started were still running after WHEN, and were killed:" on stderr, and fails. The deadline is
# wall clock because a scan reads every process's environment, which takes longest on a loaded host, where a count of
# scans could outlast a leak that exits on its own.
stop_leaks() {
  local left pid _ deadline=$((SECONDS + 4))
  while left=$(processes_with "$1" "${4:-}"); [ -n "$left" ] && ((SECONDS < deadline)); do
    sleep 0.1
  done
  [ -n "$left" ] || return 0
  while read -r pid _; do kill -KILL "$pid" 2>/dev/null || true; done <<<"$left"
  printf 'processes %s started were still running after %s, and were killed:\n%s\n' "$2" "$3" "$left" >&2
  return 1
}

# bats 1.14 keeps the pid of the watchdog that enforces BATS_TEST_TIMEOUT in a local of the function that runs the test.
# A test that fails by errexit has left that function by the time bats stops the watchdog, so bats kills no pid and the
# watchdog runs out the limit: it holds the run's output open until then, and then sends SIGTERM to the test's pid,
# which another process may hold by that time (https://github.com/bats-core/bats-core/issues/1206). The lookup falls
# back to a global of the same name, so a bats given BATS_killer_pid=$BATS_WATCHDOG_JOB in its environment stops the
# watchdog by its job. While a test runs, the name holds that test's watchdog pid, and every process the test starts
# inherits it, so a test that starts bats passes the job spec again.
# shellcheck disable=SC2034 # read by scripts/run-tests and by suites that start bats
BATS_WATCHDOG_JOB='%?bats_kill_processes_of'

# Usage: assert_no_leaks; last in teardown. bats exports BATS_TEST_TMPDIR to every command a test runs, and bats's own
# processes were started before it was set, so the processes that carry it are the ones this test started, all but the
# timeout watchdog's sleep. Teardown runs in the test process, so $$ names it.
assert_no_leaks() {
  stop_leaks "BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR" "this test" teardown "$$"
}
