#!/usr/bin/env bats
# agent-slot-rex on the Linux server, against stubbed rex, agent-slot, tmux, and ps: launch, attach, the reconcile, and
# the settings every verb runs under.
#
# Run: bats tests/agent-slot-rex.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

setup() {
  agent_slot_rex_setup
}

LAUNCHED='{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"launch","created":true,"key":"X/3","repo":"X","slot":3,
  "path":"/srv/slots/X/3","task":null,"request_id":"r","session_id":"s","base":"main","trust_prompt_expected":false}'

# A Rex terminal in session sess-a, named LABEL, whose window win-a holds block blk-a; WINDOWS-JSON, when given, is every
# window of the session, win-a among them, in the shape `session` takes.
in_rex_session() {
  local windows='[{"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  session sess-a "$1" "${2:-$windows}"
  export REX_SESSION=sess-a REX_BLOCK=blk-a
}

# --- help and usage ---------------------------------------------------------------------------------------------------

@test "every verb answers --help with a usage line and an example" {
  local verb
  for verb in launch prime attach restore sweep finish doctor; do
    run "$AGENT_SLOT_REX" "$verb" --help
    [ "$status" -eq 0 ]
    [[ ${lines[0]} == "usage: agent-slot-rex $verb"* ]]
    [[ $output == *"example: agent-slot-rex $verb"* ]]
  done
}

@test "an unknown verb is a usage error with the error shape" {
  run --separate-stderr "$AGENT_SLOT_REX" frobnicate --output json
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "usage" and .value == "frobnicate"' <<<"$stderr"
}

@test "with no usable jaq or jq, --output json still gets a dependency-missing error object" {
  run --separate-stderr env AGENT_SLOT_JQ="$T/no-such-jq" "$AGENT_SLOT_REX" doctor --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "dependency-missing" and .verb == "agent-slot-rex" and .exit_code == 78' <<<"$stderr"
}

@test "--output before the verb is refused with a usage error that says where it goes" {
  run --separate-stderr "$AGENT_SLOT_REX" --output json finish repo/1
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and (.message | contains("after the verb"))' <<<"$stderr"
}

# --- launch -----------------------------------------------------------------------------------------------------------

@test "launch from the repo's session launches it, relabels and lays out its tab, and becomes the attach" {
  in_rex_session X
  repos X Y
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^agent-slot launch X --request-id [0-9a-f-]{36} --requested-at [0-9]+\.[0-9]+ --opened-at [0-9]+\.[0-9]+ --output json$'
  called '^rex window rename -s sess-a win-a X/3$'
  called '^rex do agent_slot_layout -s sess-a -b blk-a key=X/3 block=blk-a$'
  called '^agent-slot-rex attach X/3 claude$'
  [ "$(tail -1 "$CALLS")" = "agent-slot-rex attach X/3 claude" ]
}

@test "launch adds trust needed to the label when the server expects the trust dialog" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$(jaq -c '. + {task: "fix/y", label_name: "fix/y", trust_prompt_expected: true}' <<<"$LAUNCHED")"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-a win-a X/3 · fix/y · trust needed$'
}

@test "launch labels the tab with the label the server gives the slot, its name over its task" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$(jaq -c '. + {task: "fix/y", name: "X-pr7-fix-y", label_name: "X-pr7-fix-y"}' <<<"$LAUNCHED")"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-a win-a X/3 · X-pr7-fix-y$'
}

@test "launch labels the tab by the slot's task when the server's answer has no label_name" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$(jaq -c '. + {task: "fix/y"}' <<<"$LAUNCHED")"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-a win-a X/3 · fix/y$'
}

@test "after a launch a sweep tab opens in the agent-slots session, and the session is made when missing" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called "^rex new agent-slots --window sweep --json -- $STUBS/agent-slot-rex sweep$"
  : >"$CALLS"
  run "$AGENT_SLOT_REX" launch --here
  called "^rex window new -s sess-agent-slots sweep --focus=false --json -- $STUBS/agent-slot-rex sweep$"
}

@test "after a launch with a sweep tab already open, that tab sweeps again and no second one opens" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$LAUNCHED"
  session sess-agent-slots agent-slots '[{"window_id": "w-sweep", "label": "sweep", "blocks": ["b-sweep"]}]'
  runs b-sweep 301 "bash $STUBS/agent-slot-rex sweep"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^rex send -s sess-agent-slots -b b-sweep r$'
  not_called '^rex (new agent-slots|window new -s sess-agent-slots)'
}

@test "a tab in the agent-slots session that is not a running sweep gets no keys, and a sweep tab opens" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$LAUNCHED"
  session sess-agent-slots agent-slots '[{"window_id": "w-restore", "label": "sweep", "blocks": ["b-restore"]}]'
  runs b-restore 302 "bash $STUBS/agent-slot-rex restore"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  not_called '^rex send '
  called "^rex window new -s sess-agent-slots sweep --focus=false --json -- $STUBS/agent-slot-rex sweep$"
}

@test "from a session that names no repo and with no terminal, launch refuses with repo-required" {
  in_rex_session gentle-sierra
  repos X Y
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json </dev/null
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "repo-required" and .next_step.command == "agent-slot-rex launch --repo <name>"
    and .value == "gentle-sierra" and (.message | contains("X, Y"))' <<<"$stderr"
  not_called '^agent-slot launch'
}

@test "from a session that names no repo, a terminal gets a numbered list and the launch moves to the repo's session" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  in_rex_session gentle-sierra
  repos X Y
  run with_tty "$AGENT_SLOT_REX" launch --here <<<"2"
  [ "$status" -eq 0 ]
  [[ $output == *"1) X"* && $output == *"2) Y"* ]]
  called "^rex new Y --window Y · launching --json -- $STUBS/agent-slot-rex launch --here --repo Y$"
  not_called '^agent-slot launch'
}

# --- the new-agent key and the repo's prime ---------------------------------------------------------------------------

@test "in a repo session with no prime tab, the key's tab becomes the prime: renamed for it, moved first, then attached" {
  in_rex_session X
  repos X
  primes X 'X Prime'
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^tmux has-session -t =X Prime$'
  called '^rex window rename -s sess-a win-a X Prime$'
  called '^rex window move -s sess-a win-a --index 1$'
  [ "$(tail -1 "$CALLS")" = "agent-slot-rex prime X" ]
  not_called '^agent-slot launch'
}

