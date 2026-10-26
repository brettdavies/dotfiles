#!/usr/bin/env bats
# agent-slot-rex: the Mac half of agent slots, against stubbed rex, ssh, and ps.
#
# Run: bats tests/agent-slot-rex.bats

bats_require_minimum_version 1.5.0

load lib/agent-slot-rex

setup() {
  agent_slot_rex_setup
}

LAUNCHED='{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"launch","created":true,"key":"X/3","repo":"X","slot":3,
  "path":"/srv/slots/X/3","task":null,"request_id":"r","session_id":"s","base":"main","trust_prompt_expected":false}'

# A Rex terminal in session sess-a, named LABEL, whose window win-a holds block blk-a.
in_rex_session() {
  session sess-a "$1" '[{"window_id": "win-a", "label": "new agent", "blocks": ["blk-a"]}]'
  export REX_SESSION=sess-a REX_BLOCK=blk-a
}

# --- help and usage ---------------------------------------------------------------------------------------------------

@test "every verb answers --help with a usage line and an example" {
  local verb
  for verb in launch attach restore sweep doctor; do
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

# --- launch -----------------------------------------------------------------------------------------------------------

@test "launch from the repo's session launches it, relabels and lays out its tab, and becomes the attach" {
  in_rex_session X
  repos X Y
  ssh_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^ssh-stub .*agent-slot launch X --request-id [0-9a-f-]{36} --requested-at [0-9]+ --output json$'
  called '^rex window rename -s sess-a win-a X/3$'
  called '^rex do agent_slot_layout -s sess-a -b blk-a key=X/3 block=blk-a$'
  called '^agent-slot-rex attach X/3 claude$'
  [ "$(tail -1 "$CALLS")" = "agent-slot-rex attach X/3 claude" ]
}

@test "launch adds trust needed to the label when the server expects the trust dialog" {
  in_rex_session X
  repos X
  ssh_answer launch 0 "$(jaq -c '. + {task: "fix/y", trust_prompt_expected: true}' <<<"$LAUNCHED")"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called '^rex window rename -s sess-a win-a X/3 · fix/y · trust needed$'
}

@test "after a launch a sweep tab opens in the agent-slots session, and the session is made when missing" {
  in_rex_session X
  repos X
  ssh_answer launch 0 "$LAUNCHED"
  run "$AGENT_SLOT_REX" launch --here
  [ "$status" -eq 0 ]
  called "^rex new agent-slots --window sweep --json -- $STUBS/agent-slot-rex sweep$"
  : >"$CALLS"
  run "$AGENT_SLOT_REX" launch --here
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
  not_called '^ssh-stub .*agent-slot launch'
}

@test "from a session that names no repo, a terminal gets a numbered list and the launch moves to the repo's session" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  in_rex_session gentle-sierra
  repos X Y
  run with_tty "$AGENT_SLOT_REX" launch --here <<<"2"
  [ "$status" -eq 0 ]
  [[ $output == *"1) X"* && $output == *"2) Y"* ]]
  called '^rex focus -s sess-a win-a$'
  called "^rex new Y --window Y · launching --json -- $STUBS/agent-slot-rex launch --here --repo Y$"
  not_called '^ssh-stub .*agent-slot launch'
}

@test "a retryable launch failure waits for Enter, then retries with the same request ID" {
  in_rex_session X
  repos X
  ssh_answer launch 0 1 "" "$(server_error slot-busy "X/3 is locked" 1 true)"
  ssh_answer launch 0 "$LAUNCHED"
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
  ssh_answer launch 78 "" "$(server_error git-crypt-locked "the slot could not be unlocked" 78 false)"
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
  ssh_answer launch 78 "" "$(server_error solutions-symlink-missing "docs/solutions is not a link" 78 false)"
  run "$AGENT_SLOT_REX" launch --here </dev/null
  [ "$status" -eq 78 ]
  [[ $output == *"solutions-symlink-missing: docs/solutions is not a link"* ]]
  [[ $output == *"value: v"* && $output == *"next: agent-slot doctor"* ]]
  [[ $output == *"log: /srv/state/logs/launch.log"* ]]
  not_called '^agent-slot-rex attach'
}

