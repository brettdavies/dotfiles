#!/usr/bin/env bats
# agent-slot-rex on the Mac: every slot verb a Rex.app action or the operator runs goes to the Linux server's helper
# over ssh, keeping its arguments and exit code, and the verbs that drive the server's own Rex stop with wrong-host.
# uname is stubbed to Darwin, so this runs on Linux CI.
#
# Run: bats tests/agent-slot-rex-macos.bats

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

setup() {
  agent_slot_rex_setup
  export UNAME_STUB=Darwin
}

# forwarded VERB-AND-ARGS: the ssh stub ran the server's helper with exactly these arguments, each word single-quoted,
# without a terminal.
forwarded() {
  local words
  # shellcheck disable=SC2086 # the argument is a word list
  words=$(printf "'%s' " $1)
  called "^ssh-stub -n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR testserver ~/.local/bin/agent-slot-rex ${words% }\$"
}

@test "launch, restore, finish, sweep, and doctor run on the server's helper with the same arguments" {
  local args
  for args in 'launch --repo dotfiles --task fix/x' 'restore' 'restore --tab' 'finish dotfiles/2' \
    'finish --tab --session sess-1 --block blk-2' 'sweep' 'doctor'; do
    # shellcheck disable=SC2086 # each case is its own argument list
    run "$AGENT_SLOT_REX" $args </dev/null
    [ "$status" -eq 0 ]
    forwarded "$args"
  done
  not_called '^(rex|agent-slot|tmux|systemctl) '
}

@test "a forwarded verb keeps --output json, and prints the server's object and exit code as its own" {
  ssh_answer finish 1 "" '{"ok":false,"reason":"task-has-open-pr","exit_code":1}'
  run --separate-stderr "$AGENT_SLOT_REX" finish X/2 --output json </dev/null
  [ "$status" -eq 1 ]
  forwarded 'finish X/2 --output json'
  [ "$stderr" = '{"ok":false,"reason":"task-has-open-pr","exit_code":1}' ]
  ssh_answer sweep 0 '{"ok":true,"verb":"sweep","torn_down":["X/1"]}'
  run --separate-stderr "$AGENT_SLOT_REX" sweep --output json </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"verb":"sweep","torn_down":["X/1"]}' ]
}

@test "the new-agent key in a Mac session forwards launch without --here, since the tab it names is the Mac's" {
  export REX_SESSION=sess-mac REX_BLOCK=blk-mac
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 0 ]
  forwarded 'launch'
}

@test "with a terminal attached, the forward gives the server's helper one, so it can ask and wait for keys" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  run with_tty "$AGENT_SLOT_REX" sweep <<<"q"
  [ "$status" -eq 0 ]
  called "^ssh-stub -t -o BatchMode=yes .* testserver ~/.local/bin/agent-slot-rex 'sweep'\$"
}

@test "with --output json, a forward allocates no terminal, so the server's error object stays on stderr" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  run with_tty "$AGENT_SLOT_REX" finish X/2 --output json <<<"q"
  called "^ssh-stub -n -o BatchMode=yes .* testserver ~/.local/bin/agent-slot-rex 'finish' 'X/2' '--output' 'json'\$"
}

@test "a forwarded argument reaches the server's shell as one literal word, whatever it holds" {
  local task=$'=ls it\'s $(id); `id` ~ "x" *'
  run "$AGENT_SLOT_REX" launch --repo =ls --task "$task" </dev/null
  [ "$status" -eq 0 ]
  local remote shell
  remote=$(tail -1 "$STUBS/ssh-remote.log")
  remote=${remote#\~/.local/bin/agent-slot-rex }
  for shell in "zsh -f" bash; do
    command -v "${shell%% *}" >/dev/null || continue
    # shellcheck disable=SC2086 # the shell carries its own flags
    run $shell -c "printf '%s\n' $remote"
    [ "${#lines[@]}" -eq 5 ]
    [ "${lines[0]}" = launch ]
    [ "${lines[1]}" = --repo ]
    [ "${lines[2]}" = =ls ]
    [ "${lines[3]}" = --task ]
    [ "${lines[4]}" = "$task" ]
  done
}

@test "attach, follow, restore --by, and restore --at-start stop with wrong-host before calling anything" {
  local args
  for args in 'attach X/2 claude' 'follow' 'restore --by push' 'restore --at-start'; do
    # shellcheck disable=SC2086 # each case is its own argument list
    run --separate-stderr "$AGENT_SLOT_REX" $args --output json </dev/null
    [ "$status" -eq 2 ]
    assert_error_shape "$stderr"
    jaq -e '.reason == "wrong-host" and .value == "testserver"
      and .next_step.command == "ssh testserver agent-slot-rex doctor"' <<<"$stderr"
  done
  [ ! -s "$CALLS" ]
}

@test "with ssh failing, a forwarded verb reports server-unreachable with the alias and ssh's own line" {
  touch "$STUBS/ssh/unreachable"
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json </dev/null
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "server-unreachable" and .value == "testserver" and .recovery.retryable == true
    and (.message | contains("Connection refused"))
    and .next_step.command == "ssh testserver agent-slot-rex doctor"' <<<"$stderr"
}

@test "a server with no helper installed is dependency-missing, naming the deploy" {
  ssh_answer doctor 127 "" "zsh:1: no such file or directory: /home/u/.local/bin/agent-slot-rex"
  run --separate-stderr "$AGENT_SLOT_REX" doctor --output json </dev/null
  [ "$status" -eq 78 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "dependency-missing" and .value == "testserver"
    and .next_step.command == "ssh testserver '"'"'cd ~/dotfiles && scripts/stow-deploy local'"'"'"' <<<"$stderr"
}

@test "--help stays on the Mac" {
  run "$AGENT_SLOT_REX" sweep --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot-rex sweep"* ]]
  [ ! -s "$CALLS" ]
}