@test "in a repo session whose prime is attached in one of its tabs, the key starts a slot with no picker" {
  in_rex_session X '[{"window_id": "win-p", "label": "1: X Prime", "blocks": ["blk-p"]},
    {"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  repos X
  primes X 'X Prime'
  on_tty blk-p 501 pts/9
  prime_clients pts/9
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 0 ]
  called '^tmux list-clients -t =X Prime -F #\{client_tty\}$'
  called '^agent-slot launch X --request-id '
  [ "$(tail -1 "$CALLS")" = "agent-slot-rex attach X/3 claude" ]
  not_called '^rex window move'
  not_called '^agent-slot-rex prime'
}

@test "the prime tab is known by its tmux client: a renamed tab counts, and a tab only labelled as the prime does not" {
  in_rex_session X '[{"window_id": "win-f", "label": "1: X Prime", "blocks": ["blk-f"]},
    {"window_id": "win-r", "label": "2: notes", "blocks": ["blk-r"]},
    {"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  repos X
  primes X 'X Prime'
  on_tty blk-f 501 pts/4
  on_tty blk-r 502 pts/3
  slot_answer launch 0 "$LAUNCHED"
  prime_clients pts/3
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot launch X '
  not_called '^agent-slot-rex prime'
  : >"$CALLS"
  prime_clients pts/8
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 0 ]
  called '^rex window move -s sess-a win-a --index 1$'
  [ "$(tail -1 "$CALLS")" = "agent-slot-rex prime X" ]
  not_called '^agent-slot launch'
}

@test "with its prime's tmux session not running, the key's tab says so, holds, and starts nothing" {
  in_rex_session X
  repos X
  primes X 'X Prime'
  tmux_default_answer has-session 1
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json </dev/null
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "prime-not-running" and .value == "X Prime"
    and .next_step.command == "tmux has-session -t '"'"'=X Prime'"'"'"' <<<"$stderr"
  called '^rex window rename -s sess-a win-a X · prime not running$'
  not_called '^agent-slot launch'
  not_called '^rex window move'
  not_called '^agent-slot-rex prime'
}

@test "launch --repo from a repo session with a prime starts a slot and never opens the prime" {
  in_rex_session X
  repos X
  primes X 'X Prime'
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here --repo X </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot launch X '
  not_called '^tmux '
  not_called '^agent-slot-rex prime'
}

@test "a tab a key opened goes on once the app shows it, which makes it the session's active window" {
  in_rex_session X
  shown sess-a win-a
  repos X
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here --wait-shown </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot launch X '
  not_called '^rex window close'
}

@test "a key's launch tells the server when its tab opened and was shown, each before the request" {
  local args opened shown requested now
  in_rex_session X
  shown sess-a win-a
  repos X
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here --wait-shown </dev/null
  [ "$status" -eq 0 ]
  now=$EPOCHREALTIME
  args=$(grep '^agent-slot launch X ' "$CALLS")
  [[ $args =~ --requested-at\ ([0-9]+\.[0-9]+)\ --opened-at\ ([0-9]+\.[0-9]+)\ --shown-at\ ([0-9]+\.[0-9]+)\ --output ]]
  requested=${BASH_REMATCH[1]} opened=${BASH_REMATCH[2]} shown=${BASH_REMATCH[3]}
  # The tab's process started within the test, a moment before the helper read the clock.
  jaq -n -e --argjson o "$opened" --argjson s "$shown" --argjson r "$requested" --argjson now "${now/,/.}" \
    '$o <= $s and $s <= $r and $r <= $now and $now - $o < 30'
}

@test "a tab a key opened that the app never shows starts nothing and closes itself" {
  in_rex_session X '[{"window_id": "win-o", "label": "1: notes", "blocks": ["blk-o"]},
    {"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  shown sess-a win-o
  repos X
  primes X 'X Prime'
  run "$AGENT_SLOT_REX" launch --here --wait-shown </dev/null
  [ "$status" -eq 0 ]
  called '^rex window close -s sess-a win-a$'
  not_called '^agent-slot (repos|launch)'
  not_called '^rex window (rename|move)'
  not_called '^tmux '
}

@test "with a terminal, a tab the app never made active goes on after Enter" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  in_rex_session X '[{"window_id": "win-o", "label": "1: notes", "blocks": ["blk-o"]},
    {"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  shown sess-a win-o
  repos X
  slot_answer launch 0 "$LAUNCHED"
  run with_tty "$AGENT_SLOT_REX" launch --here --wait-shown <<<""
  [ "$status" -eq 0 ]
  [[ $output == *"press Enter"* ]]
  called '^agent-slot launch X '
  not_called '^rex window close'
}

@test "prime attaches to the repo's prime session on the default tmux server from HOME, then becomes a login shell" {
  primes X 'X Prime'
  run "$AGENT_SLOT_REX" prime X
  [ "$status" -eq 0 ]
  called '^tmux attach -t =X Prime$'
  called "^tmux-cwd $HOME\$"
  [ "$(tail -1 "$CALLS")" = "login-shell -l" ]
}

@test "prime of a repo the prime map does not name is a usage error that names the map" {
  primes X 'X Prime'
  run --separate-stderr "$AGENT_SLOT_REX" prime Y --output json
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e --arg map "$STUBS/primes" '.reason == "usage" and .value == "Y" and (.message | contains($map))' <<<"$stderr"
  not_called '^tmux '
}

@test "a retryable launch failure waits for Enter, then retries with the same request ID" {
  in_rex_session X
  repos X
  slot_answer launch 0 1 "" "$(server_error slot-busy "X/3 is locked" 1 true)"
  slot_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here <<<""
  [ "$status" -eq 0 ]
  [[ $output == *"press Enter to retry with the same request ID"* ]]
  [ "$(grep -c 'agent-slot launch X' "$CALLS")" -eq 2 ]
  [ "$(grep -oE 'request-id [0-9a-f-]+' "$CALLS" | sort -u | wc -l)" -eq 1 ]
  called '^agent-slot-rex attach X/3 claude$'
}

@test "a git-crypt-locked failure offers no retry, keeps the tab until q, and opens no slot tab" {
  in_rex_session X
  repos X
  slot_answer launch 78 "" "$(server_error git-crypt-locked "the slot could not be unlocked" 78 false)"
  run "$AGENT_SLOT_REX" launch --here <<<$'\nq'
  [ "$status" -eq 78 ]
  [[ $output != *"retry"* ]]
  [[ $output == *"press q to close this tab"* ]]
  [ "$(grep -c 'agent-slot launch X' "$CALLS")" -eq 1 ]
  called '^rex window rename -s sess-a win-a X · launch failed$'
  not_called '^agent-slot-rex attach'
  not_called '^rex (new|window new)'
}

@test "a launch error envelope is shown readably with its value, next step, and log path" {
  in_rex_session X
  repos X
  slot_answer launch 78 "" "$(server_error solutions-symlink-missing "docs/solutions is not a link" 78 false)"
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 78 ]
  [[ $output == *"solutions-symlink-missing: docs/solutions is not a link"* ]]
  [[ $output == *"value: v"* && $output == *"next: agent-slot doctor"* ]]
  [[ $output == *"log: /srv/state/logs/launch.log"* ]]
  not_called '^agent-slot-rex attach'
}

