#!/usr/bin/env bats
# agent-slot-rex's reconcile triggers on the Linux server, against stubbed rex, agent-slot, and rexurrect: the gate every
# pass but the start-up step goes through (a Rex server that answers, a start-up record for its instance, and the
# reconcile lock), the outcomes a timer or push pass logs and a restore asked for by hand reports as errors, and the
# start-up step that runs rexurrect once per server instance before the first tab change.
#
# Run: bats tests/agent-slot-rex-startup.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex
load lib/processes

setup() {
  agent_slot_rex_setup
  LOG=$AGENT_SLOT_REX_STATE_DIR/reconcile.log
  RECORD=$AGENT_SLOT_REX_STATE_DIR/startup.json
  LOCK=$AGENT_SLOT_REX_STATE_DIR/reconcile.lock
  # rexurrect logs the reconcile lock's holder as it runs, so a test can tell it ran under the lock.
  stub rexurrect 'printf "rexurrect-lock %s\n" "$(readlink "$AGENT_SLOT_REX_STATE_DIR/reconcile.lock" 2>/dev/null)" \
>>"$CALLS"'
  slots '[{"repo": "A", "slot": 1}]'
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# young: the running Rex server started just now, inside the start-up step's time limit.
young() {
  REX_STUB_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  export REX_STUB_STARTED
}

# recorded INSTANCE OUTCOME: the start-up record names that instance and rexurrect's outcome there.
recorded() {
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR"
  jaq -n -c --arg i "$1" --arg r "$2" '{instance: $i, rexurrect: $r, at: "2026-11-02T00:00:00Z"}' >"$RECORD"
}

# started_by_rex: the start-up step's parent is a Rex server, as ps reports it.
started_by_rex() { printf '1 /usr/bin/rex server run\n' >>"$STUBS/ps.txt"; }

# hold_lock: a stand-in agent-slot-rex holds the reconcile lock until teardown; HOLDER is its pid.
hold_lock() {
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR" "$T/holder"
  printf '#!/usr/bin/env bash\ntrap '"'"'kill $!; exit 0'"'"' TERM\nsleep 30 &\nwait\n' >"$T/holder/agent-slot-rex"
  chmod +x "$T/holder/agent-slot-rex"
  spawn "$T/holder/agent-slot-rex" </dev/null >/dev/null 2>&1 3>&-
  HOLDER=$!
  ln -s "$HOLDER" "$LOCK"
}

no_tab_change() {
  not_called '^rex (new|window new|window close|window rename)'
}

# --- timer and push passes ---------------------------------------------------------------------------------------------

@test "a timer or push pass with no Rex server answering logs a skip, resumes no slot, and exits 0" {
  local by
  touch "$STUBS/rexdata/server-down"
  for by in poll push; do
    run --separate-stderr "$AGENT_SLOT_REX" restore --by "$by" --output json
    [ "$status" -eq 0 ]
    jaq -e '.ok and .skipped.reason == "rex-server-down" and .opened == []' <<<"$output"
  done
  not_called '^agent-slot (list|resume)'
  no_tab_change
  jaq -s -e '[.[].by] == ["poll", "push"] and all(.[]; .ok and .skipped == "rex-server-down" and .plan == null)' "$LOG"
}

@test "a timer pass on a young server with no start-up record logs startup-pending; once the record exists it reconciles" {
  young
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "startup-pending"' <<<"$output"
  not_called '^agent-slot (list|resume)'
  no_tab_change
  [ ! -e "$RECORD" ]
  recorded "$REX_STUB_INSTANCE" "done"
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  jaq -s -e '[.[].skipped] == ["startup-pending", null] and .[1].changed' "$LOG"
}

@test "a timer pass on a server past the start-up limit with no record reconciles and records rexurrect as skipped" {
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  jaq -e --arg i "$REX_STUB_INSTANCE" '.instance == $i and .rexurrect == "skipped" and (.at | test("^[0-9]{4}-"))' \
    "$RECORD"
  not_called '^rexurrect '
}

@test "a record left by an older server instance does not count for the running one" {
  young
  recorded 99999999-0000-0000-0000-000000000000 "done"
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "startup-pending"' <<<"$output"
}

@test "a timer pass while another pass holds the lock logs busy at once and changes nothing" {
  hold_lock
  SECONDS=0
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  ((SECONDS < 5))
  jaq -e --arg p "$HOLDER" '.skipped.reason == "reconcile-busy" and (.skipped.message | contains("pid \($p)"))' \
    <<<"$output"
  not_called '^agent-slot (list|resume)'
  no_tab_change
  jaq -e '.skipped == "reconcile-busy" and .ok' "$LOG"
  [ "$(readlink "$LOCK")" = "$HOLDER" ]
}

@test "a push behind a pass that outlasts the lock wait logs busy and exits 0" {
  hold_lock
  run --separate-stderr env AGENT_SLOT_REX_LOCK_WAIT=1 "$AGENT_SLOT_REX" restore --by push --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "reconcile-busy"' <<<"$output"
  no_tab_change
}

@test "a pass that waited for the lock checks the start-up record again, and keeps the one written meanwhile" {
  hold_lock
  spawn env AGENT_SLOT_REX_LOCK_WAIT=20 "$AGENT_SLOT_REX" restore --by push --output json </dev/null >"$T/push.out" 2>&1 3>&-
  local push=$! i
  for ((i = 0; i < 100; i++)); do
    grep -q '^rex server status' "$CALLS" && break
    sleep 0.1
  done
  sleep 0.5
  recorded "$REX_STUB_INSTANCE" "done"
  kill "$HOLDER"
  for ((i = 0; i < 100; i++)); do
    kill -0 "$push" 2>/dev/null || break
    sleep 0.1
  done
  jaq -e '.rexurrect == "done"' "$RECORD"
  called "^rex new A --window A/1"
  jaq -e '.by == "push" and .ok and .rexurrect == null' "$LOG"
}

@test "a pass that waited for the lock across a Rex restart skips as startup-pending for the new instance" {
  hold_lock
  spawn env AGENT_SLOT_REX_LOCK_WAIT=20 "$AGENT_SLOT_REX" restore --by push --output json </dev/null >"$T/push.out" 2>&1 3>&-
  local push=$! i
  for ((i = 0; i < 100; i++)); do
    grep -q '^rex server status' "$CALLS" && break
    sleep 0.1
  done
  sleep 0.5
  printf '%s\n' 99999999-aaaa-bbbb-cccc-dddddddddddd >"$STUBS/rexdata/instance"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STUBS/rexdata/started"
  kill "$HOLDER"
  for ((i = 0; i < 100; i++)); do
    kill -0 "$push" 2>/dev/null || break
    sleep 0.1
  done
  jaq -e '.skipped.reason == "startup-pending"' "$T/push.out"
  no_tab_change
  [ ! -e "$RECORD" ]
}

# --- a restore asked for by hand ---------------------------------------------------------------------------------------

@test "a restore asked for by hand with no Rex server answering is rex-server-down, naming the service to start" {
  touch "$STUBS/rexdata/server-down"
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 78 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "rex-server-down" and .next_step.command == "systemctl --user start rex-server.service"
    and (.message | contains("no Rex server is running"))' <<<"$stderr"
  not_called '^agent-slot (list|resume)'
  jaq -e '.by == "restore" and .ok == false and .error.reason == "rex-server-down"' "$LOG"
}

@test "a restore asked for by hand on a young server with no start-up record is startup-pending, saying when it ends" {
  export REX_STUB_STARTED=2099-01-01T00:00:00Z
  run --separate-stderr env AGENT_SLOT_REX_STARTUP_LIMIT=300 "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e --arg i "$REX_STUB_INSTANCE" '.reason == "startup-pending" and .value == $i
    and (.message | contains("2099-01-01T00:05:00Z")) and .recovery.retryable' <<<"$stderr"
  no_tab_change
  jaq -e '.ok == false and .error.reason == "startup-pending"' "$LOG"
}

@test "a restore asked for by hand behind a held lock is reconcile-busy, naming the pid that holds it" {
  hold_lock
  run --separate-stderr env AGENT_SLOT_REX_LOCK_WAIT=1 "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  jaq -e --arg p "$HOLDER" '.reason == "reconcile-busy" and (.message | contains("pid \($p)"))' <<<"$stderr"
  jaq -e '.ok == false and .error.reason == "reconcile-busy"' "$LOG"
}

# --- a pass after a teardown -------------------------------------------------------------------------------------------

@test "a finish or sweep whose teardown succeeded with no Rex server answering reports the teardown and exits 0" {
  touch "$STUBS/rexdata/server-down"
  slot_answer finish 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"finish","key":"X/2","torn_down":true}'
  run --separate-stderr "$AGENT_SLOT_REX" finish X/2 --output json </dev/null
  [ "$status" -eq 0 ]
  jaq -e '.torn_down and .reconcile.skipped.reason == "rex-server-down"' <<<"$output"
  slot_answer sweep 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"sweep","torn_down":["X/3"]}'
  run "$AGENT_SLOT_REX" sweep </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"torn down: X/3"* ]]
  [[ $output == *"tabs not reconciled: no Rex server answers"* ]]
  not_called '^agent-slot list'
}