@test "launch with the server unreachable reports server-unreachable with the alias and offers a retry" {
  in_rex_session X
  touch "$STUBS/ssh/unreachable"
  run --separate-stderr "$AGENT_SLOT_REX" launch --here --output json </dev/null
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "server-unreachable" and .value == "testserver" and .recovery.retryable == true
    and (.message | contains("Connection refused")) and (.log | type == "string")' <<<"$stderr"
  [[ $output == *"press Enter to retry with the same request ID"* ]]
  called '^rex window rename -s sess-a win-a new agent · launch failed$'
}

# --- attach -----------------------------------------------------------------------------------------------------------

@test "attach retries after ssh exits 255, showing the error and the retry count, without exiting" {
  local i
  for i in 0 1 2; do ssh_answer attach "$i" 255 "" "ssh: connect to host testserver port 22: Connection refused"; done
  ssh_answer attach 3 0
  ssh_answer has-session 0
  run "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"X/2 claude: ssh: connect to host testserver port 22: Connection refused; retry 3 in 0 s"* ]]
  [ "$(grep -c '^ssh-stub-verb attach$' "$CALLS")" -eq 4 ]
  called "^ssh-stub .*ServerAliveInterval=5 .*ServerAliveCountMax=2 -t testserver .*attach -t '=X-2'$"
}

@test "attach single-quotes its exact-match targets, which zsh on the server would expand as =command" {
  ssh_answer attach 0
  ssh_answer has-session 0
  run "$AGENT_SLOT_REX" attach X/2 claude </dev/null
  [ "$status" -eq 0 ]
  called "has-session -t '=X-2' 2>/dev/null \\|\\| exit 3; exec tmux -L agent-slots attach -t '=X-2'$"
  called "^ssh-stub -n .*tmux -L agent-slots has-session -t '=X-2'$"
  not_called "-t =X-2"
  if command -v zsh >/dev/null; then
    run zsh -c "print -r -- $(grep -m1 -o "has-session -t '=X-2'" "$CALLS")"
    [ "$output" = "has-session -t =X-2" ]
  fi
}

@test "attach to a missing session runs resume once, then attaches" {
  ssh_answer attach 0 3
  ssh_answer attach 1 0
  ssh_answer has-session 0
  ssh_answer resume 0 '{"ok":true,"key":"X/2","started":["X-2"]}'
  run "$AGENT_SLOT_REX" attach X/2 files </dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh-stub-verb resume$' "$CALLS")" -eq 1 ]
  [ "$(grep -c '^ssh-stub-verb attach$' "$CALLS")" -eq 2 ]
  called "attach -t '=X-2-files'$"
}

@test "attach to a slot that is gone exits 0 after saying why" {
  ssh_answer attach 3
  ssh_answer resume 1 "" "$(server_error slot-not-found "X/2 holds no slot" 1 false)"
  run "$AGENT_SLOT_REX" attach X/2 git </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"X/2 is gone from testserver (X/2 holds no slot)"* ]]
  [ "$(grep -c '^ssh-stub-verb attach$' "$CALLS")" -eq 1 ]
}

