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
  not_called '^rex (new|window new|window close|window rename|do|kill) '
}

# The instance restarts_after and stops_after hand the stub server by default.
NEW_INSTANCE=99999999-aaaa-bbbb-cccc-dddddddddddd

# restores_session ID LABEL TAB: the rexurrect stub restores a saved session as rexurrect does, under the ID ID whatever
# session already carries LABEL, with one tab, TAB, as a plain shell.
restores_session() {
  stub rexurrect '
jaq -c --arg id "'"$1"'" --arg l "'"$2"'" ".sessions += [{session_id: \$id, label: \$l}]" \
  "$STUBS/rexdata/sessions.json" >"$STUBS/rexdata/sessions.new"
mv "$STUBS/rexdata/sessions.new" "$STUBS/rexdata/sessions.json"
jaq -n -c --arg id "'"$1"'" --arg l "'"$2"'" --arg t "'"$3"'" "{session_id: \$id, label: \$l,
  windows: [{window_id: (\$id + \"-w\"), label: \$t, layers: [{blocks: [{block_id: (\$id + \"-b\")}]}]}]}" \
  >"$STUBS/rexdata/session-'"$1"'.json"'
}

# labeled LABEL: prints how many sessions carry LABEL.
labeled() {
  jaq --arg l "$1" '[.sessions[] | select(.label == $l)] | length' "$STUBS/rexdata/sessions.json"
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

@test "restore --by names what ran the pass in the reconcile log, with how long the pass took" {
  local by
  slots '[]'
  for by in push poll; do
    run "$AGENT_SLOT_REX" restore --by "$by" --output json
    [ "$status" -eq 0 ]
  done
  jaq -s -e '[.[].by] == ["push", "poll"] and all(.[]; .ok and (.ms | type == "number" and . >= 0))' "$LOG"
}

@test "restore --by takes only push or poll" {
  local by
  for by in sweep reconnect; do
    run --separate-stderr "$AGENT_SLOT_REX" restore --by "$by" --output json
    [ "$status" -eq 2 ]
    jaq -e --arg v "--by $by" '.reason == "usage" and .value == $v and (.message | contains("--by push|poll"))' \
      <<<"$stderr"
  done
}

@test "a timer pass that changes nothing still logs its line, small enough for a day of passes in the first 1 MiB" {
  slots '[]'
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  jaq -e '.by == "poll" and .changed == false' "$LOG"
  (($(wc -c <"$LOG") * 1440 < 1048576))
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

# --- a Rex restart under a pass ----------------------------------------------------------------------------------------

@test "a timer pass whose Rex server restarts after its gate makes no tab change on the new instance" {
  recorded "$REX_STUB_INSTANCE" "done"
  restarts_after 'ls --json'
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  no_tab_change
  jaq -e --arg old "$REX_STUB_INSTANCE" --arg new "$NEW_INSTANCE" '.skipped.reason == "rex-server-restarted"
    and (.skipped.message | contains($old) and contains($new)) and .opened == []' <<<"$output"
  jaq -e '.ok and .skipped == "rex-server-restarted" and (.changed | not) and .plan.open == []' "$LOG"
  [ ! -L "$LOCK" ]
}

@test "a pass whose Rex server restarts between two tab changes makes neither the second nor any after it" {
  recorded "$REX_STUB_INSTANCE" "done"
  slots '[{"repo": "A", "slot": 1}, {"repo": "B", "slot": 1}]'
  restarts_after 'new A'
  run --separate-stderr "$AGENT_SLOT_REX" restore --by push --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "rex-server-restarted" and .opened == ["A/1"]' <<<"$output"
  called '^rex new A '
  not_called '^rex (do|new B) '
  jaq -e '.skipped == "rex-server-restarted" and .changed and [.plan.open[].key] == ["A/1"]' "$LOG"
}

@test "a pass whose Rex server restarts right after its last tab change journals the restart" {
  recorded "$REX_STUB_INSTANCE" "done"
  restarts_after 'do agent_slot_layout'
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "rex-server-restarted" and .opened == ["A/1"]' <<<"$output"
  jaq -e '.skipped == "rex-server-restarted" and [.plan.open[].key] == ["A/1"]' "$LOG"
}

@test "a pass whose Rex server stops answering partway makes no further tab change and logs rex-server-down" {
  recorded "$REX_STUB_INSTANCE" "done"
  stops_after 'ls --json'
  run --separate-stderr "$AGENT_SLOT_REX" restore --by poll --output json
  [ "$status" -eq 0 ]
  jaq -e '.skipped.reason == "rex-server-down"' <<<"$output"
  no_tab_change
  jaq -e '.ok and .skipped == "rex-server-down"' "$LOG"
}

@test "a restore asked for by hand whose Rex server restarts partway is rex-server-restarted, and is journaled" {
  recorded "$REX_STUB_INSTANCE" "done"
  restarts_after 'ls --json'
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e --arg new "$NEW_INSTANCE" '.reason == "rex-server-restarted" and .value == $new
    and .next_step.command == "agent-slot-rex restore"' <<<"$stderr"
  no_tab_change
  jaq -e '.ok == false and .error.reason == "rex-server-restarted"' "$LOG"
}

@test "a pass that changes no tab asks the Rex server for its instance only at the gate" {
  recorded "$REX_STUB_INSTANCE" "done"
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  runs b1 1001 "agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  jaq -e '.ok and (.changed | not)' "$LOG"
  [ "$(grep -c '^rex server status' "$CALLS")" -eq 2 ]
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

@test "the start-up step kills a session a reconcile opened before rexurrect ran, so rexurrect doubles none" {
  started_by_rex
  session sess-early A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  runs b1 1001 "agent-slot-rex attach A/1 claude"
  restores_session sess-saved A A/1
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called '^rex kill sess-early$'
  local kill restore
  kill=$(grep -n '^rex kill ' "$CALLS" | head -1 | cut -d: -f1)
  restore=$(grep -n '^rexurrect auto-restore' "$CALLS" | cut -d: -f1)
  ((kill < restore))
  [ "$(labeled A)" -eq 1 ]
  called '^rex window new -s sess-saved A/1 '
  grep -q 'sess-early' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
  jaq -e '.ok and .rexurrect == "done"' "$LOG"
}

@test "the start-up step keeps a session holding only a prime's tab, and one holding a prime's and a slot's tab" {
  started_by_rex
  session sess-p A '[{"window_id": "w1", "label": "1: A", "blocks": ["b1"]}]'
  runs b1 1001 "agent-slot-rex attach A/prime claude"
  session sess-q B '[{"window_id": "w2", "label": "1: B", "blocks": ["b2"]},
    {"window_id": "w3", "label": "B/1", "blocks": ["b3"]}]'
  runs b2 1002 "agent-slot-rex attach B/prime claude"
  runs b3 1003 "agent-slot-rex attach B/1 claude"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex kill '
}

@test "the start-up step keeps a session that holds a tab the reconcile did not open" {
  started_by_rex
  session sess-own A '[{"window_id": "w1", "label": "prime", "blocks": ["b1"]},
    {"window_id": "w2", "label": "A/1", "blocks": ["b2"]}]'
  runs b2 1002 "agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex kill '
  called '^rexurrect auto-restore'
}

@test "a start-up step on an instance it already recorded kills no session" {
  started_by_rex
  recorded "$REX_STUB_INSTANCE" "done"
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  runs b1 1001 "agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex kill '
  not_called '^rexurrect '
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

# --- the prime tabs rexurrect restores ---------------------------------------------------------------------------------

# restored_prime: rexurrect brought session A back with its prime tab, "1: A Prime", as a plain zsh at its prompt in
# block pb on pts/9, and the prime map names A's prime session "A Prime", which runs with no client attached.
restored_prime() {
  primes A 'A Prime'
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["pb"]}]'
  at_prompt pb 701 pts/9
}

# typed_prime REPO: what the start-up step types into a restored prime tab, as the stub rex logs it: the keys that clear
# the prompt's line, then the prime command and Enter.
typed_prime() {
  printf '%s' $'\005\025'" exec $STUBS/agent-slot-rex prime $1"$'\r'
}

# sent_to BLOCK REPO: the calls log has the prime command typed into the block.
sent_to() {
  grep -qxF "rex send -s sess-a -b $1 $(typed_prime "$2")" "$CALLS" || {
    echo "no prime command was typed into $1" >&2
    cat -v "$CALLS" >&2
    return 1
  }
}

# primes_journaled JQ: the start-up step's journal line carries the prime outcomes the jq expression, applied to them,
# accepts.
primes_journaled() {
  jaq -e "select(.by == \"restore-at-start\") | .primes | $1" "$LOG" >/dev/null || {
    echo "journaled primes do not match: $1" >&2
    cat "$LOG" >&2
    return 1
  }
}

@test "after a restart the start-up step makes a restored prime tab the prime, between rexurrect and the reconcile" {
  started_by_rex
  restored_prime
  attaches_on_send pb pts/9
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  sent_to pb A
  local restore send list
  restore=$(grep -n '^rexurrect auto-restore' "$CALLS" | cut -d: -f1)
  send=$(grep -n '^rex send ' "$CALLS" | cut -d: -f1)
  list=$(grep -n '^agent-slot list' "$CALLS" | cut -d: -f1)
  ((restore < send && send < list))
  primes_journaled '. == [{repo: "A", prime: "A Prime", outcome: "reattached", session_id: "sess-a", window_id: "pw"}]'
  jaq -e '.ok and .rexurrect == "done"' "$LOG"
  grep -q 'A Prime.*reattached' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "after the start-up step reattached a prime, the new-agent key in its session starts a slot, not a second prime" {
  started_by_rex
  slots '[]'
  restored_prime
  attaches_on_send pb pts/9
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  local f=$STUBS/rexdata/session-sess-a.json
  jaq -c '.windows += [{window_id: "win-a", label: "new agent", layers: [{blocks: [{block_id: "blk-a"}]}]}]' "$f" \
    >"$f.new"
  mv "$f.new" "$f"
  repos A
  slot_answer launch 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"launch","created":true,"key":"A/3",
    "repo":"A","slot":3,"path":"/srv/slots/A/3","task":null,"request_id":"r","session_id":"s","base":"main",
    "trust_prompt_expected":false}'
  : >"$CALLS"
  REX_SESSION=sess-a REX_BLOCK=blk-a run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot launch A --model opus --request-id '
  not_called '^agent-slot-rex prime'
  not_called '^rex window move'
}

@test "a prime that a tab of its session already holds is left alone" {
  started_by_rex
  restored_prime
  prime_clients pts/9
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '.[0].outcome == "already-open"'
}

@test "a tab with the prime's label whose shell is running a program is left alone" {
  started_by_rex
  primes A 'A Prime'
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["pb"]}]'
  running_in pb 701 pts/9 nvim
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '.[0].outcome == "not-idle" and .[0].window_id == "pw"'
}

@test "a tab with the prime's label whose own process is a script in its terminal's foreground is left alone" {
  started_by_rex
  primes A 'A Prime'
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["pb"]}]'
  runs pb 701 "bash $STUBS/agent-slot-rex prime A"
  printf 'pts/9\n' >"$STUBS/tty/701"
  printf '{"child":{"pid":701,"name":"bash"},"foreground":{"pid":701,"name":"bash"}}\n' >"$STUBS/rexdata/process-pb.json"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '.[0].outcome == "not-idle"'
}

