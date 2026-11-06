#!/usr/bin/env bats
# agent-slot resume --model: a live slot's model changes through the command line of a restarted Claude, never through
# the running one, and only while its agent is idle.
#
# Run: bats tests/agent-slot-resume-model.bats
#
# Fixtures only: tmux is a stub that records its calls, except in the one test that runs a scratch tmux server on a
# socket of its own, and the agent is a stand-in process that claude agents lists. Resuming without --model is held by
# agent-slot-prune.bats and agent-slot-foreign-head.bats.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  set_model sonnet
  SETTINGS_BEFORE=$(sha256sum <"$AGENT_SLOT_CLAUDE_SETTINGS")
  AGENT=
  REAL_SOCKET=
}

teardown() {
  [ -z "$REAL_SOCKET" ] || "$REAL_TMUX" -L "$REAL_SOCKET" kill-server 2>/dev/null || true
  stop_spawned
  assert_no_leaks
}

OPUS_LINE='claude --dangerously-skip-permissions --settings '\''{"idleCompaction":false}'\'' --model claude-opus-5-5 --effort xhigh --resume s1 -n t1'
SONNET_LINE='CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=1 claude --dangerously-skip-permissions --settings '\''{"idleCompaction":false}'\'' --model claude-sonnet-5-5 --effort xhigh --advisor opus --resume s1 -n t1'
# What the stand-in Claude logs: the words the shell passes it, with the line's quoting gone.
OPUS_ARGS=${OPUS_LINE#claude }
OPUS_ARGS=${OPUS_ARGS//\'/}

record() { jaq -r "$1" "$SLOT/.git/agent-slot.json"; }

set_model() {
  jaq --arg m "$1" '.model = $m' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
}

typed() { cat "$STUBS/typed-repoa-1"; }

# listed STATE PID: claude agents lists one session in the slot, in STATE.
listed() {
  jaq -n -c --arg cwd "$SLOT" --argjson pid "$2" --arg state "$1" \
    '[{pid: $pid, cwd: $cwd, status: $state, sessionId: "s1"}]' >"$STUBS/claude-agents.json"
}

# agent STATE: a stand-in for the slot's Claude that claude agents lists in STATE. It notes in the calls log when it is
# stopped, so the order of stopping and typing can be read there.
agent() {
  spawn bash -c "trap 'echo agent-stopped >>\"$CALLS\"; exit 0' TERM; sleep 120 & wait" </dev/null >/dev/null 2>&1 3>&-
  AGENT=$!
  listed "$1" "$AGENT"
}

alive() { kill -0 "$AGENT" 2>/dev/null; }

resume_model() { run --separate-stderr "$AGENT_SLOT" resume repoa/1 "$@" --output json; }

# line_of PATTERN: the number of the first line of the calls log that matches.
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }

# wait_for_lines FILE N: waits up to 5 s for the file to hold N lines.
wait_for_lines() {
  local i
  for ((i = 0; i < 50; i++)); do
    [ -f "$1" ] && [ "$(wc -l <"$1")" -ge "$2" ] && return 0
    sleep 0.1
  done
  echo "$1 never reached $2 lines"
  return 1
}

# tmux_wrapper: puts a tmux in front of the stub that fails send-keys while $STUBS/send-keys-fails exists, hangs it while
# $STUBS/send-keys-hangs exists, fails kill-session while $STUBS/kill-fails exists, and fails copy-mode while
# $STUBS/copy-mode-fails exists.
tmux_wrapper() {
  mv "$STUBS/tmux" "$STUBS/tmux-base"
  cat >"$STUBS/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *send-keys*)
    [ ! -e '$STUBS/send-keys-fails' ] || { echo 'tmux: server exited unexpectedly' >&2; exit 1; }
    [ ! -e '$STUBS/send-keys-hangs' ] || exec sleep 60 ;;
  *kill-session*) [ ! -e '$STUBS/kill-fails' ] || { echo 'tmux: server exited unexpectedly' >&2; exit 1; } ;;
  *copy-mode*) [ ! -e '$STUBS/copy-mode-fails' ] || { echo 'tmux: server exited unexpectedly' >&2; exit 1; } ;;