@test "attach after a deliberate detach waits for Enter before reattaching" {
  ssh_answer attach 0
  ssh_answer has-session 0
  run "$AGENT_SLOT_REX" attach X.y/2 claude <<<""
  [ "$status" -eq 0 ]
  [[ $output == *"detached from X_y-2; press Enter to reattach"* ]]
  [ "$(grep -c '^ssh-stub-verb attach$' "$CALLS")" -eq 2 ]
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
  ssh_answer resume 0 '{"ok":true,"key":"A/1","started":["A-1","A-1-files","A-1-git"]}'
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

@test "with ssh exiting 255, restore reports server-unreachable with the alias and changes no tabs" {
  touch "$STUBS/ssh/unreachable"
  session sess-a A '[{"window_id": "w1", "label": "A/1", "blocks": ["b1"]}]'
  run --separate-stderr "$AGENT_SLOT_REX" restore --output json
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "server-unreachable" and .value == "testserver"' <<<"$stderr"
  not_called '^rex (new|window new|window close|window rename)'
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

@test "a sweep tab whose ssh fails stays open, showing the error and its log path" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  touch "$STUBS/ssh/unreachable"
  run with_tty "$AGENT_SLOT_REX" sweep <<<"q"
  [ "$status" -eq 1 ]
  [[ $output == *"server-unreachable: ssh to testserver failed"* ]]
  [[ $output =~ log:\ $AGENT_SLOT_REX_STATE_DIR/logs/[^[:space:]]+-sweep\.log ]]
  [[ $output == *"press q to close this tab"* ]]
}

@test "restore at Rex start gives up after its bound when ssh never answers, and logs why" {
  touch "$STUBS/ssh/hang"
  export AGENT_SLOT_REX_RESTORE_WAIT=2
  run timeout 20 "$AGENT_SLOT_REX" restore --wait-server
  [ "$status" -eq 1 ]
  grep -q 'gave up: testserver did not answer ssh within 2 s' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
  grep -q 'server-unreachable' "$AGENT_SLOT_REX_STATE_DIR/restore.log"
  not_called '^rex (new|window new|window close)'
}

@test "restore at Rex start reconciles once the server answers" {
  ssh_answer probe 0 1
  slots '[{"repo": "A", "slot": 1}]'
  run "$AGENT_SLOT_REX" restore --wait-server
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh-stub-verb probe$' "$CALLS")" -eq 2 ]
  called "^rex new A --window A/1 --json -- $STUBS/agent-slot-rex attach A/1 claude$"
}

# --- doctor -----------------------------------------------------------------------------------------------------------

SERVER_DOCTOR='{"schema":"dotfiles.agent-slot/1","ok":false,"verb":"doctor","findings":[
  {"reason":"git-crypt-key-missing","severity":"error","message":"no key","exit_code":78,
   "next_step":{"action":"fix-config","command":"op document get '"'"'git-crypt key'"'"' --out-file k","docs":"d"}},
  {"reason":"slot-path-untrusted","severity":"warning","message":"untrusted","exit_code":78,
   "next_step":{"action":"run","command":"agent-slot warm dotfiles","docs":"d"}}],
  "launch_times":{"launches":0,"measured":0,"not_ready":[],"skewed":0,"median_s":null,"p90_s":null,"target_s":30},
  "verified_versions":{"claude":"2.1.310"}}'

@test "doctor rewrites each server next step to run through the alias" {
  ssh_answer doctor 1 "$SERVER_DOCTOR"
  run --separate-stderr "$AGENT_SLOT_REX" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '[.findings[] | select(.host == "server") | .next_step.command | startswith("ssh testserver ")] == [true, true]' \
    <<<"$output"
  local cmd remote
  while IFS= read -r cmd; do
    eval "remote=${cmd#ssh testserver }"
    jaq -e --arg r "$remote" '[.findings[].next_step.command] | index($r) != null' <<<"$SERVER_DOCTOR"
  done < <(jaq -r '.findings[] | select(.host == "server") | .next_step.command' <<<"$output")
  jaq -e '.launch_times.target_s == 30' <<<"$output"
}