@test "a tab with the prime's label that holds more than one pane is left alone" {
  started_by_rex
  primes A 'A Prime'
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["pb", "pc"]}]'
  at_prompt pb 701 pts/9
  at_prompt pc 702 pts/10
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '.[0].outcome == "not-idle"'
}

@test "a restored prime tab whose prime tmux session is not running is left alone and journaled prime-not-running" {
  started_by_rex
  restored_prime
  no_old_primes
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '.[0].outcome == "prime-not-running" and .[0].window_id == "pw"'
  grep -qF "no session named A Prime on the default tmux server holds a Claude" "$AGENT_SLOT_REX_STATE_DIR/restore.log"
  called "^rex window new -s sess-a A/1 "
}

@test "a repo with no session, or whose session has no tab labelled exactly as its prime, gets nothing typed" {
  started_by_rex
  primes A 'A Prime' B 'B Prime'
  session sess-a A '[{"window_id": "w1", "label": "2: A Prime notes", "blocks": ["b1"]},
    {"window_id": "w2", "label": "A Prime", "blocks": ["b2"]}]'
  at_prompt b1 701 pts/9
  running_in b2 702 pts/10 htop
  session sess-x X '[{"window_id": "wx", "label": "1: B Prime", "blocks": ["bx"]}]'
  at_prompt bx 703 pts/11
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  primes_journaled '[.[] | {repo, outcome}] == [{repo: "A", outcome: "not-idle"}, {repo: "B", outcome: "no-session"}]'
  : >"$CALLS"
  rm "$RECORD"
  at_prompt b2 702 pts/10
  printf '%s\n' "$NEW_INSTANCE" >"$STUBS/rexdata/instance"
  jaq -c '.windows |= map(select(.window_id != "w2"))' "$STUBS/rexdata/session-sess-a.json" >"$T/s.json"
  mv "$T/s.json" "$STUBS/rexdata/session-sess-a.json"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  [ "$(jaq -s -r '.[-1].primes[0].outcome' "$LOG")" = no-tab ]
}

