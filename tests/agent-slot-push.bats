#!/usr/bin/env bats
# agent-slot's push to this host's Rex layer: after a launch makes a slot, and after a sweep or finish tears one down,
# agent-slot runs the Rex helper's `restore --by push` here. The push runs in the background, never changes the verb's
# result or exit code, does nothing without the helper, skips a verb the helper ran itself, and logs one line. The last
# tests run the real helper against a stubbed Rex server, so a teardown's push is seen closing that slot's tab.
#
# Run: bats tests/agent-slot-push.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  PUSH_LOG=$AGENT_SLOT_STATE_DIR/push.log
  # The helper logs its argv and runtime directory, then answers from $T/helper.{out,err,rc}; while $T/helper.hold
  # exists it does not answer, for up to 30 s.
  mkdir -p "$T/helper"
  cat >"$T/helper/agent-slot-rex" <<EOF
#!/usr/bin/env bash
printf 'helper %s XDG_RUNTIME_DIR=%s\n' "\$*" "\${XDG_RUNTIME_DIR-unset}" >>'$CALLS'
for ((i = 0; i < 300; i++)); do [ -e '$T/helper.hold' ] || break; sleep 0.1; done
[ ! -e '$T/helper.out' ] || cat '$T/helper.out'
[ ! -e '$T/helper.err' ] || cat '$T/helper.err' >&2
exit "\$(cat '$T/helper.rc' 2>/dev/null || echo 0)"
EOF
  chmod +x "$T/helper/agent-slot-rex"
  export AGENT_SLOT_REX_HELPER=$T/helper/agent-slot-rex
  PUSHED="helper restore --by push --output json XDG_RUNTIME_DIR="
}

# pushed N: waits up to 30 s of wall time for the push log to hold N lines. A deadline rather than a count of tries,
# because on a loaded machine the push under test can take far longer than usual to land.
pushed() {
  local deadline=$((SECONDS + 30))
  until (($(cat "$PUSH_LOG" 2>/dev/null | wc -l) >= $1)); do
    ((SECONDS < deadline)) || {
      echo "the push log holds fewer than $1 lines after 30 s:" >&2
      cat "$PUSH_LOG" >&2 2>/dev/null || true
      return 1
    }
    sleep 0.1
  done
}

# push_timeout SECONDS: how long one push may take.
push_timeout() { export AGENT_SLOT_PUSH_TIMEOUT=$1; }

# no_helper: the Rex helper is not installed.
no_helper() { export AGENT_SLOT_REX_HELPER=$T/no-helper; }

# helper_answers RC [STDOUT [STDERR]]: how the helper's restore ends.
helper_answers() {
  printf '%s\n' "$1" >"$T/helper.rc"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >"$T/helper.out"
  [[ -z ${3:-} ]] || printf '%s\n' "$3" >"$T/helper.err"
}

launch_repoa() {
  prime repoa
  trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-push --output json
}

@test "a launch that makes a slot runs one local restore by push, and logs it" {
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  jaq -e '.key == "repoa/1" and .created' <<<"$output"
  [ "$(grep -c '^helper ' "$CALLS")" -eq 1 ]
  grep -q "^$PUSHED" "$CALLS"
  jaq -e '.verb == "launch" and .keys == ["repoa/1"] and .result == "restored" and .exit == 0 and .detail == null
    and (.ms | type == "number") and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$PUSH_LOG"
}

@test "a launch returns without waiting on its restore, and the push is logged once the restore ends" {
  touch "$T/helper.hold"
  launch_repoa
  [ "$status" -eq 0 ]
  sleep 1
  [ ! -e "$PUSH_LOG" ]
  rm "$T/helper.hold"
  pushed 1
  jaq -e '.result == "restored"' "$PUSH_LOG"
}

@test "a push that outlives its bound is logged as timed out" {
  push_timeout 1
  touch "$T/helper.hold"
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  jaq -e '.result == "timed-out" and .exit == 124' "$PUSH_LOG"
}

@test "a restore that fails is logged with its exit and last line, and the launch's result is unchanged" {
  helper_answers 1 '' $'agent-slot-rex: rex-failed: rex ls exited 1\n{"ok":false,"reason":"rex-failed"}'
  launch_repoa
  [ "$status" -eq 0 ]
  jaq -e '.ok and .key == "repoa/1" and .created' <<<"$output"
  pushed 1
  jaq -e '.result == "restore-failed" and .exit == 1 and .detail == "{\"ok\":false,\"reason\":\"rex-failed\"}"' \
    "$PUSH_LOG"
}

@test "a restore whose pass changed nothing is logged as deferred, naming why" {
  helper_answers 0 '{"ok":true,"verb":"restore","skipped":{"reason":"startup-pending","message":"m"}}'
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  jaq -e '.result == "deferred" and .exit == 0 and .detail == "startup-pending"' "$PUSH_LOG"
}

