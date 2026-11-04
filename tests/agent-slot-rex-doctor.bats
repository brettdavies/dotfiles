#!/usr/bin/env bats
# agent-slot-rex doctor on the Linux server: the Rex server and the units that keep the slot layer running, rexurrect,
# the reconcile journal, where the slot tmux server runs, and agent-slot's own doctor, against stubbed rex, systemctl,
# tmux, ps, and agent-slot.
#
# Run: bats tests/agent-slot-rex-doctor.bats

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

SLOT_DOCTOR='{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"doctor","findings":[],
  "launch_times":{"launches":0,"measured":0,"not_ready":[],"skewed":0,"median_s":null,"p90_s":null,"target_s":30},
  "verified_versions":{"claude":"2.1.310"}}'

setup() {
  agent_slot_rex_setup
  slot_answer doctor 0 "$SLOT_DOCTOR"
  export AGENT_SLOT_REX_VERIFIED_VERSIONS=$T/verified-versions
  rex_versions 0.0.1
  printf '# test\nrex 0.0.1\n' >"$AGENT_SLOT_REX_VERIFIED_VERSIONS"
  printf '777\n' >"$STUBS/tmux-answers/pid"
  printf '0::/user.slice/user-1000.slice/session-c1.scope\n' >"$STUBS/cgroup.txt"
  STATE=$AGENT_SLOT_REX_STATE_DIR
  mkdir -p "$STATE"
}

# doctor: runs doctor --output json, leaving its findings in $output.
doctor() {
  run --separate-stderr "$AGENT_SLOT_REX" doctor --output json
}

# finding REASON: the finding with that reason, or nothing.
finding() {
  jaq -c --arg r "$1" '.findings[] | select(.reason == $r)' <<<"$output"
}

# journal_line SECONDS-AGO OK: one reconcile journal line that ran that many seconds ago.
journal_line() {
  local at
  at=$(jaq -n -r --argjson s "$1" 'now - $s | floor | todate')
  jaq -n -c --arg at "$at" --argjson ok "$2" '{at: $at, by: "poll", pid: 1, ok: $ok, ms: 5, changed: false, plan: null,
    error: (if $ok then null else {reason: "rex-failed", message: "rex ls exited 1", log: null} end)}' \
    >>"$STATE/reconcile.log"
}

# startup_record INSTANCE REXURRECT: the start-up step's record for a Rex server instance.
startup_record() {
  jaq -n -c --arg i "$1" --arg r "$2" '{instance: $i, rexurrect: $r, at: "2026-11-02T23:16:07Z"}' >"$STATE/startup.json"
}

@test "with every unit active and the verified build running, doctor reports no findings and exits 0" {
  journal_line 30 true
  startup_record "$REX_STUB_INSTANCE" "done"
  doctor
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .findings == [] and .launch_times.target_s == 30
    and .verified_versions.claude == "2.1.310"' <<<"$output"
  called '^agent-slot doctor --output json$'
  not_called '^ssh-stub '
}

@test "doctor names each inactive unit in a finding with the command that starts it" {
  unit agent-slot-reconcile.timer inactive
  unit rex-tab-numbers.service failed
  unit rex-login-server.service inactive
  doctor
  [ "$status" -eq 1 ]
  jaq -e '[.findings[] | {reason, severity, host, command: .next_step.command}] == [
    {reason: "reconcile-timer-inactive", severity: "error", host: "server",
     command: "systemctl --user enable --now agent-slot-reconcile.timer"},
    {reason: "tab-numbers-inactive", severity: "error", host: "server",
     command: "systemctl --user enable --now rex-tab-numbers.service"},
    {reason: "login-server-inactive", severity: "error", host: "server",
     command: "sudo systemctl enable --now rex-login-server.service"}]' <<<"$output"
  called '^systemctl is-active rex-login-server.service$'
}

@test "with no Rex server answering, doctor reports rex-server-down with the command that starts the service" {
  touch "$STUBS/rexdata/server-down"
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.next_step.command == "systemctl --user start rex-server.service" and .severity == "error"
    and (.message | contains("no Rex server is running"))' <<<"$(finding rex-server-down)"
  [ -z "$(finding rex-server-foreign)" ]
}

@test "doctor names a Rex server that rex-server.service did not start, with the commands that hand the socket back" {
  printf '0\n' >"$STUBS/units/rex-server.service.pid"
  doctor
  [ "$status" -eq 1 ]
  jaq -e --arg r "$STUBS/rexurrect" '.severity == "error" and .value == "4242"
    and .next_step.action == "ask-operator"
    and .next_step.command == "\($r) save && rex --autostart=false server stop && systemctl --user restart rex-server.service"
    and (.message | contains("pid 4242") and contains("MainPID 0"))' <<<"$(finding rex-server-foreign)"
}