@test "a launch whose agent-slot call outlives its bound reports agent-slot-timed-out and offers a retry" {
  in_rex_session X
  repos X
  slot_answer launch 124
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json </dev/null
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "agent-slot-timed-out" and .exit_code == 1 and .recovery.retryable == true
    and .recovery.side_effects == "unknown" and .recovery.reconcile == "agent-slot-rex restore"
    and .next_step.command == "agent-slot-rex restore" and (.message | contains("agent-slot launch"))
    and (.log | type == "string")' <<<"$stderr"
  [[ $output == *"press Enter to retry with the same request ID"* ]]
  called '^rex window rename -s sess-a win-a X · launch failed$'
}

# --- the local runner -------------------------------------------------------------------------------------------------

@test "a server verb through the local runner returns agent-slot's own JSON and exit code" {
  in_rex_session X
  repos X
  slot_answer launch 0 "$LAUNCHED"
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json
  [ "$status" -eq 0 ]
  grep '^{' <<<"$output" | jaq -e '.ok == true and .key == "X/3" and .path == "/srv/slots/X/3" and .request_id == "r"'
  slot_answer launch 78 "" "$(server_error git-crypt-locked "the slot could not be unlocked" 78 false)"
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json </dev/null
  [ "$status" -eq 78 ]
  jaq -e '.reason == "git-crypt-locked" and .message == "the slot could not be unlocked"' <<<"$stderr"
  not_called '^ssh-stub '
}

@test "a missing agent-slot is dependency-missing, naming where the helper looked" {
  export AGENT_SLOT_REX_AGENT_SLOT=$T/no-such/agent-slot
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 78 ]
  assert_error_shape "$stderr"
  jaq -e --arg p "$T/no-such/agent-slot" '.reason == "dependency-missing" and .value == $p
    and .next_step.command == "cd ~/dotfiles && scripts/stow-deploy local"' <<<"$stderr"
}

@test "every agent-slot call names this helper's client, so agent-slot's push skips the pass this helper runs next" {
  export AGENT_SLOT_REX_CLIENT=testmac
  slots '[]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^agent-slot list --output json$'
  called '^agent-slot-client testmac$'
  not_called '^agent-slot-client (bretts-air)?$'
}

# --- attach -----------------------------------------------------------------------------------------------------------

@test "attach on a live slot runs a local tmux attach from HOME, and attaches again after the client detaches" {
  run "$AGENT_SLOT_REX" attach X/2 claude <<<""
  [ "$status" -eq 0 ]
  [[ $output == *"detached from X-2; press Enter to reattach"* ]]
  [ "$(grep -c '^tmux -L agent-slots attach -t =X-2$' "$CALLS")" -eq 2 ]
  [ "$(grep '^tmux-cwd ' "$CALLS" | sort -u)" = "tmux-cwd $HOME" ]
  not_called '^(ssh-stub|agent-slot) '
}

@test "attach attaches again after the slot's session ends and its resume brings it back" {
  tmux_answer has-session 1 1
  slot_answer resume 0 '{"ok":true,"key":"X/2","started":["X-2"]}'
  run "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c '^tmux -L agent-slots attach -t =X-2$' "$CALLS")" -eq 2 ]
  [ "$(grep -c '^slot-verb resume$' "$CALLS")" -eq 1 ]
}

@test "attach to a slot whose session is missing resumes the slot first, then attaches" {
  tmux_answer has-session 0 1
  slot_answer resume 0 '{"ok":true,"key":"X/2","started":["X-2-files"]}'
  run "$AGENT_SLOT_REX" attach X/2 files </dev/null
  [ "$status" -eq 0 ]
  local resume attach
  resume=$(grep -n '^agent-slot resume X/2 --output json$' "$CALLS" | cut -d: -f1)
  attach=$(grep -n '^tmux -L agent-slots attach -t =X-2-files$' "$CALLS" | head -1 | cut -d: -f1)
  [ -n "$resume" ] && [ -n "$attach" ] && [ "$resume" -lt "$attach" ]
}

@test "attach to a slot that is gone exits 0 after saying why" {
  tmux_answer has-session 1
  slot_answer resume 1 "" "$(server_error slot-not-found "X/2 holds no slot" 1 false)"
  run "$AGENT_SLOT_REX" attach X/2 git </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"X/2 is gone (X/2 holds no slot); this pane is done"* ]]
  not_called '^tmux -L agent-slots attach'
}

@test "attach keeps retrying a resume that fails for another reason, pausing between tries" {
  tmux_answer has-session 0 1
  tmux_answer has-session 1 1
  slot_answer resume 0 1 "" "$(server_error tmux-failed "tmux would not start" 1 true)"
  slot_answer resume 1 0 '{"ok":true}'
  run "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"X/2 claude: resume failed: tmux-failed; retrying in 0 s"* ]]
  [ "$(grep -c '^slot-verb resume$' "$CALLS")" -eq 2 ]
  called '^tmux -L agent-slots attach -t =X-2$'
}