@test "of two tabs that carry the prime's label, only the first becomes the prime" {
  started_by_rex
  primes A 'A Prime'
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["pb"]},
    {"window_id": "qw", "label": "2: A Prime", "blocks": ["qb"]}]'
  at_prompt pb 701 pts/9
  at_prompt qb 702 pts/10
  attaches_on_send pb pts/9
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  sent_to pb A
  [ "$(grep -c '^rex send ' "$CALLS")" -eq 1 ]
  primes_journaled '. == [{repo: "A", prime: "A Prime", outcome: "reattached", session_id: "sess-a", window_id: "pw"}]'
}

@test "a prime command that brings no client within the wait is journaled unconfirmed" {
  started_by_rex
  restored_prime
  export AGENT_SLOT_REX_PRIME_WAIT=1
  run timeout 45 "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  sent_to pb A
  primes_journaled '.[0].outcome == "unconfirmed"'
}

@test "a rex call that fails while reattaching one prime still reattaches the next and reconciles every slot" {
  started_by_rex
  restored_prime
  primes B 'B Prime' A 'A Prime again'
  rm "$STUBS/rexdata/session-sess-a.json"
  session sess-b B '[{"window_id": "bw", "label": "1: B Prime", "blocks": ["bb"]}]'
  at_prompt bb 702 pts/10
  attaches_on_send bb pts/10
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send -s sess-a '
  called "^rex send -s sess-b -b bb "
  called "^rex window new -s sess-a A/1 "
  primes_journaled '[.[] | {repo, outcome}] == [{repo: "A", outcome: "rex-failed"}, {repo: "B", outcome: "reattached"}]'
  jaq -e 'select(.by == "restore-at-start") | .ok and .changed' "$LOG"
  grep -q 'session sess-a not found' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "a Rex restart while the start-up step reattaches primes types nothing more and leaves the tabs to the new instance" {
  started_by_rex
  restored_prime
  restarts_after 'block call'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  no_tab_change
  not_called '^agent-slot list'
  primes_journaled '.[0].outcome == "rex-server-restarted"'
  jaq -e '.ok and .skipped == "rex-server-restarted"' "$LOG"
  [ ! -L "$LOCK" ]
}

@test "a start-up step on an instance it already recorded, as a config reload runs, types into no prime tab" {
  started_by_rex
  recorded "$REX_STUB_INSTANCE" "done"
  restored_prime
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex send '
  not_called '^tmux -L default list-clients'
  jaq -e 'has("primes") and .primes == null' "$LOG"
}

# --- a restored prime tab of three panes ------------------------------------------------------------------------------

# prime_answer REPO SERVER STARTED-JSON: what agent-slot prime answers for the repo.
prime_answer() {
  slot_answer prime 0 "$(jaq -n -c --arg r "$1" --arg s "$2" --argjson started "$3" '{schema: "dotfiles.agent-slot/1",
    ok: true, verb: "prime", key: "\($r)/prime", repo: $r, path: "/srv/\($r)", name: "\($r)-prime", server: $s,
    session: "\($r)-prime", started: $started, conversation: {mode: "fresh", session_id: "s"},
    trust_prompt_expected: false}')"
}