# --- the plan's closes -------------------------------------------------------------------------------------------------

@test "a planned close whose tab is already gone counts as closed, and the pass succeeds" {
  slots '[]'
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]},
    {"window_id": "w2", "label": "A/2", "blocks": ["b2"]}]'
  touch "$STUBS/rexdata/closed-elsewhere-w1"
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 0 ]
  jaq -e '[.closed[].key] == ["A/1", "A/2"]' <<<"$output"
  called '^rex window close -s sess-a w2$'
}

# --- the start-up step -------------------------------------------------------------------------------------------------

@test "the start-up step runs rexurrect under the lock before its first tab change, then records the instance" {
  started_by_rex
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rexurrect auto-restore --server-pid $REX_STUB_PID$"
  [ "$(grep -nE '^(rexurrect auto-restore|rex (new|window new))' "$CALLS" | head -1 | cut -d: -f2-)" = \
    "rexurrect auto-restore --server-pid $REX_STUB_PID" ]
  local holder
  holder=$(sed -n 's/^rexurrect-lock //p' "$CALLS")
  [ -n "$holder" ]
  called "^rex new A --window A/1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  jaq -e --arg i "$REX_STUB_INSTANCE" '.instance == $i and .rexurrect == "done"' "$RECORD"
  jaq -e '.by == "restore-at-start" and .ok and .rexurrect == "done" and .changed' "$LOG"
  [ ! -L "$LOCK" ]
}