# with_brew DIR: a Homebrew prefix whose bin holds tmux, flock, and a jaq that logs each run.
with_brew() {
  mkdir -p "$1/bin"
  cp "$STUBS/tmux" "$1/bin/tmux"
  printf '#!/bin/sh
echo brew-jaq >>"%s"
exec "%s" "$@"
' "$T/brew-jaq.log" "$(command -v jaq)" >"$1/bin/jaq"
  printf '#!/bin/sh
exit 0
' >"$1/bin/flock"
  chmod +x "$1/bin/jaq" "$1/bin/flock"
}

@test "under the systemd user manager's PATH, the helper finds tmux, jaq, and flock in the Homebrew bin" {
  with_brew "$T/brew"
  unset AGENT_SLOT_REX_TMUX AGENT_SLOT_JQ
  run env AGENT_SLOT_REX_HOMEBREW="$T/brew" PATH="$STUBS/os:/usr/local/bin:/usr/bin:/bin" \
    "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  called '^tmux -L agent-slots attach -t =X-2$'
  [ -s "$T/brew-jaq.log" ]
  [ "$(head -1 "$STUBS/path.log")" = "PATH=$T/brew/bin:$STUBS/os:/usr/local/bin:/usr/bin:/bin" ]
}

@test "the Homebrew bin moves to the front of PATH, and a missing Homebrew prefix leaves PATH as it was" {
  with_brew "$T/brew"
  unset AGENT_SLOT_REX_TMUX
  local jaq_dir
  jaq_dir=$(dirname "$(command -v jaq)")
  run env AGENT_SLOT_REX_HOMEBREW="$T/brew" PATH="$STUBS/os:$jaq_dir:$T/brew/bin:/usr/bin:/bin" \
    "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [ "$(head -1 "$STUBS/path.log")" = "PATH=$T/brew/bin:$STUBS/os:$jaq_dir:/usr/bin:/bin" ]
  : >"$STUBS/path.log"
  export AGENT_SLOT_REX_TMUX=$STUBS/tmux
  run env AGENT_SLOT_REX_HOMEBREW="$T/no-brew" PATH="$STUBS/os:$jaq_dir:/usr/bin:/bin" \
    "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [ "$(head -1 "$STUBS/path.log")" = "PATH=$STUBS/os:$jaq_dir:/usr/bin:/bin" ]
}

# --- reconcile: restore and sweep -------------------------------------------------------------------------------------

@test "restore opens a tab for each of three live slots across two repo sessions, making the sessions" {
  slots '[{"repo": "A", "slot": 1, "task": "t1"}, {"repo": "A", "slot": 2, "branch": "feat/b"},
    {"repo": "B", "slot": 1}]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 · t1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  called "^rex window new -s sess-A A/2 · feat/b --focus=false --json -- $STUBS/agent-slot-rex attach A/2 claude$"
  called "^rex new B --window B/1 --json -- $STUBS/agent-slot-rex attach B/1 claude$"
  [ "$(grep -c '^rex do agent_slot_layout' "$CALLS")" -eq 3 ]
  not_called '^rex window close'
}

@test "reconcile labels a slot's tab with the label list gives it: its name, else its task" {
  slots '[{"repo": "A", "slot": 1, "task": "t1", "name": "A-pr7-fix"}, {"repo": "A", "slot": 2, "task": "t2"},
    {"repo": "A", "slot": 3, "task": "t3", "label_name": "from-server"}]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 · A-pr7-fix --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  called "^rex window new -s sess-A A/2 · t2 --focus=false --json -- $STUBS/agent-slot-rex attach A/2 claude$"
  called "^rex window new -s sess-A A/3 · from-server --focus=false --json -- $STUBS/agent-slot-rex attach A/3 claude$"
}

@test "reconcile labels a tab by task, else branch, when the server's list has no label_name" {
  slot_answer list 0 '{"schema": "dotfiles.agent-slot/1", "ok": true, "verb": "list", "slots": [
    {"key": "A/1", "repo": "A", "slot": 1, "state": "active", "task": "t1", "branch": "feat/a", "agent": "idle",
     "needs_you": [], "sessions": {"claude": true, "files": true, "git": true}},
    {"key": "A/2", "repo": "A", "slot": 2, "state": "active", "task": null, "branch": "feat/b", "agent": "idle",
     "needs_you": [], "sessions": {"claude": true, "files": true, "git": true}}]}'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 · t1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  called "^rex window new -s sess-A A/2 · feat/b --focus=false --json -- $STUBS/agent-slot-rex attach A/2 claude$"
}

@test "restore closes a keyed tab whose slot is gone and leaves unkeyed tabs alone" {
  slots '[]'
  session sess-a A '[{"window_id": "w1", "label": "A/1 · old", "blocks": ["b1"]},
    {"window_id": "w2", "label": "notes", "blocks": ["b2"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^rex window close -s sess-a w1$'
  not_called '^rex window close -s sess-a w2$'
  not_called '^rex (new|window new)'
}

@test "restore leaves alone a tab whose label looks like a key outside that repo's session" {
  slots '[]'
  session sess-n notes '[{"window_id": "w1", "label": "A/1 draft", "blocks": ["b1"]}]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  not_called '^rex window (close|rename)'
}

@test "restore resumes a dormant slot before opening its tab" {
  slots '[{"repo": "A", "slot": 1, "state": "dormant"}]'
  slot_answer resume 0 '{"ok":true,"key":"A/1","started":["A-1","A-1-files","A-1-git"]}'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  local resume open
  resume=$(grep -n 'agent-slot resume A/1' "$CALLS" | cut -d: -f1)
  open=$(grep -n '^rex new A' "$CALLS" | cut -d: -f1)
  [ -n "$resume" ] && [ -n "$open" ] && [ "$resume" -lt "$open" ]
}

@test "restore closes a keyed tab whose attach loop is not running and opens a fresh one" {
  slots '[{"repo": "A", "slot": 1}]'
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1", "b2"]}]'
  runs b1 101 "-zsh"
  runs b2 102 "bash $STUBS/agent-slot-rex attach A/1 files"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^rex window close -s sess-a w1$'
  called "^rex window new -s sess-a A/1 --focus=false --json -- $STUBS/agent-slot-rex attach A/1 claude$"
}

@test "reconcile keeps the one of two tabs keyed to a slot whose attach loop runs, and closes the other" {
  slots '[{"repo": "A", "slot": 1}]'
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]},
    {"window_id": "w2", "label": "Window 2", "blocks": ["b2"]}]'
  runs b1 101 "-zsh"
  runs b2 102 "/opt/homebrew/bin/bash $STUBS/agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^rex window close -s sess-a w1$'
  not_called '^rex window close -s sess-a w2$'
  called '^rex window rename -s sess-a w2 A/1$'
  not_called '^rex (new|window new)'
}

