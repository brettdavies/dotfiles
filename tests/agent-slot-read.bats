#!/usr/bin/env bats
# agent-slot's read verbs: repos, list, and whoami.
#
# Run: bats tests/agent-slot-read.bats

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
}

@test "repos lists the clones with an origin and nothing else" {
  prime alpha
  prime beta
  git init -q "$AGENT_SLOT_DEV/no-origin"
  git -C "$AGENT_SLOT_DEV/alpha" worktree add -q "$AGENT_SLOT_DEV/a-worktree"

  run --separate-stderr "$AGENT_SLOT" repos --output json
  [ "$status" -eq 0 ]
  [ "$(jaq -c '[.repos[].name]' <<<"$output")" = '["alpha","beta"]' ]
  jaq -e --arg p "$AGENT_SLOT_DEV/alpha" '.repos[0].prime == $p and (.repos[0].origin | endswith("alpha.git"))' \
    <<<"$output"
}

@test "repos also lists a prime named in AGENT_SLOT_EXTRA_PRIMES" {
  prime alpha
  git clone -q "$T/origins/alpha.git" "$T/outside"
  export AGENT_SLOT_EXTRA_PRIMES=$T/outside
  run --separate-stderr "$AGENT_SLOT" repos --output json
  [ "$(jaq -c '[.repos[].name]' <<<"$output")" = '["alpha","outside"]' ]
}

@test "list with no slot root returns an empty list and exits 0" {
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '.ok == true and .slots == []' <<<"$output"
  [ ! -e "$AGENT_SLOT_ROOT" ]
}

@test "list reports a slot whose tmux session is missing as dormant" {
  slot repoa 1
  echo other-session >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '.slots[0].key == "repoa/1" and .slots[0].state == "dormant" and .slots[0].sessions.claude == false' \
    <<<"$output"
}

@test "list reports a live slot as active with its agent's state from claude agents" {
  slot repoa 1 '{"task": "fix-login"}'
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' >"$STUBS/tmux-sessions"
  jaq -n -c --arg cwd "$AGENT_SLOT_ROOT/repoa/1/src" \
    '[{pid: 999999, cwd: $cwd, kind: "interactive", sessionId: "s1", status: "busy"}]' >"$STUBS/claude-agents.json"
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '.slots[0] | .state == "active" and .agent == "busy" and .task == "fix-login" and .sessions.git == true' \
    <<<"$output"
}

@test "list reports the slot's branch and its stored needs-you blockers" {
  slot repoa 2 '{"last_check": {"blockers": [{"code": "unpushed-commits", "count": 1, "message": "1 unpushed commit"}]}}'
  git -C "$AGENT_SLOT_ROOT/repoa/2" checkout -q -b feat/topic
  echo repoa-2 >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0] | .branch == "feat/topic" and .needs_you[0].code == "unpushed-commits" and .agent == "absent"' \
    <<<"$output"
  run "$AGENT_SLOT" list
  [[ "$output" == *"repoa/2"*"needs you: 1 unpushed commit"* ]]
}

@test "list labels a slot by its name, else its task, else its branch" {
  slot repoa 1 '{"task": "fix-login", "name": "repoa-pr7-fix-login"}'
  slot repoa 2 '{"task": "fix-login"}'
  slot repoa 3
  git -C "$AGENT_SLOT_ROOT/repoa/3" checkout -q -b feat/topic
  printf 'repoa-1\nrepoa-2\nrepoa-3\n' >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '[.slots[].label_name] == ["repoa-pr7-fix-login", "fix-login", "feat/topic"]' <<<"$output"
  run "$AGENT_SLOT" list
  [[ ${lines[0]} == *$'\trepoa-pr7-fix-login' ]]
  [[ ${lines[2]} == *$'\tfeat/topic' ]]
}

@test "list counts two Claude sessions in one slot as unknown" {
  slot repoa 1
  echo repoa-1 >"$STUBS/tmux-sessions"
  jaq -n -c --arg cwd "$AGENT_SLOT_ROOT/repoa/1" \
    '[{pid: 1, cwd: $cwd, status: "idle"}, {pid: 2, cwd: $cwd, status: "idle"}]' >"$STUBS/claude-agents.json"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0].agent == "unknown" and (.slots[0].agent_detail | test("2 Claude sessions"))' <<<"$output"
}

@test "list counts a failed claude agents lookup as unknown" {
  slot repoa 1
  echo repoa-1 >"$STUBS/tmux-sessions"
  stub claude 'exit 1'
  run --separate-stderr "$AGENT_SLOT" list --output json
  [ "$status" -eq 0 ]
  jaq -e '.slots[0].agent == "unknown"' <<<"$output"
}

