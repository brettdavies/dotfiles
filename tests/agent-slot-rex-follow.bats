#!/usr/bin/env bats
# agent-slot-rex follow and the restores it and the server's push run: one loop per Rex server, a restore once a
# minute, one at once after a sleep or once the server answers again, an exit when Rex is gone, and a log line for each.
#
# Run: bats tests/agent-slot-rex-follow.bats

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

REX_SERVER='/Applications/Rex.app/Contents/MacOS/rex server run --listen unix:///tmp/rex.sock'

setup() {
  agent_slot_rex_setup
  export AGENT_SLOT_REX_TICK=0.2 AGENT_SLOT_REX_POLL_INTERVAL=3600 AGENT_SLOT_REX_WAKE_GAP=2
  printf '1 %s\n' "$REX_SERVER" >>"$STUBS/ps.txt"
  STATE=$AGENT_SLOT_REX_STATE_DIR
  FOLLOW_LOG=$STATE/follow.log
  LOOPS=()
}

teardown() {
  local pid
  for pid in "${LOOPS[@]}"; do kill -CONT "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
}

# eventually COMMAND...: retries the command for up to 10 s until it succeeds.
eventually() {
  local i
  for ((i = 0; i < 100; i++)); do
    "$@" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "never true: $*" >&2
  cat "$CALLS" "$FOLLOW_LOG" >&2 2>/dev/null || true
  return 1
}

# track PID...: processes teardown stops.
track() { LOOPS+=("$@"); }

# poll_every SECONDS: the follow loop's interval between polls.
poll_every() { export AGENT_SLOT_REX_POLL_INTERVAL=$1; }