@test "reconcile relabels X/2 to carry the branch once the slot's record names it" {
  slots '[{"repo": "X", "slot": 2, "branch": "feat/y"}]'
  session sess-x X '[{"window_id": "w1", "label": "X/2", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-x w1 X/2 · feat/y$'
}

# The needs-you message that gave agentnative-site/1 a 156-character label.
LONG_NEEDS="agent state unknown: processes outside the slot's tmux panes use the slot: 2723178 2723198 2723204"

# with_long_needs SLOTS-JSON: SLOTS-JSON with each "needs_you": "long" replaced by LONG_NEEDS.
with_long_needs() {
  jaq -c --arg m "$LONG_NEEDS" \
    'map(if .needs_you == "long" then .needs_you = [{code: "agent-state-unknown", message: $m}] else . end)' <<<"$1"
}

# fits_rex KEY LABEL: the label is within Rex's 128 characters and starts with the key, which is how reconcile finds the
# tab's slot.
fits_rex() {
  jaq -n -e --arg k "$1" --arg l "$2" '($l | length) <= 128 and ($l | startswith($k + " · "))' >/dev/null || {
    echo "label does not fit Rex or lost its key: $2" >&2
    return 1
  }
}

@test "a long needs-you message is cut to fit Rex's 128 characters, on open and on rename, keeping key and task first" {
  slots "$(with_long_needs '[{"repo": "agentnative-site", "slot": 1, "task": "release-main-2026-10-27",
    "needs_you": "long"}, {"repo": "agentnative-site", "slot": 2, "task": "t2", "needs_you": "long"}]')"
  session sess-ans agentnative-site '[{"window_id": "w1", "label": "agentnative-site/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach agentnative-site/1 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  local renamed opened
  renamed=$(sed -n 's/^rex window rename -s sess-ans w1 //p' "$CALLS")
  opened=$(sed -n 's/^rex window new -s sess-ans \(.*\) --focus=false --json -- .*/\1/p' "$CALLS")
  fits_rex agentnative-site/1 "$renamed"
  fits_rex agentnative-site/2 "$opened"
  [ "$renamed" = "agentnative-site/1 · release-main-2026-10-27 · needs you: agent state unknown: processes outside \
the slot's tmux panes use the…" ]
  [[ $opened == "agentnative-site/2 · t2 · needs you: agent state unknown: "*"…" ]]
  : >"$CALLS"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  not_called '^rex (new|window new|window rename|window close)'
}

@test "a pass that relabels a slot with a long needs-you message still closes a duplicate tab" {
  slots "$(with_long_needs '[{"repo": "agentnative-site", "slot": 1, "task": "release-main-2026-10-27",
    "needs_you": "long"}, {"repo": "dotfiles", "slot": 2}]')"
  session sess-ans agentnative-site '[{"window_id": "w1", "label": "agentnative-site/1 · release-main-2026-10-27",
    "blocks": ["b1"]}]'
  session sess-dot dotfiles '[{"window_id": "w2", "label": "dotfiles/2", "blocks": ["b2"]},
    {"window_id": "w3", "label": "dotfiles/2", "blocks": ["b3"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach agentnative-site/1 claude"
  runs b2 102 "bash $STUBS/agent-slot-rex attach dotfiles/2 claude"
  runs b3 103 "bash $STUBS/agent-slot-rex attach dotfiles/2 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-ans w1 agentnative-site/1 · release-main-2026-10-27 · needs you: '
  called '^rex window close -s sess-dot w3$'
  not_called '^rex window close -s sess-dot w2$'
}

@test "a rex failure's message carries rex's Error: line, not the help pointer after it" {
  slots '[]'
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach A/1 claude"
  rex_fails 'window close' 2 $'Error: window w1 is not in session sess-a\nRun "rex window close --help" for more information.'
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "rex-failed" and .message == "rex window exited 2: Error: window w1 is not in session sess-a"' \
    <<<"$stderr"
  rex_fails 'window close' 1 $'connection reset\n\n'
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  jaq -e '.message == "rex window exited 1: connection reset"' <<<"$stderr"
}

@test "with agent-slot list outliving its bound, restore reports agent-slot-timed-out and changes no tabs" {
  slot_answer list 124
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "agent-slot-timed-out" and .value == "60"
    and .message == "agent-slot list did not finish within 60 s"' <<<"$stderr"
  not_called '^rex (new|window new|window close|window rename)'
}

# --- reconcile: passes that overlap -----------------------------------------------------------------------------------

LOCK_LINK=reconcile.lock

@test "two restores at once open one tab for a slot that has none" {
  slots '[{"repo": "D", "slot": 7, "task": "t"}]'
  session sess-d D '[]'
  hold_window_new sess-d 2
  "$AGENT_SLOT_REX" restore --output json >"$T/a.out" 2>"$T/a.err" &
  local a=$!
  "$AGENT_SLOT_REX" restore --output json >"$T/b.out" 2>"$T/b.err" &
  local b=$!
  local status_a=0 status_b=0
  wait "$a" || status_a=$?
  wait "$b" || status_b=$?
  [ "$status_a" -eq 0 ] && [ "$status_b" -eq 0 ]
  grep '^rex window' "$CALLS" >&2 || true
  [ "$(grep -c '^rex window new -s sess-d D/7 · t ' "$CALLS")" -eq 1 ]
  not_called '^rex window close'
  [ ! -L "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK" ]
}

@test "a pane whose attach loop starts while the snapshot runs counts as running" {
  slots '[{"repo": "A", "slot": 1}]'
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  starts_on_inspect sess-a b1 101 "bash $STUBS/agent-slot-rex attach A/1 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  not_called '^rex window (close|new)'
  not_called '^rex new'
}

@test "a reconcile lock whose holder is gone does not stop the next restore" {
  slots '[{"repo": "A", "slot": 1}]'
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR"
  sh -c 'exit 0' &
  local gone=$!
  wait "$gone"
  ln -s "$gone" "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  called "^rex new A --window A/1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
  [ ! -L "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK" ]
}

@test "a restore behind a reconcile that outlasts the wait fails with reconcile-busy and changes no tabs" {
  slots '[{"repo": "A", "slot": 1}]'
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR" "$T/holder"
  printf '#!/usr/bin/env bash\ntrap '"'"'kill $!; exit 0'"'"' TERM\nsleep 10 &\nwait\n' >"$T/holder/agent-slot-rex"
  chmod +x "$T/holder/agent-slot-rex"
  "$T/holder/agent-slot-rex" </dev/null >/dev/null 2>&1 &
  local holder=$!
  ln -s "$holder" "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK"
  run --separate-stderr env AGENT_SLOT_REX_LOCK_WAIT=1 "$AGENT_SLOT_REX" restore --output json
  kill "$holder"
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e --arg l "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK" '.reason == "reconcile-busy" and .value == $l
    and .recovery.retryable == true' <<<"$stderr"
  not_called 'agent-slot list'
  not_called '^rex (new|window)'
  [ "$(readlink "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK")" = "$holder" ]
}

@test "a reconcile that stops on an error leaves no lock behind" {
  slot_answer list 124
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "agent-slot-timed-out"' <<<"$stderr"
  [ ! -L "$AGENT_SLOT_REX_STATE_DIR/$LOCK_LINK" ]
}

@test "the sweep closes itself when nothing needs you" {
  slots '[{"repo": "X", "slot": 1}]'
  session sess-x X '[{"window_id": "w1", "label": "X/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/1 claude"
  run "$AGENT_SLOT_REX" sweep </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"nothing needs you"* ]]
  [[ $output != *"press q"* ]]
}

