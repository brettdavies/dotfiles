#!/usr/bin/env bats
# Tests for scripts/tmux/prune-orphans.sh, which SIGKILLs tmux clients whose
# terminal is gone. It runs from tmux's client-detached hook and from the
# tmux-prune-orphans systemd user timer.
#
# Run: bats tests/tmux-prune-orphans.bats
#
# `tmux` is a stub selected through TMUX_BIN, and `logger` a stub on a
# PATH-prepended directory, so nothing reaches a real tmux server or syslog.
# The clients the stub reports are real `sleep` processes started by the test,
# because the script signals them with the `kill` builtin.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/tmux/prune-orphans.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS"
  : >"$CALLS"
  export TMUX_BIN="$STUBS/tmux"
  export HELD="$BATS_TEST_TMPDIR/held.pids"
  export TMUX_PRUNE_TIMEOUT=1
  stub logger 'log logger "$@"'
  PATH="$STUBS:$PATH"
  SLEEPERS=()
}

teardown() {
  local pid
  [ -f "$HELD" ] && mapfile -t -O "${#SLEEPERS[@]}" SLEEPERS <"$HELD"
  for pid in "${SLEEPERS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# stub NAME BODY: an executable NAME whose body can call `log`.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
log() { printf '%s\n' "\$*" >>"\$CALLS"; }
$2
EOF
  chmod +x "$STUBS/$1"
}

# sleeper: start a stand-in client process and record its pid in SLEEPER. It
# is detached from the test shell, so its death is not reported as a job.
sleeper() {
  SLEEPER=$(sleep 60 >/dev/null 2>&1 3>&- & echo $!)
  SLEEPERS+=("$SLEEPER")
}

# A tmux client passes its stdin and stdout to the server over the socket. A
# wedged server never reads that message, so the passed descriptors stay open
# after the client is killed. The stub's background sleep holds its stdout the
# same way, from its own process group so that timeout's signal to the
# client's group does not reach it.
@test "a tmux server that never answers fails the prune within its timeout instead of hanging" {
  stub tmux 'exec 3>&-
perl -e "setpgrp; exec @ARGV" sleep 60 &
echo $! >>"$HELD"
exec sleep 60'

  run -1 timeout 10 "$SCRIPT"

  [[ "$output" == *"ERROR: tmux server did not answer list-clients within 1s"* ]]
}

@test "a tmux client that ignores SIGTERM is killed after the grace period and the prune still fails" {
  stub tmux 'exec 3>&-
trap "" TERM
exec sleep 60'

  run -1 timeout 20 "$SCRIPT"

  [[ "$output" == *"ERROR: tmux server did not answer list-clients within 1s"* ]]
}

@test "no tmux server running is a clean exit" {
  stub tmux 'echo "no server running on /tmp/tmux-1000/default" >&2; exit 1'

  run -0 "$SCRIPT"

  [ -z "$output" ]
  [ ! -s "$CALLS" ]
}

@test "a client whose tty is (none) is killed and an attached client is left alone" {
  sleeper
  local orphan=$SLEEPER
  sleeper
  local attached=$SLEEPER
  stub tmux "printf '%s\n' '$orphan (none)' '$attached /dev/pts/3'"

  run -0 "$SCRIPT"

  for _ in $(seq 50); do
    kill -0 "$orphan" 2>/dev/null || break
    sleep 0.1
  done
  run ! kill -0 "$orphan"
  kill -0 "$attached"
  grep -qx "logger -t tmux-prune killing orphan client pid=$orphan" "$CALLS"
}