@test "doctor reports rex-restart-pending with the four steps in order when the installed Rex is newer than the server" {
  rex_versions 0.0.2 0.0.1
  printf 'rex 0.0.2\n' >"$AGENT_SLOT_REX_VERIFIED_VERSIONS"
  doctor
  [ "$status" -eq 0 ]
  jaq -e --arg r "$STUBS/rexurrect" '.severity == "warning" and .value == "0.0.1"
    and .next_step.command == "\($r) save && systemctl --user restart rex-server.service"
    and (.message | test("1\\) update Rex.app and the iOS app to at least 0.0.2.*2\\) .*save.*3\\) systemctl --user restart rex-server.service.*4\\) rerun the two-machine checklist"))' \
    <<<"$(finding rex-restart-pending)"
}

@test "doctor reports version-unverified for an unlisted Rex build and nothing for the listed one" {
  rex_versions 9.9.9
  doctor
  [ "$status" -eq 0 ]
  jaq -e '.severity == "warning" and .value == "9.9.9"' <<<"$(finding version-unverified)"
  rex_versions 0.0.1
  doctor
  [ -z "$(finding version-unverified)" ]
}

@test "doctor reports reconcile-stale for a newest journal line 4 minutes old, and for three failed passes in a row" {
  journal_line 240 true
  doctor
  [ "$status" -eq 1 ]
  jaq -e --arg log "$STATE/reconcile.log" '.next_step.command == "agent-slot-rex restore" and .value == $log' \
    <<<"$(finding reconcile-stale)"
  : >"$STATE/reconcile.log"
  journal_line 90 true
  journal_line 60 false
  journal_line 30 false
  doctor
  [ -z "$(finding reconcile-stale)" ]
  journal_line 5 false
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.message | contains("last 3 passes failed")' <<<"$(finding reconcile-stale)"
}

@test "doctor reports reconcile-stale for three passes in a row that found the reconcile lock held" {
  local i
  for i in 90 60 30; do
    jaq -n -c --arg at "$(jaq -n -r --argjson s "$i" 'now - $s | floor | todate')" '{at: $at, by: "poll", pid: 1,
      ok: true, ms: 5, changed: false, plan: null, skipped: "reconcile-busy", rexurrect: null, error: null}' \
      >>"$STATE/reconcile.log"
  done
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.message | contains("last 3 passes found the reconcile lock held")' <<<"$(finding reconcile-stale)"
}

@test "a stale journal is not reported while the reconcile timer is off, which its own finding covers" {
  journal_line 600 true
  unit agent-slot-reconcile.timer inactive
  doctor
  [ -z "$(finding reconcile-stale)" ]
  [ -n "$(finding reconcile-timer-inactive)" ]
}

@test "doctor reports nothing for a slot tmux server in a login session's scope or a scope of its own" {
  doctor
  [ -z "$(finding tmux-outside-scope)" ]
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/agent-slots-tmux-12-1793000000.scope\n' \
    >"$STUBS/cgroup.txt"
  doctor
  [ -z "$(finding tmux-outside-scope)" ]
  called '^ps -o cgroup= -p 777$'
}

@test "doctor reports tmux-outside-scope for a slot tmux server in the Rex server's or a timer's unit, with a next step" {
  local unit_name
  for unit_name in rex-server.service agent-slot-sweep.service; do
    printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s\n' "$unit_name" >"$STUBS/cgroup.txt"
    doctor
    [ "$status" -eq 0 ]
    jaq -e --arg u "$unit_name" '.severity == "warning" and .value == $u and .next_step.action == "ask-operator"
      and .next_step.command == "agent-slot list" and (.message | contains("pid 777") and contains($u))' \
      <<<"$(finding tmux-outside-scope)"
  done
}

@test "with no slot tmux server running, doctor reports nothing about its scope" {
  rm "$STUBS/tmux-answers/pid"
  doctor
  [ "$status" -eq 0 ]
  [ -z "$(finding tmux-outside-scope)" ]
}

@test "doctor reports own-tabs-unrestored when the running server's start-up record shows rexurrect stopped or skipped" {
  local outcome
  for outcome in stopped skipped; do
    startup_record "$REX_STUB_INSTANCE" "$outcome"
    doctor
    [ "$status" -eq 0 ]
    jaq -e --arg o "$outcome" '.severity == "warning" and .value == $o
      and .next_step.command == "systemctl --user restart rex-server.service"' <<<"$(finding own-tabs-unrestored)"
  done
  for outcome in "done" failed; do
    startup_record "$REX_STUB_INSTANCE" "$outcome"
    doctor
    [ -z "$(finding own-tabs-unrestored)" ]
  done
  startup_record 99999999-0000-0000-0000-000000000000 skipped
  doctor
  [ -z "$(finding own-tabs-unrestored)" ]
}

@test "a missing rexurrect is a warning naming its deploy script" {
  rm "$STUBS/rexurrect"
  doctor
  [ "$status" -eq 0 ]
  jaq -e '.severity == "warning" and .next_step.command == "cd ~/dotfiles && scripts/rexurrect-deploy.sh"' \
    <<<"$(finding rexurrect-missing)"
}