@test "the restore gets the user manager's runtime directory when the caller has none" {
  prime repoa
  trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/1")"
  run --separate-stderr env -u XDG_RUNTIME_DIR "$AGENT_SLOT" launch repoa --request-id r-push --output json
  [ "$status" -eq 0 ]
  pushed 1
  grep -qx "${PUSHED}/run/user/$(id -u)" "$CALLS"
}

@test "a verb the helper ran pushes nothing, since the helper reconciles next, and logs the skip" {
  AGENT_SLOT_REX_CLIENT=server launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  run ! grep -q '^helper ' "$CALLS"
  jaq -e '.result == "skipped" and .exit == null' "$PUSH_LOG"
}

@test "with no Rex helper installed, a launch makes its slot, pushes nothing, and returns its usual result" {
  no_helper
  launch_repoa
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .created' <<<"$output"
  sleep 1
  [ ! -e "$PUSH_LOG" ]
}

@test "a launch that returns the slot an earlier try made pushes nothing again" {
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-push --output json
  [ "$status" -eq 0 ]
  jaq -e '.created == false' <<<"$output"
  sleep 1
  [ "$(wc -l <"$PUSH_LOG")" -eq 1 ]
}

# finished_slot: repoa/1 is a finished task whose tmux sessions run, and each verb waits for its push.
finished_slot() {
  export AGENT_SLOT_PUSH_WAIT=1
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  finished_task
}

@test "a sweep that tears a slot down pushes, naming the slot" {
  finished_slot
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  pushed 1
  jaq -e '.verb == "sweep" and .keys == ["repoa/1"] and .result == "restored"' "$PUSH_LOG"
}

@test "a finish that tears a slot down pushes, naming the slot" {
  finished_slot
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == true' <<<"$output"
  pushed 1
  jaq -e '.verb == "finish" and .keys == ["repoa/1"] and .result == "restored"' "$PUSH_LOG"
}

@test "a push that fails leaves a sweep's result and exit code unchanged" {
  finished_slot
  helper_answers 1 '' 'boom'
  run --separate-stderr "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.ok and .torn_down == ["repoa/1"]' <<<"$output"
  jaq -e '.result == "restore-failed" and .detail == "boom"' "$PUSH_LOG"
}

@test "a push that times out leaves a finish's result and exit code unchanged" {
  push_timeout 1
  finished_slot
  touch "$T/helper.hold"
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.ok and .torn_down == true' <<<"$output"
  jaq -e '.verb == "finish" and .result == "timed-out"' "$PUSH_LOG"
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
  run ! grep -q '^helper ' "$CALLS"
  [ ! -e "$PUSH_LOG" ]
}

@test "past 1 MiB the push log moves to push.log.1, replacing the one before" {
  mkdir -p "$AGENT_SLOT_STATE_DIR"
  echo older >"$PUSH_LOG.1"
  head -c 1100000 /dev/zero | tr '\0' x >"$PUSH_LOG"
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  [ "$(wc -c <"$PUSH_LOG.1")" -eq 1100000 ]
  jaq -e '.verb == "launch"' "$PUSH_LOG"
}

# --- through the real helper -------------------------------------------------------------------------------------------

# real_helper: the push runs the real agent-slot-rex, which calls this agent-slot and a stubbed Rex server holding one
# session per repo, from $T/rex/sessions.json and session-<id>.json, whose tabs' blocks run nothing.
real_helper() {
  mkdir -p "$T/rex"
  printf '{"sessions":[]}\n' >"$T/rex/sessions.json"
  cat >"$T/rex/rex" <<EOF
#!/usr/bin/env bash
[ "\$1" = --autostart=false ] || exit 99
shift
printf 'rex %s\n' "\$*" >>'$CALLS'
case "\$1 \$2" in
  'server status') printf '%s\n' 'pid: 1' 'instance: i-1' 'started: 2026-01-01T00:00:00Z' 'version: 0' ;;
  'ls --json') cat '$T/rex/sessions.json' ;;
  'session inspect') cat "$T/rex/session-\$3.json" ;;
  'block call') echo '{"child":{"pid":0}}' ;;
  'window new') echo '{"window_id":"w-new","block_ids":["b-new"]}' ;;
  new\ *) echo '{"session_id":"sess-new","initial_windows":[{"window_id":"w-new","block_ids":["b-new"]}]}' ;;
esac
EOF
  chmod +x "$T/rex/rex"
  export REX_BIN_DIR=$T/rex AGENT_SLOT_REX_APP_PATHS='' AGENT_SLOT_REX_STATE_DIR=$T/rex-state
  export AGENT_SLOT_REX_AGENT_SLOT=$AGENT_SLOT AGENT_SLOT_REX_SELF=$T/rex/self
  export AGENT_SLOT_REX_HELPER=$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/agent-slot-rex
}