holds_lock() { [[ $(cut -d' ' -f1 "$STATE/follow.pid" 2>/dev/null) == "$1" ]]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
count() { grep -cE "$1" "$CALLS" || true; }
at_least() { (($(count "$1") >= $2)); }
logged() { jaq -e -s "$1" "$FOLLOW_LOG" >/dev/null; }

# follow_bg: starts a loop in the background, as Rex does, and waits until it holds the follow lock; sets LOOP.
follow_bg() {
  "$AGENT_SLOT_REX" follow </dev/null >/dev/null 2>&1 3>&- &
  LOOP=$!
  track "$LOOP"
  eventually holds_lock "$LOOP"
}

# --- restore --by ------------------------------------------------------------------------------------------------------

@test "restore --by names what ran the pass in the reconcile log, with how long the pass took" {
  local by
  slots '[]'
  for by in push poll reconnect; do
    run "$AGENT_SLOT_REX" restore --by "$by" --output json
    [ "$status" -eq 0 ]
  done
  jaq -s -e '[.[].by] == ["push", "poll", "reconnect"] and all(.[]; .ok and (.ms | type == "number" and . >= 0))' \
    "$STATE/reconcile.log"
}

@test "restore --by takes only push, poll, or reconnect" {
  run --separate-stderr "$AGENT_SLOT_REX" restore --by sweep --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "--by sweep" and (.message | contains("--by push|poll|reconnect"))' \
    <<<"$stderr"
}

@test "a poll pass that changes nothing still logs its line, small enough for a day of passes in the first 1 MiB" {
  slots '[]'
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  jaq -e '.by == "poll" and .changed == false' "$STATE/reconcile.log"
  (($(wc -c <"$STATE/reconcile.log") * 1440 < 1048576))
}

@test "every server call names this Mac, so the server's push skips the Mac that is already reconciling" {
  export AGENT_SLOT_REX_CLIENT=testmac
  slots '[]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^ssh-stub .* AGENT_SLOT_REX_CLIENT=testmac ~/.local/bin/agent-slot list --output json$'
}

# --- follow -------------------------------------------------------------------------------------------------------------

@test "follow restores once each interval, as a poll" {
  poll_every 1
  follow_bg
  eventually at_least '^agent-slot-rex restore --by poll --output json$' 2
  logged 'any(.[]; .event == "start" and .interval == 1 and .pid > 0 and .rex_pid > 0)'
}

@test "a second follow under the same Rex server exits and leaves the first one running" {
  # One parent starts both loops, as one Rex server would.
  bash -c '"$1" follow & until [ -e "$2" ]; do sleep 0.1; done; "$1" follow; echo "$?" >"$3"; wait' _ \
    "$AGENT_SLOT_REX" "$STATE/follow.pid" "$T/second" </dev/null >/dev/null 2>&1 3>&- &
  track $!
  eventually test -s "$T/second"
  [ "$(cat "$T/second")" = 0 ]
  local first
  first=$(cut -d' ' -f1 "$STATE/follow.pid")
  track "$first"
  kill -0 "$first"
  logged "any(.[]; .event == \"already-following\" and .holder == $first)"
}

@test "a follow under a new Rex server takes over, and the loop of the old one exits" {
  bash -c '"$1" follow & wait' _ "$AGENT_SLOT_REX" </dev/null >/dev/null 2>&1 3>&- &
  track $!
  eventually test -e "$STATE/follow.pid"
  local old
  old=$(cut -d' ' -f1 "$STATE/follow.pid")
  track "$old"
  follow_bg
  [ "$LOOP" != "$old" ]
  eventually gone "$old"
  holds_lock "$LOOP"
  logged "any(.[]; .event == \"superseded\" and .pid == $old)"
}

@test "after the Mac sleeps, follow restores at once, as a reconnect" {
  follow_bg
  kill -STOP "$LOOP"
  sleep 3
  kill -CONT "$LOOP"
  eventually at_least '^agent-slot-rex restore --by reconnect --output json$' 1
  [ "$(count '^agent-slot-rex restore --by poll')" -eq 0 ]
  called '^ssh-stub-verb probe$'
  logged 'any(.[]; .event == "wake" and .gap_s >= 3)'
}

@test "after a server call fails, follow probes the server and restores as soon as it answers" {
  poll_every 1
  stub agent-slot-rex '
[ "$(grep -c "^agent-slot-rex restore" "$CALLS")" -gt 1 ] && exit 0
echo "{\"ok\":false,\"reason\":\"server-unreachable\"}" >&2
exit 1'
  ssh_answer probe 0 255 '' 'ssh: connect to host testserver port 22: Network is unreachable'
  follow_bg
  eventually at_least '^agent-slot-rex restore --by reconnect --output json$' 1
  local order
  order=$(grep -E '^(agent-slot-rex restore|ssh-stub-verb probe)' "$CALLS" | head -4 | paste -sd '|')
  [ "$order" = 'agent-slot-rex restore --by poll --output json|ssh-stub-verb probe|ssh-stub-verb probe|agent-slot-rex restore --by reconnect --output json' ]
  logged '[.[].event] | index("unreachable") < index("reachable")'
  logged 'any(.[]; .event == "reachable" and (.down_s | type == "number"))'
  [ -z "$(ls "$STATE/logs" 2>/dev/null)" ]
}

@test "follow exits once the Rex server it serves is gone, and gives up its lock" {
  follow_bg
  : >"$STUBS/ps.txt"
  eventually gone "$LOOP"
  [ ! -e "$STATE/follow.pid" ]
  logged 'any(.[]; .event == "rex-gone")'
}

@test "follow does nothing unless a Rex server started it" {
  printf '1 %s\n' '/Applications/Rex.app/Contents/MacOS/rex config check /tmp/init.lua' >"$STUBS/ps.txt"
  run timeout 10 "$AGENT_SLOT_REX" follow
  [ "$status" -eq 0 ]
  logged 'any(.[]; .event == "skipped" and (.parent | contains("rex config check")))'
  [ ! -e "$STATE/follow.pid" ]
  not_called '^agent-slot-rex '
}