@test "with a blocker the sweep stays open, and the slot's tab label carries that blocker" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slots '[{"repo": "X", "slot": 1, "needs_you": [{"code": "unpushed", "message": "1 unpushed commit"}]}]'
  session sess-x X '[{"window_id": "w1", "label": "X/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/1 claude"
  run with_tty "$AGENT_SLOT_REX" sweep <<<"q"
  [ "$status" -eq 0 ]
  [[ $output == *"X/1 · needs you: 1 unpushed commit"* ]]
  [[ $output == *"press q to close this tab"* ]]
  called '^rex window rename -s sess-x w1 X/1 · needs you: 1 unpushed commit$'
}

@test "a sweep showing what needs you runs again in its own tab on r" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slots '[{"repo": "X", "slot": 1, "needs_you": [{"code": "unpushed", "message": "1 unpushed commit"}]}]'
  session sess-x X '[{"window_id": "w1", "label": "X/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/1 claude"
  run with_tty "$AGENT_SLOT_REX" sweep <<<"rq"
  [ "$status" -eq 0 ]
  [[ $output == *"press r to run the sweep again; press q to close this tab"* ]]
  called '^agent-slot-rex sweep$'
}

@test "a sweep that finds nothing needing you still runs again when r arrived while it ran" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slots '[]'
  run with_tty "$AGENT_SLOT_REX" sweep <<<"rq"
  [ "$status" -eq 0 ]
  called '^agent-slot-rex sweep$'
}

@test "a sweep tab whose agent-slot call fails stays open, showing the error and its log path" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slot_answer sweep 124
  run with_tty "$AGENT_SLOT_REX" sweep <<<"q"
  [ "$status" -eq 1 ]
  [[ $output == *"agent-slot-timed-out: agent-slot sweep did not finish within 300 s"* ]]
  [[ $output =~ log:\ $AGENT_SLOT_REX_STATE_DIR/logs/[^[:space:]]+-sweep\.log ]]
  [[ $output == *"press q to close this tab"* ]]
}

@test "a sweep tab whose agent-slot call failed runs the sweep again on r" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slot_answer sweep 124
  run with_tty "$AGENT_SLOT_REX" sweep <<<"rq"
  called '^agent-slot-rex sweep$'
}

# started_by COMMAND: the process that started the helper, as ps reports its parent.
started_by() {
  printf '1 %s\n' "$1" >>"$STUBS/ps.txt"
}

# --- the reconcile log ------------------------------------------------------------------------------------------------

RECONCILE_LOG=reconcile.log

@test "each reconcile pass appends one JSON line: when it ran, what ran it, its plan, and ok or the error" {
  slots '[{"repo": "A", "slot": 1}, {"repo": "A", "slot": 2}]'
  session sess-a A '[{"window_id": "w1", "label": "A/2 · old", "blocks": ["b1"]},
    {"window_id": "w2", "label": "A/9", "blocks": ["b2"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach A/2 claude"
  runs b2 102 "bash $STUBS/agent-slot-rex attach A/9 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  local log=$AGENT_SLOT_REX_STATE_DIR/$RECONCILE_LOG
  [ "$(wc -l <"$log")" -eq 1 ]
  jaq -e '.by == "restore" and .ok == true and .error == null and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and [.plan.open[].key] == ["A/1"] and [.plan.rename[] | {key, label}] == [{key: "A/2", label: "A/2"}]
    and [.plan.close[] | {key, why}] == [{key: "A/9", why: "slot is gone"}]' "$log"
  rex_fails 'window close' 2 $'Error: window w2 is not in session sess-a\nRun "rex window close --help" for more information.'
  run "$AGENT_SLOT_REX" sweep --output json
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$log")" -eq 2 ]
  tail -1 "$log" | jaq -e '.by == "sweep" and .ok == false and [.plan.close[].key] == ["A/9"]
    and .error.reason == "rex-failed" and (.error.message | endswith("Error: window w2 is not in session sess-a"))'
}

@test "the reconcile log names a restore at Rex start and a finish, and records a pass that stopped before its plan" {
  started_by '/usr/bin/rex server run'
  slots '[]'
  run "$AGENT_SLOT_REX" restore --at-start
  [ "$status" -eq 0 ]
  slot_answer finish 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"finish","key":"X/2","torn_down":true}'
  run "$AGENT_SLOT_REX" finish X/2 </dev/null
  [ "$status" -eq 0 ]
  slot_answer list 124
  run "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  jaq -s -e '[.[].by] == ["restore-at-start", "finish", "restore"] and [.[].ok] == [true, true, false]
    and .[2].plan == null and .[2].error.reason == "agent-slot-timed-out"' "$AGENT_SLOT_REX_STATE_DIR/$RECONCILE_LOG"
}