# rex_tab SESSION-LABEL WINDOW LABEL: the stubbed Rex server holds a session with one tab of that label.
rex_tab() {
  jaq -c --arg l "$1" '.sessions += [{session_id: "sess-\($l)", label: $l}]' "$T/rex/sessions.json" >"$T/rex/s.new"
  cp "$T/rex/s.new" "$T/rex/sessions.json"
  jaq -n -c --arg l "$1" --arg w "$2" --arg t "$3" '{session_id: "sess-\($l)", label: $l,
    windows: [{window_id: $w, label: $t, layers: [{blocks: [{block_id: "b-\($w)"}]}]}]}' >"$T/rex/session-sess-$1.json"
}

@test "a sweep that tears a slot down while a Rex server is present closes that slot's tab through one local restore" {
  real_helper
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  rex_tab repoa w1 'repoa/1 · t1'
  finished_task
  run --separate-stderr env AGENT_SLOT_PUSH_WAIT=1 "$AGENT_SLOT" sweep --yes --output json
  [ "$status" -eq 0 ]
  jaq -e '.torn_down == ["repoa/1"]' <<<"$output"
  jaq -e '.result == "restored" and .detail == null' "$PUSH_LOG"
  grep -qx 'rex window close -s sess-repoa w1' "$CALLS"
  jaq -e '.by == "push" and .ok and [.plan.close[] | {key, why}] == [{key: "repoa/1", why: "slot is gone"}]' \
    "$T/rex-state/reconcile.log"
}

@test "a push behind a pass that holds the lock gives up inside its own bound, logged as deferred" {
  real_helper
  push_timeout 4
  mkdir -p "$T/rex-state" "$T/holder"
  printf '#!/usr/bin/env bash\ntrap '"'"'kill $!; exit 0'"'"' TERM\nsleep 30 &\nwait\n' >"$T/holder/agent-slot-rex"
  chmod +x "$T/holder/agent-slot-rex"
  "$T/holder/agent-slot-rex" </dev/null >/dev/null 2>&1 3>&- &
  local holder=$!
  ln -s "$holder" "$T/rex-state/reconcile.lock"
  launch_repoa
  [ "$status" -eq 0 ]
  pushed 1
  kill "$holder"
  jaq -e '.result == "deferred" and .detail == "reconcile-busy"' "$PUSH_LOG"
  jaq -e '.by == "push" and .ok and .skipped == "reconcile-busy"' "$T/rex-state/reconcile.log"
}

@test "the finish a release starts closes its slot's tab and leaves another slot's tmux sessions alone" {
  real_helper
  task_slot_setup
  slot repoa 2 '{"task": "t2"}'
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\nrepoa-2\nrepoa-2-files\nrepoa-2-git\n' >"$STUBS/tmux-sessions"
  rex_tab repoa w1 'repoa/1 · t1'
  finished_task
  : >"$CALLS"
  run --separate-stderr env AGENT_SLOT_PUSH_WAIT=1 "$AGENT_SLOT" finish repoa/1 --yes --output json
  [ "$status" -eq 0 ]
  grep -qx 'rex window close -s sess-repoa w1' "$CALLS"
  run ! grep -E '^tmux .*(new-session|kill-session).*repoa-2' "$CALLS"
  run ! grep -q '^agent-slot resume\|resume repoa/2' "$CALLS"
  grep -qx 'repoa-2' "$STUBS/tmux-sessions"
}

@test "list and check report a working slot the same before and after a reconcile that rebuilt its tab" {
  real_helper
  slot repoa 2 '{"task": "t2"}'
  printf 'repoa-2\nrepoa-2-files\nrepoa-2-git\n' >"$STUBS/tmux-sessions"
  local list_before check_before
  run --separate-stderr "$AGENT_SLOT" list --output json
  list_before=$(jaq -c '[.slots[] | {key, state, agent, needs_you}]' <<<"$output")
  run --separate-stderr "$AGENT_SLOT" check repoa/2 --output json
  check_before=$(jaq -c '[.slots[] | {key, teardown, blockers}]' <<<"$output")
  run --separate-stderr "$AGENT_SLOT_REX_HELPER" restore --output json
  [ "$status" -eq 0 ]
  jaq -e '.opened == ["repoa/2"]' <<<"$output"
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$(jaq -c '[.slots[] | {key, state, agent, needs_you}]' <<<"$output")" = "$list_before" ]
  run --separate-stderr "$AGENT_SLOT" check repoa/2 --output json
  [ "$(jaq -c '[.slots[] | {key, teardown, blockers}]' <<<"$output")" = "$check_before" ]
}
