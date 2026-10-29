# shellcheck shell=bash
# Background processes a test starts, and the guard that fails a test which leaves one running. A leaked process keeps
# the working directory bats ran from, so a run inside an agent slot leaves the slot held against teardown, by a process
# whose temp directory is already gone.
#
# A suite that starts a background process starts it with spawn and ends its teardown with stop_spawned, then
# assert_no_leaks. spawn needs util-linux's setsid, so only a Linux-only suite uses it; without /proc, the guard passes.

# Usage: spawn <command> [args...]; starts the command in the background in a session of its own, so stop_spawned
# stops it with every process it starts, however deep and whichever parent each ends up with. $! is its pid, which is
# also its session and process group id once setsid has run.
spawn() {
  setsid "$@" &
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

# Usage: leaked_processes; prints "<pid> <command>" for each live process this test started. bats exports
# BATS_TEST_TMPDIR to every command a test runs, and the environment /proc shows is the one a process was started with,
# so bats's own processes lack it. grep runs without the variable and reads its value from stdin, so it never matches
# itself.
leaked_processes() {
  local file pid marker="BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR"
  [ -d /proc/self ] || return 0
  for file in $(env -u BATS_TEST_TMPDIR grep -lsazxF -f - /proc/[0-9]*/environ <<<"$marker"); do
    pid=${file#/proc/}
    pid=${pid%%/*}
    printf '%s %s\n' "$pid" "$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | cut -c1-160)"
  done
}

# Usage: assert_no_leaks; last in teardown. Gives what the test stopped up to 3 s to exit, then kills whatever is left,
# names it, and fails the test.
assert_no_leaks() {
  local left pid _ i
  for ((i = 0; i < 30; i++)); do
    left=$(leaked_processes)
    [ -n "$left" ] || return 0
    sleep 0.1
  done
  while read -r pid _; do kill -KILL "$pid" 2>/dev/null || true; done <<<"$left"
  printf 'processes this test started were still running after teardown, and were killed:\n%s\n' "$left" >&2
  return 1
}