@test "a pass that stops unexpectedly still leaves its line in the reconcile log, as a script-error" {
  slots '[]'
  printf 'not json\n' >"$STUBS/rexdata/sessions.json"
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "script-error"' <<<"$stderr"
  jaq -e '.by == "restore" and .ok == false and .plan == null and .error.reason == "script-error"
    and (.error.message | startswith("stopped unexpectedly at "))' "$AGENT_SLOT_REX_STATE_DIR/$RECONCILE_LOG"
}

@test "past 1 MiB the reconcile log moves to reconcile.log.1, replacing the one before" {
  local log=$AGENT_SLOT_REX_STATE_DIR/$RECONCILE_LOG
  mkdir -p "$AGENT_SLOT_REX_STATE_DIR"
  echo older >"$log.1"
  head -c 1100000 /dev/zero | tr '\0' x >"$log"
  slots '[]'
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  [ "$(wc -c <"$log.1")" -eq 1100000 ]
  [ "$(wc -l <"$log")" -eq 1 ]
  jaq -e '.by == "restore"' "$log"
}

# --- the error contract -----------------------------------------------------------------------------------------------

@test "every JSON error from agent-slot-rex has the contract's shape" {
  local stderr_file=$BATS_TEST_TMPDIR/err
  slot_answer list 124
  "$AGENT_SLOT_REX" restore --output json 2>"$stderr_file" || true
  assert_error_shape "$(cat "$stderr_file")"
  "$AGENT_SLOT_REX" attach nope claude --output json 2>"$stderr_file" || true
  assert_error_shape "$(cat "$stderr_file")"
  rm "$STUBS/slot/list.rc"
  repos X
  in_rex_session nope
  "$AGENT_SLOT_REX" launch --output json 2>"$stderr_file" </dev/null || true
  assert_error_shape "$(cat "$stderr_file")"
  no_rex
  "$AGENT_SLOT_REX" restore --output json 2>"$stderr_file" || true
  slots '[]'
  "$AGENT_SLOT_REX" restore --output json 2>"$stderr_file" || true
  jaq -e '.reason == "dependency-missing"' "$stderr_file"
  assert_error_shape "$(cat "$stderr_file")"
}

# sweep_tore_down KEY...: the server's sweep --yes tore these slots down.
sweep_tore_down() {
  slot_answer sweep 0 "$(printf '%s\n' "$@" | jaq -R -s -c '{schema: "dotfiles.agent-slot/1", ok: true,
    verb: "sweep", dry_run: false, torn_down: split("\n") | map(select(. != "")), would_tear_down: [],
    needs_you: [], slots: []}')"
}

@test "the sweep runs the server's sweep --yes before it lists the slots" {
  sweep_tore_down
  slots '[]'
  run "$AGENT_SLOT_REX" sweep </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot sweep --yes --output json$'
  [ "$(grep '^slot-verb' "$CALLS" | head -2 | paste -sd ' ' -)" = 'slot-verb sweep slot-verb list' ]
}

@test "after a launch from a just-merged task's tab, the sweep tears that slot down and closes its tab" {
  sweep_tore_down X/1
  slots '[{"repo": "X", "slot": 2}]'
  session sess-x X '[{"window_id": "w1", "label": "X/1 · feat/done", "blocks": ["b1"]},
    {"window_id": "w2", "label": "X/2", "blocks": ["b2"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/1 claude"
  runs b2 102 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run "$AGENT_SLOT_REX" sweep </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"torn down: X/1"* ]]
  called '^rex window close -s sess-x w1$'
  not_called '^rex window close -s sess-x w2$'
}

@test "the finish key finds the focused tab's slot by its attach loop and runs the finish in the agent-slots session" {
  session sess-x X '[{"window_id": "w1", "label": "Window 1", "blocks": ["b1", "b2"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run "$AGENT_SLOT_REX" finish --tab --session sess-x --block b2
  [ "$status" -eq 0 ]
  called "^rex new agent-slots --window finish X/2 --json -- $STUBS/agent-slot-rex finish X/2$"
  not_called '^agent-slot '
}

@test "the finish key on a tab that is not a slot's is a usage error and opens nothing" {
  session sess-x X '[{"window_id": "w1", "label": "notes", "blocks": ["b1"]}]'
  runs b1 101 "-zsh"
  run --separate-stderr "$AGENT_SLOT_REX" finish --tab --session sess-x --block b1 --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  not_called '^rex (new|window new)'
}

@test "finish runs the server's finish --yes, then closes the finished task's tab" {
  slot_answer finish 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"finish","key":"X/2","torn_down":true}'
  slots '[]'
  session sess-x X '[{"window_id": "w1", "label": "X/2", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run "$AGENT_SLOT_REX" finish X/2 </dev/null
  [ "$status" -eq 0 ]
  called '^agent-slot finish X/2 --yes --output json$'
  [[ $output == *"X/2 is torn down"* ]]
  called '^rex window close -s sess-x w1$'
}

@test "finish of a task with an open PR names the PR, deletes nothing, and keeps the tab until q" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  slot_answer finish 1 "" "$(server_error task-has-open-pr 'X/2 has an open PR: #11; merge or close it first' 1 false)"
  slots '[{"repo": "X", "slot": 2}]'
  session sess-x X '[{"window_id": "w1", "label": "X/2", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run with_tty "$AGENT_SLOT_REX" finish X/2 <<<"q"
  [ "$status" -eq 1 ]
  [[ $output == *"task-has-open-pr"*"#11"* ]]
  [[ $output == *"press q to close this tab"* ]]
  not_called '^rex window close'
}

# --- the rex CLI and the settings -------------------------------------------------------------------------------------

@test "every rex call passes --autostart=false, so the helper never starts a Rex server" {
  slots '[{"repo": "A", "slot": 1}]'
  session sess-a A '[{"window_id": "w1", "label": "A/9", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach A/9 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUBS/rex-argv.log")" -gt 4 ]
  run grep -v -- '^--autostart=false ' "$STUBS/rex-argv.log"
  [ "$status" -eq 1 ]
}