@test "list lists a claimed slot that has no clone yet as setting-up" {
  mkdir -p "$AGENT_SLOT_ROOT/repoa"
  echo '{"schema": "dotfiles.agent-slot/1", "repo": "repoa", "slot": 3, "state": "setting-up"}' \
    >"$AGENT_SLOT_ROOT/repoa/.3.claim.json"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0].key == "repoa/3" and .slots[0].state == "setting-up"' <<<"$output"
}

@test "whoami from a nested directory of a slot returns that slot's record" {
  slot repoa 4 '{"task": "t4"}'
  mkdir -p "$AGENT_SLOT_ROOT/repoa/4/src/deep"
  cd "$AGENT_SLOT_ROOT/repoa/4/src/deep"
  run --separate-stderr "$AGENT_SLOT" whoami --output json
  [ "$status" -eq 0 ]
  jaq -e --arg p "$AGENT_SLOT_ROOT/repoa/4" '.slot.key == "repoa/4" and .slot.task == "t4" and .slot.path == $p' \
    <<<"$output"
}

@test "whoami resolves a slot reached through a symlink to the slot root" {
  slot repoa 1
  ln -s "$AGENT_SLOT_ROOT" "$T/link"
  run --separate-stderr "$AGENT_SLOT" whoami --path "$T/link/repoa/1" --output json
  [ "$status" -eq 0 ]
  jaq -e '.slot.key == "repoa/1"' <<<"$output"
}

@test "whoami from a prime checkout is not-in-slot, exit 1, with a JSON error on stderr" {
  prime alpha
  cd "$AGENT_SLOT_DEV/alpha"
  run --separate-stderr "$AGENT_SLOT" whoami --output json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  jaq -e --arg p "$AGENT_SLOT_DEV/alpha" '.reason == "not-in-slot" and .value == $p' <<<"$stderr"
}

# start_in DIR VAR=VALUE... COMMAND...: a detached COMMAND with its working directory in DIR and the given environment,
# as a daemon a pane's shell started (powerlevel10k's gitstatusd) or a shell opened by hand. Returns once COMMAND runs,
# since /proc shows the first VAR=VALUE in its environment only from COMMAND's own exec, and fails when it never does.
start_in() {
  local dir=$1 n=0
  shift
  (cd "$dir" && exec setsid /usr/bin/env "$@" </dev/null >/dev/null 2>&1) &
  SLEEPER=$!
  until grep -qsazxF "$1" "/proc/$SLEEPER/environ" || ((n++ > 50)); do sleep 0.1; done
  grep -qsazxF "$1" "/proc/$SLEEPER/environ" || {
    echo "start_in: $* never ran" >&2
    return 1
  }
}

@test "gitstatusd that a slot pane's prompt started counts as the slot's own, by the pane it names" {
  slot repoa 1
  echo repoa-1 >"$STUBS/tmux-sessions"
  printf 'repoa-1 999991 %%11\nrepoa-1-files 999992 %%12\nrepoa-1-git 999993 %%13\n' >"$STUBS/tmux-panes"
  start_in "$AGENT_SLOT_ROOT/repoa/1" TMUX="/tmp/tmux-test/agent-slot-test,1,0" TMUX_PANE=%12 \
    "$(gitstatusd_standin)" -e 'sleep 120'
  run --separate-stderr "$AGENT_SLOT" list --output json
  kill "$SLEEPER"
  jaq -e '.slots[0].agent == "absent"' <<<"$output"
}

@test "gitstatusd in the slot whose environment names another tmux server makes the agent state unknown" {
  slot repoa 1
  echo repoa-1 >"$STUBS/tmux-sessions"
  printf 'repoa-1 999991 %%11\n' >"$STUBS/tmux-panes"
  start_in "$AGENT_SLOT_ROOT/repoa/1" TMUX="/tmp/tmux-1000/default,1,0" TMUX_PANE=%11 \
    "$(gitstatusd_standin)" -e 'sleep 120'
  run --separate-stderr "$AGENT_SLOT" list --output json
  kill "$SLEEPER"
  jaq -e --arg pid "$SLEEPER" '.slots[0].agent == "unknown" and (.slots[0].agent_detail | contains($pid))' <<<"$output"
}

@test "a process that exits before its command and environment are read leaves nothing on stderr" {
  run --separate-stderr bash -c 'source "$1"; _agent_pane_daemon 2147483647 "%1"' _ \
    "$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/agentstate.sh"
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
}