# restored_three_panes: rexurrect brought session A back with its prime tab, "1: A Prime", as three plain zsh panes, each
# at its prompt, and no session on the default server holds a Claude.
restored_three_panes() {
  primes A 'A Prime'
  no_old_primes
  session sess-a A '[{"window_id": "pw", "label": "1: A Prime", "blocks": ["b1", "b2", "b3"]}]'
  at_prompt b1 701 pts/9
  at_prompt b2 702 pts/10
  at_prompt b3 703 pts/11
}

@test "a restored prime tab of three idle shells is replaced: the prime starts, a new tab opens first, the old one closes" {
  started_by_rex
  slots '[]' '[{"repo": "A", "label": "A Prime"}]'
  restored_three_panes
  prime_answer A slots '["A-prime", "A-prime-files", "A-prime-git"]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  in_call_order '^rexurrect auto-restore' '^agent-slot prime A --output json$' \
    "^rex window new -s sess-a A Prime --focus=false --json -- $STUBS/agent-slot-rex attach A/prime claude\$" \
    '^rex do agent_slot_layout -s sess-a -b blk-new-[0-9]+ key=A/prime block=blk-new-[0-9]+$' \
    '^rex window move -s sess-a win-new-[0-9]+ --index 1$' \
    '^rex window close -s sess-a pw$' '^agent-slot list'
  not_called '^rex send '
  [ "$(grep -c '^rex window new' "$CALLS")" -eq 1 ]
  primes_journaled '. == [{repo: "A", prime: "A Prime", outcome: "reopened", session_id: "sess-a", window_id: "pw"}]'
  grep -q 'A Prime.*reopened' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "with the prime already running, a restored tab of three idle shells is replaced the same way" {
  started_by_rex
  slots '[]'
  restored_three_panes
  prime_answer A slots '[]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called '^rex window close -s sess-a pw$'
  primes_journaled '.[0].outcome == "reopened"'
}

@test "a restored three-pane tab with a pane running a program is left alone, and starts nothing" {
  started_by_rex
  slots '[]'
  restored_three_panes
  running_in b2 702 pts/10 nvim
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^agent-slot prime'
  not_called '^rex window (new|close|move)'
  primes_journaled '.[0].outcome == "not-idle" and .[0].window_id == "pw"'
}

@test "a server answering that an old-style session holds the prime leaves a restored three-pane tab alone" {
  started_by_rex
  slots '[]'
  restored_three_panes
  prime_answer A default '[]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called '^agent-slot prime A '
  not_called '^rex window (new|close|move)'
  primes_journaled '.[0].outcome == "not-idle"'
}

@test "an agent-slot prime that fails leaves the restored tab, journals its reason, and the next repo still runs" {
  started_by_rex
  slots '[]'
  restored_three_panes
  primes B 'B Prime'
  session sess-b B '[{"window_id": "qw", "label": "1: B Prime", "blocks": ["qb"]}]'
  at_prompt qb 801 pts/12
  attaches_on_send qb pts/12
  slot_answer prime 1 "" "$(server_error tmux-failed "could not start the tmux session A-prime" 1 true)"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex window close -s sess-a pw$'
  not_called "^rex window new -s sess-a A Prime "
  primes_journaled '.[0].outcome == "tmux-failed" and .[0].repo == "A" and .[1].outcome == "reattached" and .[1].repo == "B"'
  grep -q 'could not start the tmux session A-prime' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
}

@test "a repo with no map line whose session has a tab labelled with its name is handled, and one with no session is not walked" {
  started_by_rex
  slots '[]'
  repos B C
  no_old_primes
  session sess-b B '[{"window_id": "qw", "label": "1: B", "blocks": ["q1", "q2", "q3"]}]'
  at_prompt q1 801 pts/12
  at_prompt q2 802 pts/13
  at_prompt q3 803 pts/14
  prime_answer B slots '[]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  called "^rex window new -s sess-b B --focus=false --json -- $STUBS/agent-slot-rex attach B/prime claude\$"
  called '^rex window close -s sess-b qw$'
  primes_journaled '. == [{repo: "B", prime: "B", outcome: "reopened", session_id: "sess-b", window_id: "qw"}]'
}

@test "a repo the map names is walked once, whatever repos says" {
  started_by_rex
  slots '[]'
  restored_prime
  attaches_on_send pb pts/9
  repos A
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  primes_journaled 'length == 1 and .[0].outcome == "reattached"'
}

@test "a repos call that fails leaves the walk to the map's lines" {
  started_by_rex
  slots '[]'
  restored_prime
  attaches_on_send pb pts/9
  slot_answer repos 1 "" "$(server_error tmux-failed "no" 1 true)"
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  primes_journaled '. == [{repo: "A", prime: "A Prime", outcome: "reattached", session_id: "sess-a", window_id: "pw"}]'
}

@test "a Rex restart while a restored three-pane tab is replaced closes nothing and leaves the tabs to the new instance" {
  started_by_rex
  slots '[]'
  restored_three_panes
  prime_answer A slots '[]'
  restarts_after 'window new'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^rex window close'
  not_called '^rex do agent_slot_layout'
  not_called '^agent-slot list'
  primes_journaled '.[0].outcome == "rex-server-restarted"'
}

@test "a start-up step on an instance it already recorded, as a config reload runs, replaces no three-pane tab" {
  started_by_rex
  recorded "$REX_STUB_INSTANCE" "done"
  slots '[]'
  restored_three_panes
  prime_answer A slots '[]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  not_called '^agent-slot prime'
  not_called '^rex window (new|close|move)'
}

@test "only the start-up step journals prime outcomes; every other pass journals primes as null" {
  restored_prime
  run "$AGENT_SLOT_REX" restore --by poll
  [ "$status" -eq 0 ]
  not_called '^rex send '
  jaq -e '.by == "poll" and has("primes") and .primes == null' "$LOG"
}