esac
exec '$STUBS/tmux-base' "\$@"
EOF
  chmod +x "$STUBS/tmux"
}

# real_pane [SHELL...]: with REAL_TMUX set, the three sessions of repoa/1 on a scratch tmux server under $T, each a shell
# (bash --norc --noprofile by default) with a fake claude first on its PATH. It types `claude first` into the Claude
# session, waits for it to run, and lists it idle. The fake logs its arguments to $T/pane-claude.log and its pid to
# $T/pane-claude.pid, and copies what it reads from its terminal to $T/claude-input, which stays empty while nothing is
# typed into it. Sets OLD to that pid.
real_pane() {
  REAL_SOCKET=agent-slot-test-model
  export TMUX_TMPDIR=$T
  mkdir -p "$T/bin"
  cat >"$T/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'$T/pane-claude.log'
echo \$\$ >'$T/pane-claude.pid'
exec cat >>'$T/claude-input'
EOF
  chmod +x "$T/bin/claude"
  local name
  local -a shell=("$@")
  ((${#shell[@]} > 0)) || shell=(bash --norc --noprofile)
  for name in repoa-1 repoa-1-files repoa-1-git; do
    "$REAL_TMUX" -L "$REAL_SOCKET" -f "$AGENT_SLOT_TMUX_CONF" new-session -d -s "$name" -c "$SLOT" \
      "env PATH=$T/bin:$PATH ${shell[*]}"
  done
  export AGENT_SLOT_TMUX=$REAL_TMUX AGENT_SLOT_TMUX_SOCKET=$REAL_SOCKET
  "$REAL_TMUX" -L "$REAL_SOCKET" send-keys -t =repoa-1: -l 'claude first'
  "$REAL_TMUX" -L "$REAL_SOCKET" send-keys -t =repoa-1: Enter
  wait_for_lines "$T/pane-claude.log" 1
  OLD=$(cat "$T/pane-claude.pid")
  listed idle "$OLD"
}

pane_in_mode() { "$REAL_TMUX" -L "$REAL_SOCKET" display-message -p -t =repoa-1: '#{pane_in_mode}'; }

@test "an idle Claude is ended, then started again in its own pane on the new model, resuming its conversation" {
  agent idle
  resume_model --model opus
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.key == "repoa/1" and .model == "opus" and .previous_model == "sonnet" and .restarted == true
    and .started == []' <<<"$output"
  [ "$(record .model)" = opus ]
  [ "$(typed)" = "$OPUS_LINE" ]
  run ! alive
  stopped=$(line_of '^agent-stopped$')
  typed_at=$(line_of 'send-keys -t =repoa-1: -l ')
  [ -n "$stopped" ] && [ -n "$typed_at" ] && [ "$stopped" -lt "$typed_at" ]
}

@test "a slot goes to Sonnet with Opus as its advisor, and back to Opus without it" {
  set_model opus
  agent idle
  resume_model --model sonnet
  [ "$status" -eq 0 ]
  jaq -e '.model == "sonnet" and .previous_model == "opus" and .restarted == true' <<<"$output"
  [ "$(typed)" = "$SONNET_LINE" ]
  agent idle
  resume_model --model opus
  [ "$status" -eq 0 ]
  [ "$(typed)" = "$OPUS_LINE" ]
}

@test "the model changes only on the restarted command line: no /model is typed and no Claude settings file is written" {
  agent idle
  resume_model --model opus
  [ "$status" -eq 0 ]
  jaq -e '.restarted == true' <<<"$output"
  run grep -c -- '/model' "$CALLS"
  [ "$output" = 0 ]
  [ "$(sha256sum <"$AGENT_SLOT_CLAUDE_SETTINGS")" = "$SETTINGS_BEFORE" ]
  [ "$(jaq -c . "$AGENT_SLOT_CLAUDE_STATE")" = '{"projects":{}}' ]
}

@test "a busy or waiting agent is never interrupted: resume refuses, says who acts, and changes nothing" {
  local st action
  for st in busy waiting; do
    action=retry
    [ "$st" = busy ] || action=ask-operator
    agent "$st"
    resume_model --model opus
    [ "$status" -eq 1 ]
    assert_error_shape "$stderr"
    jaq -e --arg st "$st" --arg action "$action" '.reason == "agent-busy" and .exit_code == 1 and .value == $st
      and (.message | contains("once the agent is idle")) and (.message | contains("agent-slot list --output json"))
      and .recovery.side_effects == "none" and .recovery.retryable == true
      and .next_step.action == $action and .next_step.command == "agent-slot resume repoa/1 --model opus"' <<<"$stderr"
    alive
  done
  [ "$(record .model)" = sonnet ]
  run ! grep -q '^agent-stopped$' "$CALLS"
  run ! grep -q 'send-keys' "$CALLS"
}

@test "an agent whose state cannot be read is not ended either" {
  agent idle
  echo 'not json' >"$STUBS/claude-agents.json"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "agent-busy" and .value == "unknown" and (.message | contains("claude agents --json failed"))
    and .recovery.side_effects == "none" and .next_step.action == "ask-operator"' <<<"$stderr"
  alive
  [ "$(record .model)" = sonnet ]
}

@test "a resume run by the slot's own agent is told to ask from another session" {
  listed busy "$$"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "agent-busy" and .value == "own-agent" and .next_step.action == "ask-operator"
    and (.message | contains("inside the slot'"'"'s own agent")) and (.message | contains("another session"))' <<<"$stderr"
  [ "$(record .model)" = sonnet ]
}

@test "a resume the slot's own agent left running in the background is refused although that agent is listed idle" {
  spawn bash -c 'while [ ! -e "$1/go" ]; do sleep 0.1; done
    "$0" resume repoa/1 --model opus --output json >"$1/out" 2>"$1/err"; echo $? >"$1/status"; exec sleep 120' \
    "$AGENT_SLOT" "$T" </dev/null >/dev/null 2>&1 3>&-
  AGENT=$!
  listed idle "$AGENT"
  touch "$T/go"
  wait_for_lines "$T/status" 1
  [ "$(cat "$T/status")" = 1 ]
  jaq -e '.reason == "agent-busy" and .value == "own-agent" and .next_step.action == "ask-operator"
    and (.message | contains("inside the slot'"'"'s own agent"))' "$T/err"
  alive
  [ "$(record .model)" = sonnet ]
  run ! grep -q 'send-keys' "$CALLS"
}

@test "an idle Claude that still runs a Bash command is not ended, and neither is the command" {
  spawn bash -c "trap 'echo agent-stopped >>\"$CALLS\"; exit 0' TERM; bash -c 'sleep 120 && pwd -P >| $T/claude-0abc12-cwd' & wait" \
    </dev/null >/dev/null 2>&1 3>&-
  AGENT=$!
  listed idle "$AGENT"
  local i
  for ((i = 0; i < 30; i++)); do
    pgrep -P "$AGENT" >/dev/null && break
    sleep 0.1
  done
  local job
  job=$(pgrep -P "$AGENT")
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e --arg job "$job" '.reason == "agent-busy" and (.value | startswith($job + " sleep 120")) and .next_step.action == "retry"
    and (.message | contains("1 background job")) and (.message | contains("PID " + $job))
    and (.message | contains("changes nothing"))
    and (.message | contains("list --output json") | not) and .recovery.side_effects == "none"' <<<"$stderr"
  alive
  pgrep -P "$AGENT" >/dev/null
  [ "$(record .model)" = sonnet ]
  run ! grep -q 'send-keys' "$CALLS"
}

@test "with no Claude running, the model is recorded and nothing is typed" {
  resume_model --model opus
  [ "$status" -eq 0 ]
  jaq -e '.model == "opus" and .previous_model == "sonnet" and .restarted == false and .started == []' <<<"$output"
  [ "$(record .model)" = opus ]
  [ ! -e "$STUBS/typed-repoa-1" ]
}

@test "a Claude session that is gone comes back on the new model, not the one the record held before" {
  printf 'repoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  resume_model --model opus
  [ "$status" -eq 0 ]
  jaq -e '.model == "opus" and .restarted == false and .started == ["repoa-1"]' <<<"$output"
  [ "$(typed)" = "$OPUS_LINE" ]
}

@test "naming the model the slot already runs changes nothing, however busy its agent is" {
  agent busy
  resume_model --model sonnet
  [ "$status" -eq 0 ]
  jaq -e '.model == "sonnet" and .previous_model == "sonnet" and .restarted == false' <<<"$output"
  alive
  run ! grep -q 'claude agents' "$CALLS"
  [ ! -e "$STUBS/typed-repoa-1" ]
  jaq 'del(.model)' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  resume_model --model opus
  [ "$status" -eq 0 ]
  jaq -e '.model == "opus" and .previous_model == "opus" and .restarted == false' <<<"$output"
  alive
}

@test "resume without --model asks Claude nothing about the agent" {
  agent busy
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e 'has("model") | not' <<<"$output"
  run ! grep -q 'claude agents' "$CALLS"
  [ "$(record .model)" = sonnet ]
}

@test "in text, resume says the model it switched to and that Claude was restarted" {
  agent idle
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --model opus
  [ "$status" -eq 0 ]
  [[ $output == *"repoa/1: every session was already running; model sonnet to opus, restarted its Claude"* ]]
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --model opus
  [[ $output == *"repoa/1: every session was already running; model opus unchanged"* ]]
  set_model sonnet
  echo '[]' >"$STUBS/claude-agents.json"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --model opus
  [[ $output == *"repoa/1: every session was already running; model sonnet to opus, no running Claude to restart"* ]]
  set_model sonnet
  printf 'repoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --model opus
  [[ $output == *"started repoa-1; model sonnet to opus, its Claude started on it"* ]]
}

@test "a model outside opus and sonnet, a missing value, and a repeated flag are usage errors before anything changes" {
  agent idle
  resume_model --model haiku
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "haiku" and .message == "--model takes opus or sonnet"' <<<"$stderr"
  resume_model --model
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "--model" and .message == "--model needs a value: opus or sonnet"' <<<"$stderr"
  resume_model --model ''
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "--model" and .message == "--model needs a value: opus or sonnet"' <<<"$stderr"
  resume_model --model opus --model sonnet
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .message == "resume takes one --model"' <<<"$stderr"
  alive
  [ "$(record .model)" = sonnet ]
}

@test "a flag resume does not know, such as --model=opus, is named as unknown, not blamed on the slot" {
  resume_model --model=opus
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "--model=opus" and .message == "unknown option --model=opus"' <<<"$stderr"
  resume_model --mdoel opus
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .message == "unknown option --mdoel"' <<<"$stderr"
  [ "$(record .model)" = sonnet ]
}

@test "the flag may come before the slot, and the slot is still required" {
  run --separate-stderr "$AGENT_SLOT" resume --model opus repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .model == "opus"' <<<"$output"
  run --separate-stderr "$AGENT_SLOT" resume --model opus --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and (.message | startswith("resume takes one slot"))' <<<"$stderr"
}

@test "launch reads the model resume wrote: a repeat naming the old one is refused, the new one answered" {
  jaq '.request_id = "r-1"' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  resume_model --model opus
  [ "$status" -eq 0 ]
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-1 --model sonnet --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "model-differs" and (.message | contains("repoa/1 already holds this work and runs on opus"))' \
    <<<"$stderr"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-1 --model opus --output json
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1"' <<<"$output"
}

@test "when the new Claude cannot be typed in, the Claude session is dropped so the next resume starts it on the new model" {
  tmux_wrapper
  agent idle
  touch "$STUBS/send-keys-fails"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "tmux-failed" and .recovery.side_effects == "partial" and .recovery.retryable == true
    and .value == "repoa-1" and (.message | startswith("ended the Claude in repoa-1, but could not type the new line"))
    and (.message | contains("the record names opus")) and (.message | contains("was dropped"))
    and .next_step.command == "agent-slot resume repoa/1"' <<<"$stderr"
  log=$(jaq -r .log <<<"$stderr")
  [ -f "$log" ]
  grep -q 'server exited unexpectedly' "$log"
  run ! alive
  [ "$(record .model)" = opus ]
  run ! grep -qxF repoa-1 "$STUBS/tmux-sessions"
  rm "$STUBS/send-keys-fails"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.started == ["repoa-1"]' <<<"$output"
  [ "$(typed)" = "$OPUS_LINE" ]
}

@test "when tmux does not answer while the new line is typed, the error says the Claude was ended and how to bring it back" {
  tmux_wrapper
  agent idle
  touch "$STUBS/send-keys-hangs"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "tmux-unresponsive" and .recovery.side_effects == "partial"
    and (.message | startswith("ended the Claude in repoa-1, but tmux did not answer"))
    and (.message | contains("the record names opus")) and .next_step.command == "agent-slot resume repoa/1"' <<<"$stderr"
  run ! alive
}

@test "when the Claude session cannot be dropped either, the error gives the command that drops it" {
  tmux_wrapper
  agent idle
  touch "$STUBS/send-keys-fails" "$STUBS/kill-fails"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "tmux-failed" and .recovery.side_effects == "partial"
    and (.message | contains("could not be dropped")) and (.message | contains("kill-session -t =repoa-1"))
    and (.next_step.command | contains("kill-session -t =repoa-1"))' <<<"$stderr"
  grep -qxF repoa-1 "$STUBS/tmux-sessions"
}

@test "on a real tmux server, the new Claude is typed into the pane once the old one has exited" {
  REAL_TMUX=$(command -v tmux) || skip "tmux is not installed"
  real_pane
  resume_model --model opus
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.restarted == true and .started == []' <<<"$output"
  wait_for_lines "$T/pane-claude.log" 2
  [ "$(sed -n 1p "$T/pane-claude.log")" = first ]
  [ "$(sed -n 2p "$T/pane-claude.log")" = "$OPUS_ARGS" ]
  run ! kill -0 "$OLD"
  [ "$(cat "$T/pane-claude.pid")" != "$OLD" ]
  [ ! -s "$T/claude-input" ]
}

@test "with the pane in copy mode, as when the operator is scrolled back, the new line still reaches the shell" {
  REAL_TMUX=$(command -v tmux) || skip "tmux is not installed"
  real_pane
  "$REAL_TMUX" -L "$REAL_SOCKET" copy-mode -t =repoa-1:
  [ "$(pane_in_mode)" = 1 ]
  resume_model --model opus
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.restarted == true' <<<"$output"
  wait_for_lines "$T/pane-claude.log" 2
  [ "$(sed -n 2p "$T/pane-claude.log")" = "$OPUS_ARGS" ]
  [ "$(pane_in_mode)" = 0 ]
  [ ! -s "$T/claude-input" ]
}

@test "the new line reaches a zsh at its prompt as well as a bash" {
  REAL_TMUX=$(command -v tmux) || skip "tmux is not installed"
  command -v zsh >/dev/null || skip "zsh is not installed"
  real_pane zsh -f
  resume_model --model opus
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  wait_for_lines "$T/pane-claude.log" 2
  [ "$(sed -n 2p "$T/pane-claude.log")" = "$OPUS_ARGS" ]
  [ ! -s "$T/claude-input" ]
}

@test "a tmux that cannot leave copy mode stops the resume before the Claude is ended or the record changes" {
  tmux_wrapper
  agent idle
  touch "$STUBS/copy-mode-fails"
  resume_model --model opus
  [ "$status" -eq 1 ]
  jaq -e '.reason == "tmux-failed" and .recovery.side_effects == "none" and .recovery.retryable == true
    and .value == "repoa-1" and (.message | contains("its Claude was not ended"))
    and .next_step.command == "agent-slot resume repoa/1 --model opus"' <<<"$stderr"
  alive
  [ "$(record .model)" = sonnet ]
  run ! grep -q 'send-keys' "$CALLS"
}

@test "resume --help documents --model, the refusal, and the fields the flag adds" {
  run "$AGENT_SLOT" resume --help
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "usage: agent-slot resume <repo>/<N> [--model (opus | sonnet)] [--output json]" ]
  [[ $output == *"agent-busy"* ]]
  [[ $output == *"previous_model"* ]]
  [[ $output == *"restarted"* ]]
}

@test "schema lists agent-busy as a retryable failure" {
  run --separate-stderr "$AGENT_SLOT" schema --output json
  [ "$status" -eq 0 ]
  jaq -e '.reasons[] | select(.reason == "agent-busy") | .exit_code == 1 and .retryable == true and .action == "retry"' \
    <<<"$output"
}
