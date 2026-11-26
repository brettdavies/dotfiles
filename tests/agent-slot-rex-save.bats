#!/usr/bin/env bats
# agent-slot-rex save, which the autosave timer runs: it calls `rexurrect save` only once the start-up step has run
# rexurrect's restore in the running Rex server, since a save in a server rexurrect has not restored into restores first
# and would double every repo session the reconcile already opened. Against stubbed rex and rexurrect.
#
# Run: bats tests/agent-slot-rex-save.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

setup() {
  agent_slot_rex_setup
  SAVES=$AGENT_SLOT_REX_STATE_DIR/save.log
  RECORD=$AGENT_SLOT_REX_STATE_DIR/startup.json
  mkdir -p "$REXURRECT_STATE_DIR"
  stub rexurrect 'exit 0'
}

# recorded OUTCOME: the start-up record shows rexurrect's OUTCOME in the running server instance.
recorded() {
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR"
  jaq -n -c --arg i "$REX_STUB_INSTANCE" --arg r "$1" '{instance: $i, rexurrect: $r, at: "2026-11-02T00:00:00Z"}' \
    >"$RECORD"
}

# paused: the save changed nothing, exited 0, and logged save-paused.
paused() {
  [ "$status" -eq 0 ]
  not_called '^rexurrect '
  jaq -e '.saved == false and .skipped.reason == "save-paused"' <<<"$output"
  jaq -e '.by == "save" and .ok and .skipped == "save-paused"' "$SAVES"
}

@test "save runs rexurrect save once the start-up step's restore is done" {
  recorded "done"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 0 ]
  called '^rexurrect save$'
  jaq -e --arg i "$REX_STUB_INSTANCE" '.saved and .instance == $i and .startup == "done" and .skipped == null' \
    <<<"$output"
  jaq -e '.by == "save" and .ok and .skipped == null and .rexurrect == "done"' "$SAVES"
}

@test "save runs after a failed restore when rexurrect recorded the server instance" {
  recorded failed
  printf '%s restore-failed\n' "$REX_STUB_INSTANCE" >"$REXURRECT_STATE_DIR/restored-instances"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 0 ]
  called '^rexurrect save$'
}

@test "save runs after a restore cut off at its bound when rexurrect recorded the server instance" {
  recorded stopped
  printf '%s\n' "$REX_STUB_INSTANCE" >"$REXURRECT_STATE_DIR/restored-instances"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 0 ]
  called '^rexurrect save$'
}

@test "save pauses after a failed restore rexurrect never recorded, since its save would restore into a filled server" {
  recorded failed
  printf '99999999-0000-0000-0000-000000000000\n' >"$REXURRECT_STATE_DIR/restored-instances"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  paused
  jaq -e '.skipped.next_step.command == "systemctl --user restart rex-server.service"' <<<"$output"
}

@test "save pauses while rexurrect stopped at its bound or was skipped, or the start-up step has not run" {
  local outcome
  for outcome in stopped skipped; do
    recorded "$outcome"
    run --separate-stderr "$AGENT_SLOT_REX" save --output json
    paused
  done
  rm -f "$RECORD"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  paused
  jaq -e '.startup == null and .skipped.next_step.command == "agent-slot-rex save"' <<<"$output"
}

@test "save changes nothing and exits 0 when no Rex server answers" {
  recorded "done"
  touch "$STUBS/rexdata/server-down"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 0 ]
  not_called '^rexurrect '
  jaq -e '.saved == false and .skipped.reason == "rex-server-down"' <<<"$output"
}

@test "a rexurrect save that fails fails the verb with its message" {
  recorded "done"
  stub rexurrect 'echo "rexurrect: the Rex server refused the snapshot" >&2; exit 1'
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 1 ]
  jaq -e --arg log "$REXURRECT_STATE_DIR/rexurrect.log" '.reason == "rexurrect-failed"
    and (.message | test("refused the snapshot")) and .log == $log and .next_step.command == "agent-slot-rex save"' \
    <<<"$stderr"
  jaq -e '.by == "save" and .ok == false and .error.reason == "rexurrect-failed" and .rexurrect == "failed"' "$SAVES"
}

@test "a rexurrect save that outlives its bound fails as rexurrect-failed, naming the bound" {
  recorded "done"
  stub rexurrect 'exec sleep 30'
  AGENT_SLOT_REX_SAVE_BOUND=1 run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "rexurrect-failed" and (.message | test("did not finish within 1 s"))' <<<"$stderr"
}

@test "a save with no rexurrect installed fails as rexurrect-missing, naming the deploy script" {
  recorded "done"
  rm "$STUBS/rexurrect"
  run --separate-stderr "$AGENT_SLOT_REX" save --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "rexurrect-missing" and .next_step.command == "cd ~/dotfiles && scripts/rexurrect-deploy.sh"' \
    <<<"$stderr"
  jaq -e '.by == "save" and .ok == false and .error.reason == "rexurrect-missing"' "$SAVES"
}