@test "doctor with the server unreachable still reports every Mac check, plus server-unreachable" {
  touch "$STUBS/ssh/unreachable"
  printf '{"actions":[{"name":"dev_layout"}]}\n' >"$STUBS/rexdata/actions.json"
  export REX_STUB_VERSION=9.9.9 AGENT_SLOT_REX_VERIFIED_VERSIONS=$BATS_TEST_TMPDIR/verified
  printf 'rex 0.0.1\n' >"$AGENT_SLOT_REX_VERIFIED_VERSIONS"
  run --separate-stderr "$AGENT_SLOT_REX" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '[.findings[] | {reason, host, severity}] == [
    {reason: "rex-action-unregistered", host: "mac", severity: "error"},
    {reason: "version-unverified", host: "mac", severity: "warning"},
    {reason: "server-unreachable", host: "server", severity: "error"}]' <<<"$output"
  local finding
  while IFS= read -r finding; do
    assert_error_shape "$finding"
  done < <(jaq -c '.findings[]' <<<"$output")
}

@test "doctor without rex reports dependency-missing for it and still checks the server" {
  no_rex
  ssh_answer doctor 0 '{"ok":true,"findings":[],"launch_times":null,"verified_versions":{}}'
  run --separate-stderr "$AGENT_SLOT_REX" doctor --output json
  [ "$status" -eq 1 ]
  jaq -e '[.findings[].reason] == ["dependency-missing"] and .findings[0].host == "mac"' <<<"$output"
  called 'agent-slot doctor --output json$'
}

# --- the error contract -----------------------------------------------------------------------------------------------

@test "every JSON error from agent-slot-rex has the contract's shape" {
  local stderr_file=$BATS_TEST_TMPDIR/err
  touch "$STUBS/ssh/unreachable"
  "$AGENT_SLOT_REX" restore --output json 2>"$stderr_file" || true
  assert_error_shape "$(cat "$stderr_file")"
  "$AGENT_SLOT_REX" attach nope claude --output json 2>"$stderr_file" || true
  assert_error_shape "$(cat "$stderr_file")"
  rm "$STUBS/ssh/unreachable"
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
  ssh_answer sweep 0 "$(printf '%s\n' "$@" | jaq -R -s -c '{schema: "dotfiles.agent-slot/1", ok: true,
    verb: "sweep", dry_run: false, torn_down: split("\n") | map(select(. != "")), would_tear_down: [],
    needs_you: [], slots: []}')"
}

@test "the sweep runs the server's sweep --yes before it lists the slots" {
  sweep_tore_down
  slots '[]'
  run "$AGENT_SLOT_REX" sweep </dev/null
  [ "$status" -eq 0 ]
  called '^ssh-stub .*agent-slot.* sweep --yes --output json'
  [ "$(grep '^ssh-stub-verb' "$CALLS" | head -2 | paste -sd ' ')" = 'ssh-stub-verb sweep ssh-stub-verb list' ]
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
  not_called '^ssh-stub '
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
  ssh_answer finish 0 '{"schema":"dotfiles.agent-slot/1","ok":true,"verb":"finish","key":"X/2","torn_down":true}'
  slots '[]'
  session sess-x X '[{"window_id": "w1", "label": "X/2", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run "$AGENT_SLOT_REX" finish X/2 </dev/null
  [ "$status" -eq 0 ]
  called '^ssh-stub .*agent-slot.* finish X/2 --yes --output json'
  [[ $output == *"X/2 is torn down"* ]]
  called '^rex window close -s sess-x w1$'
}

@test "finish of a task with an open PR names the PR, deletes nothing, and keeps the tab until q" {
  command -v script >/dev/null || skip "script(1) gives the helper a terminal"
  ssh_answer finish 1 "" "$(server_error task-has-open-pr 'X/2 has an open PR: #11; merge or close it first' 1 false)"
  slots '[{"repo": "X", "slot": 2}]'
  session sess-x X '[{"window_id": "w1", "label": "X/2", "blocks": ["b1"]}]'
  runs b1 101 "bash $STUBS/agent-slot-rex attach X/2 claude"
  run with_tty "$AGENT_SLOT_REX" finish X/2 <<<"q"
  [ "$status" -eq 1 ]
  [[ $output == *"task-has-open-pr"*"#11"* ]]
  [[ $output == *"press q to close this tab"* ]]
  not_called '^rex window close'
}