# settings_value NAME [VAR=VALUE...]: the value lib/settings.sh gives NAME, sourced alone under the given environment.
settings_value() {
  local name=$1
  shift
  env "$@" bash -c 'source "$1" && printf "%s" "${!2}"' _ \
    "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/settings.sh" "$name"
}

@test "with REX_BIN_DIR unset, the CLI lookup is /usr/bin/rex and takes the first candidate that exists" {
  unset AGENT_SLOT_REX_APP_PATHS
  [ "$(settings_value AR_REX_PATHS)" = /usr/bin/rex ]
  unset REX_BIN_DIR
  mkdir -p "$T/usr/bin"
  cp "$STUBS/rex" "$T/usr/bin/rex"
  slots '[]'
  run --separate-stderr env AGENT_SLOT_REX_APP_PATHS="$T/Applications/Rex.app/rex:$T/usr/bin/rex" \
    "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 0 ]
  called '^rex ls --json$'
}

@test "overriding one setting changes only that value" {
  local before after
  before=$(env -u AGENT_SLOT_REX_SERVER bash -c 'source "$1" && declare -p | grep "^declare -[-ax]* AR_"' _ \
    "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/settings.sh")
  after=$(env AGENT_SLOT_REX_SERVER=elsewhere bash -c 'source "$1" && declare -p | grep "^declare -[-ax]* AR_"' _ \
    "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/settings.sh")
  [ "$(diff <(echo "$before") <(echo "$after") | grep -c '^[<>]')" -eq 2 ]
  [[ $after == *'AR_SERVER="elsewhere"'* ]]
}

@test "no library outside settings.sh names a host" {
  run grep -rlE 'bigdaddy|bretts-air' "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib"
  [ "$output" = "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/settings.sh" ]
}

# --- a pass that fails after its slot verb succeeded ------------------------------------------------------------------

@test "a finish whose teardown succeeded reports a failed reconcile with partial side effects and the restore to run" {
  slot_answer finish 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"finish","key":"X/2","torn_down":true}'
  slots '[]'
  rex_fails 'ls --json' 1 'Error: no Rex server is running at unix:///run/user/1000/rex/server.sock'
  run --separate-stderr "$AGENT_SLOT_REX" finish X/2 --output json </dev/null
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "rex-failed" and .recovery.side_effects == "partial"
    and .recovery.reconcile == "agent-slot-rex restore" and (.message | contains("agent-slot finish tore X/2 down"))' \
    <<<"$stderr"
}

@test "a sweep that tore slots down reports a failed reconcile as partial, and one that tore none down as none" {
  sweep_tore_down X/1 X/4
  slots '[]'
  rex_fails 'ls --json' 1 'Error: no Rex server is running at unix:///run/user/1000/rex/server.sock'
  run --separate-stderr "$AGENT_SLOT_REX" sweep --output json </dev/null
  [ "$status" -eq 1 ]
  jaq -e '.recovery.side_effects == "partial" and (.message | contains("agent-slot sweep tore down X/1, X/4"))' \
    <<<"$stderr"
  sweep_tore_down
  run --separate-stderr "$AGENT_SLOT_REX" sweep --output json </dev/null
  [ "$status" -eq 1 ]
  jaq -e '.recovery.side_effects == "none" and (.message | contains("tore") | not)' <<<"$stderr"
}

@test "attach waits out a tmux server that does not answer, and resumes nothing while it waits" {
  tmux_answer has-session 0 124
  run "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"X/2 claude: the agent-slots tmux server did not answer; retrying in 0 s"* ]]
  not_called '^agent-slot resume'
  called '^tmux -L agent-slots attach -t =X-2$'
}

# --- tab numbers ------------------------------------------------------------------------------------------------------

@test "a tab whose label carries a number, even a doubled one, is keyed to its slot by the rest of the label" {
  slots '[{"repo": "dotfiles", "slot": 3, "task": "task"}]'
  session sess-d dotfiles '[{"window_id": "w1", "label": "4: 1: dotfiles/3 · task", "blocks": ["b1"]}]'
  run "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 0 ]
  jaq -e '.closed == [{key: "dotfiles/3", label: "4: 1: dotfiles/3 · task", why: "attach loop is not running"}]
    and .opened == ["dotfiles/3"]' <<<"$output"
}

@test "a numbered tab whose rest matches its slot is left alone, and a rename for a changed task keeps its number" {
  slots '[{"repo": "dotfiles", "slot": 3, "task": "task"}, {"repo": "dotfiles", "slot": 4, "task": "new"}]'
  session sess-d dotfiles '[{"window_id": "w1", "label": "2: dotfiles/3 · task", "blocks": ["b1"]},
    {"window_id": "w2", "label": "3: dotfiles/4 · old", "blocks": ["b2"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach dotfiles/3 claude"
  runs b2 102 "bash $STUBS/agent-slot-rex attach dotfiles/4 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  not_called '^rex window rename -s sess-d w1 '
  called '^rex window rename -s sess-d w2 3: dotfiles/4 · new$'
  not_called '^rex (new|window new|window close)'
}

@test "a numbered label at Rex's limit is cut in its rest, never its number, and a second pass changes nothing" {
  slots "$(with_long_needs '[{"repo": "agentnative-site", "slot": 1, "task": "release-main-2026-10-27",
    "needs_you": "long"}]')"
  session sess-ans agentnative-site '[{"window_id": "w1", "label": "12: agentnative-site/1", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach agentnative-site/1 claude"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  local renamed
  renamed=$(sed -n 's/^rex window rename -s sess-ans w1 //p' "$CALLS")
  jaq -n -e --arg l "$renamed" '($l | length) <= 128 and ($l | startswith("12: agentnative-site/1 · "))
    and ($l | endswith("…"))' >/dev/null
  : >"$CALLS"
  run "$AGENT_SLOT_REX" restore
  [ "$status" -eq 0 ]
  not_called '^rex (new|window new|window rename|window close)'
}

@test "the finish key finds the slot from a numbered label when no attach loop names it" {
  session sess-x X '[{"window_id": "w1", "label": "3: X/2 · t", "blocks": ["b1"]}]'
  run "$AGENT_SLOT_REX" finish --tab --session sess-x --block b1
  [ "$status" -eq 0 ]
  called "^rex new agent-slots --window finish X/2 --json -- $STUBS/agent-slot-rex finish X/2$"
}