@test "a second start-up step on the same instance, as a config reload starts, only reconciles" {
  started_by_rex
  recorded "$REX_STUB_INSTANCE" "done"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rexurrect '
  called "^rex new A --window A/1"
  jaq -e '.rexurrect == null and .by == "restore-at-start"' "$LOG"
}

@test "a start-up step on an instance a post-limit pass already recorded never calls rexurrect" {
  started_by_rex
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  jaq -e '.rexurrect == "skipped"' "$RECORD"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rexurrect '
}

@test "a start-up step on a new server instance runs rexurrect again" {
  started_by_rex
  recorded 99999999-0000-0000-0000-000000000000 "done"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rexurrect auto-restore --server-pid $REX_STUB_PID$"
  jaq -e --arg i "$REX_STUB_INSTANCE" '.instance == $i and .rexurrect == "done"' "$RECORD"
}

@test "with rexurrect absent the start-up step still reconciles and records rexurrect as skipped" {
  started_by_rex
  export AGENT_SLOT_REX_REXURRECT=$T/no-rexurrect
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1"
  jaq -e '.rexurrect == "skipped"' "$RECORD"
}

@test "a rexurrect that never exits is stopped at its bound; the step journals it, reconciles, and records it" {
  started_by_rex
  stub rexurrect 'exec sleep 30'
  export AGENT_SLOT_REX_REXURRECT_BOUND=1
  run timeout 20 "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1"
  jaq -e '.rexurrect == "stopped"' "$RECORD"
  jaq -e '.rexurrect == "stopped" and .ok' "$LOG"
  grep -q 'rexurrect: stopped' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "a rexurrect that fails is recorded as failed, and the step still reconciles" {
  started_by_rex
  stub rexurrect 'exit 3'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1"
  jaq -e '.rexurrect == "failed"' "$RECORD"
}

@test "a start-up step whose server never answers gives up at its bound, journals it, and records nothing" {
  started_by_rex
  touch "$STUBS/rexdata/server-down"
  export AGENT_SLOT_REX_STARTUP_WAIT=1
  run timeout 20 "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 78 ]
  not_called '^rexurrect '
  no_tab_change
  [ ! -e "$RECORD" ]
  jaq -e '.by == "restore-at-start" and .ok == false and .error.reason == "rex-server-down"' "$LOG"
  grep -q 'gave up: no Rex server answered within 1 s' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "a server that answers late still gets rexurrect then the reconcile, and timer passes meanwhile change nothing" {
  started_by_rex
  young
  touch "$STUBS/rexdata/server-down" "$T/rexurrect-hold"
  stub rexurrect 'while [ -e "'"$T"'/rexurrect-hold" ]; do sleep 0.1; done'
  spawn "$AGENT_SLOT_REX" restore --at-start </dev/null >/dev/null 2>&1 3>&-
  local step=$!
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "rex-server-down"' <<<"$output"
  rm "$STUBS/rexdata/server-down"
  local i
  for ((i = 0; i < 100; i++)); do
    grep -q '^rexurrect auto-restore' "$CALLS" && break
    sleep 0.1
  done
  called '^rexurrect auto-restore'
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "startup-pending"' <<<"$output"
  not_called '^agent-slot (list|resume)'
  no_tab_change
  rm "$T/rexurrect-hold"
  for ((i = 0; i < 100; i++)); do
    kill -0 "$step" 2>/dev/null || break
    sleep 0.1
  done
  called "^rex new A --window A/1"
  [ "$(grep -c '^agent-slot list' "$CALLS")" -eq 1 ]
  jaq -s -e '[.[].by] == ["poll", "poll", "restore-at-start"] and .[2].rexurrect == "done"' "$LOG"
}

@test "the start-up step does nothing when rex config check, not a Rex server, loaded init.lua" {
  printf '1 /usr/bin/rex config check /tmp/init.lua\n' >>"$STUBS/ps.txt"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  grep -q 'not started by a Rex server' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
  not_called '^rex '
  not_called '^rexurrect '
}