@test "from a shell with no XDG_RUNTIME_DIR, doctor still reaches the user manager through the uid's runtime dir" {
  stub systemctl '
printf "systemctl-runtime %s\n" "${XDG_RUNTIME_DIR:-unset}" >>"$CALLS"
[ "$1" = --user ] && shift
case $1 in
  is-active) echo active ;;
  show) echo 4242 ;;
esac'
  run --separate-stderr env -u XDG_RUNTIME_DIR "$AGENT_SLOT_REX" doctor --output json
  [ "$status" -eq 0 ]
  [ "$(grep '^systemctl-runtime ' "$CALLS" | sort -u)" = "systemctl-runtime /run/user/$(id -u)" ]
  called "^agent-slot-runtime /run/user/$(id -u)\$"
}

@test "a Rex server that has not loaded the slot actions, or does not list its actions, is an error finding" {
  printf '{"actions":[{"name":"dev_layout"}]}\n' >"$STUBS/rexdata/actions.json"
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.severity == "error" and .value == "agent_slot_new"
    and .next_step.command == "cd ~/dotfiles && scripts/stow-deploy rex"' <<<"$(finding rex-action-unregistered)"
  rex_fails 'actions --json' 1 'Error: request timed out'
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.severity == "error" and .next_step.command == "rex --autostart=false actions --json"' \
    <<<"$(finding rex-failed)"
  [ -z "$(finding rex-action-unregistered)" ]
}

@test "an agent-slot doctor that outlives its bound or is not installed is a finding marked as the server's" {
  slot_answer doctor 124
  doctor
  [ "$status" -eq 1 ]
  jaq -e '.severity == "error" and .host == "server" and .value == "120"' <<<"$(finding agent-slot-timed-out)"
  export AGENT_SLOT_REX_AGENT_SLOT=$T/no-such/agent-slot
  doctor
  [ "$status" -eq 1 ]
  jaq -e --arg p "$T/no-such/agent-slot" '.severity == "error" and .host == "server" and .value == $p' \
    <<<"$(finding dependency-missing)"
}

@test "a slot tmux server that does not answer is tmux-unresponsive, with the command that probes it" {
  printf '124\n' >"$STUBS/tmux-answers/display-message.rc"
  doctor
  [ "$status" -eq 1 ]
  jaq -e --arg t "$STUBS/tmux" '.severity == "error" and .value == "agent-slots"
    and .next_step.command == "timeout 5 \($t) -L agent-slots list-sessions"' <<<"$(finding tmux-unresponsive)"
}

@test "with the user manager unreachable, doctor names no foreign Rex server from the MainPID it could not read" {
  touch "$STUBS/units/show-fails"
  doctor
  [ -z "$(finding rex-server-foreign)" ]
}

@test "agent-slot's own findings join the helper's, each marked as the server's" {
  slot_answer doctor 1 '{"ok":false,"findings":[{"reason":"git-crypt-key-missing","severity":"error",
    "message":"no key","exit_code":78,"next_step":{"action":"fix-config","command":"op document get k","docs":"d"}}],
    "launch_times":null,"verified_versions":{}}'
  unit rex-tab-numbers.service inactive
  doctor
  [ "$status" -eq 1 ]
  jaq -e '[.findings[] | {reason, host}] == [{reason: "tab-numbers-inactive", host: "server"},
    {reason: "git-crypt-key-missing", host: "server"}]
    and (.findings[1].next_step.command == "op document get k")' <<<"$output"
}

@test "doctor without rex reports dependency-missing for it and still runs every other check" {
  no_rex
  unit rex-tab-numbers.service inactive
  doctor
  [ "$status" -eq 1 ]
  jaq -e '[.findings[].reason] == ["dependency-missing", "tab-numbers-inactive"] and .rex == null' <<<"$output"
  called '^agent-slot doctor --output json$'
}

@test "every doctor finding has the error envelope's shape" {
  printf '0\n' >"$STUBS/units/rex-server.service.pid"
  rex_versions 0.0.2
  unit agent-slot-reconcile.timer inactive
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/rex-server.service\n' >"$STUBS/cgroup.txt"
  startup_record "$REX_STUB_INSTANCE" skipped
  rm "$STUBS/rexurrect"
  doctor
  [ "$(jaq '.findings | length' <<<"$output")" -ge 6 ]
  local f
  while IFS= read -r f; do
    assert_error_shape "$f"
  done < <(jaq -c '.findings[]' <<<"$output")
}

@test "doctor's text output names each finding's severity, reason, and next step" {
  unit rex-tab-numbers.service inactive
  run "$AGENT_SLOT_REX" doctor
  [ "$status" -eq 1 ]
  [[ $output == *"ERROR"$'\t'"server: tab-numbers-inactive: "* ]]
  [[ $output == *$'\tnext: systemctl --user enable --now rex-tab-numbers.service'* ]]
  [[ $output == *"doctor: 1 error(s)"* ]]
}
