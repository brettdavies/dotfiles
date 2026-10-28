#!/usr/bin/env bats
# agent-slot's push to the Rex clients: after a launch makes a slot, and after a sweep or finish tears one down, each Mac
# in AGENT_SLOT_REX_CLIENTS is asked over ssh to restore its tabs. The push runs in the background, never changes the
# verb's result, skips the Mac whose helper started the verb, and logs one line per client.
#
# Run: bats tests/agent-slot-push.bats

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  clients 'maca macb'
  PUSH_LOG=$AGENT_SLOT_STATE_DIR/push.log
  # The Mac's shell expands the tilde.
  # shellcheck disable=SC2088
  REMOTE='~/.local/bin/agent-slot-rex restore --by push --output json'
}

# pushed N: waits up to 10 s for the push log to hold N lines.
pushed() {
  local i
  for ((i = 0; i < 100; i++)); do
    (($(cat "$PUSH_LOG" 2>/dev/null | wc -l) >= $1)) && return 0
    sleep 0.1
  done
  echo "the push log holds fewer than $1 lines:" >&2
  cat "$PUSH_LOG" >&2 2>/dev/null || true
  return 1
}

# clients NAMES [TIMEOUT]: the Rex clients a push reaches, and the seconds one push may take.
clients() {
  export AGENT_SLOT_REX_CLIENTS=$1
  [[ -z ${2:-} ]] || export AGENT_SLOT_PUSH_TIMEOUT=$2
}

# ssh_host HOST RC [STDERR]: how ssh to HOST ends.
ssh_host() {
  printf '%s\n' "$2" >"$STUBS/ssh-$1.rc"
  [[ -z ${3:-} ]] || printf '%s\n' "$3" >"$STUBS/ssh-$1.err"
}

launch_repoa() {
  prime repoa
  trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-push --output json
}

@test "a launch that makes a slot asks every Rex client to restore, and logs each push" {
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 2
  jaq -e '.key == "repoa/1" and (.next_step.note | contains("asked to open"))' <<<"$output"
  grep -qxF "ssh -n -o BatchMode=yes -o ConnectTimeout=5 maca $REMOTE" "$CALLS"
  grep -qxF "ssh -n -o BatchMode=yes -o ConnectTimeout=5 macb $REMOTE" "$CALLS"
  jaq -s -e '(map(.client) | sort) == ["maca", "macb"]
    and all(.[]; .verb == "launch" and .keys == ["repoa/1"] and .result == "restored" and .exit == 0
      and (.ms | type == "number") and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))' "$PUSH_LOG"
}

@test "a launch returns without waiting on a client that does not answer, and its push is logged once it ends" {
  clients 'maca asleep down' 30
  touch "$STUBS/ssh-asleep.hold"
  ssh_host down 255 'ssh: connect to host down port 22: Operation timed out'
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 2
  run ! grep -q '"client":"asleep"' "$PUSH_LOG"
  rm "$STUBS/ssh-asleep.hold"
  pushed 3
  jaq -s -e 'map({(.client): .}) | add
    | .maca.result == "restored" and .asleep.result == "restored"
      and .down.result == "unreachable" and .down.exit == 255
      and .down.detail == "ssh: connect to host down port 22: Operation timed out"' "$PUSH_LOG"
}

@test "a push that outlives its bound is logged as timed out" {
  clients asleep 1
  touch "$STUBS/ssh-asleep.hold"
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  jaq -e '.client == "asleep" and .result == "timed-out" and .exit == 124' "$PUSH_LOG"
}

@test "a client that is reached but whose restore fails is logged with the restore's exit and its last line" {
  ssh_host macb 1 $'agent-slot-rex: rex-failed: rex ls exited 1\n{"ok":false,"reason":"rex-failed"}'
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 2
  jaq -s -e 'map({(.client): .}) | add | .maca.result == "restored"
    and .macb.result == "restore-failed" and .macb.exit == 1 and .macb.detail == "{\"ok\":false,\"reason\":\"rex-failed\"}"' \
    "$PUSH_LOG"
}

@test "a verb the Mac helper started pushes to every client but that Mac, and logs the skip" {
  AGENT_SLOT_REX_CLIENT=maca launch_repoa
  [ "$status" -eq 0 ]
  pushed 2
  run ! grep -q ' maca ' "$CALLS"
  grep -qxF "ssh -n -o BatchMode=yes -o ConnectTimeout=5 macb $REMOTE" "$CALLS"
  jaq -s -e 'map({(.client): .}) | add | .maca.result == "skipped" and .maca.exit == null
    and .macb.result == "restored"' "$PUSH_LOG"
}

@test "with no Rex client configured, a launch pushes nothing" {
  clients ''
  launch_repoa
  [ "$status" -eq 0 ]
  sleep 1
  run ! grep -q '^ssh ' "$CALLS"
  [ ! -e "$PUSH_LOG" ]
}

@test "a launch that returns the slot an earlier try made pushes nothing again" {
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 2
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-push --output json
  [ "$status" -eq 0 ]
  jaq -e '.created == false' <<<"$output"
  sleep 1
  [ "$(wc -l <"$PUSH_LOG")" -eq 2 ]
}

@test "a sweep that tears a slot down pushes, naming the slot" {
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  pushed 2
  jaq -s -e 'all(.[]; .verb == "sweep" and .keys == ["repoa/1"] and .result == "restored")' "$PUSH_LOG"
}

@test "a finish that tears a slot down pushes, naming the slot" {
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  finished_task
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true' <<<"$output"
  pushed 2
  jaq -s -e 'all(.[]; .verb == "finish" and .keys == ["repoa/1"] and .result == "restored")' "$PUSH_LOG"
}

@test "a sweep or finish that tears nothing down pushes nothing" {
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == []' <<<"$output"
  finished_task
  run --separate-stderr "$AGENT_SLOT" sweep --output json
  [ "$status" -eq 0 ]
  jaq -e '.would_tear_down == ["repoa/1"]' <<<"$output"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --output json
  [ "$status" -eq 0 ]
  sleep 1
  run ! grep -q '^ssh ' "$CALLS"
  [ ! -e "$PUSH_LOG" ]
}

@test "past 1 MiB the push log moves to push.log.1, replacing the one before" {
  mkdir -p "$AGENT_SLOT_STATE_DIR"
  echo older >"$PUSH_LOG.1"
  head -c 1100000 /dev/zero | tr '\0' x >"$PUSH_LOG"
  clients maca
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  [ "$(wc -c <"$PUSH_LOG.1")" -eq 1100000 ]
  jaq -e '.client == "maca"' "$PUSH_LOG"
}
