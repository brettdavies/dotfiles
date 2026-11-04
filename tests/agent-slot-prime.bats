#!/usr/bin/env bats
# A repo's prime: the slot-shaped set of tmux sessions that runs in the repo's own checkout. Its names and its map, then
# the verb that starts it.
#
# Run: bats tests/agent-slot-prime.bats
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
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/projects
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  NAMES=$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/names.sh
  MAP=$BATS_TEST_DIRNAME/../config/agent-slot-rex/primes.tsv
  prime repoa
  rm -f "$STUBS/tmux-panes-default"
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# names EXPRESSION: runs a shell expression with the names library loaded.
names() {
  bash -c 'source "$1"; eval "$2"' _ "$NAMES" "$1"
}

# --- names and the map ------------------------------------------------------------------------------------------------

@test "a prime's three sessions come from the same naming a slot's do, sanitized the same way" {
  run names 'slot_session repoa prime; echo; slot_session repoa prime files; echo; slot_session repoa prime git; echo
    slot_session a.b prime'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = repoa-prime ]
  [ "${lines[1]}" = repoa-prime-files ]
  [ "${lines[2]}" = repoa-prime-git ]
  [ "${lines[3]}" = a_b-prime ]
}

@test "a prime's Claude session is told from a slot's by name, whatever digits the repo's name holds" {
  local is_prime is_slot
  for is_prime in x-prime foo-2-prime; do
    run names "slot_session_is_prime $is_prime"
    [ "$status" -eq 0 ]
    run names "slot_session_is_claude $is_prime"
    [ "$status" -ne 0 ]
  done
  for is_slot in x-prime-1 foo-2; do
    run names "slot_session_is_prime $is_slot"
    [ "$status" -ne 0 ]
    run names "slot_session_is_claude $is_slot"
    [ "$status" -eq 0 ]
  done
  run names "slot_session_is_prime x-prime-files"
  [ "$status" -ne 0 ]
}

@test "a repo's display name comes from the map, else from the repo's own name" {
  printf '# a comment\nxurl-rs\tXR CLI\nbroken line with no tab\n#qmd\tcommented out\n' >"$T/map"
  run names "prime_display_name xurl-rs '$T/map'; echo; prime_display_name qmd '$T/map'; echo
    prime_display_name broken '$T/map'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'XR CLI' ]
  [ "${lines[1]}" = qmd ]
  [ "${lines[2]}" = broken ]
}

@test "the map names each repo once, with two fields and a name tmux can hold" {
  local repos
  run awk -F '\t' '!/^#/ && NF != 2' "$MAP"
  [ -z "$output" ]
  repos=$(awk -F '\t' '!/^#/ { print $1 }' "$MAP")
  [ -n "$repos" ]
  [ -z "$(sort <<<"$repos" | uniq -d)" ]
  run awk -F '\t' '!/^#/ && $2 ~ /[.:]/' "$MAP"
  [ -z "$output" ]
}

@test "the map carries the display name of each session that runs today under a name other than its repo's" {
  run names "prime_display_name home-media-server '$MAP'; echo; prime_display_name dot-github '$MAP'; echo
    prime_display_name streams-control '$MAP'; echo; prime_display_name gbrain '$MAP'; echo
    prime_display_name obsidian-vault '$MAP'; echo; prime_display_name qmd '$MAP'"
  [ "${lines[0]}" = 'Home Media Server' ]
  [ "${lines[1]}" = _github ]
  [ "${lines[2]}" = 'Streams Control' ]
  [ "${lines[3]}" = GBrain ]
  [ "${lines[4]}" = Vault ]
  [ "${lines[5]}" = qmd ]
}

@test "an old session counts as holding a Claude only when a pane runs one, under its name or its version" {
  run names "printf 'A\tzsh\nA\tclaude\nB\t2.1.318\nC\tzsh\nC\tlazygit\nD\t2.1\nA\tyazi\n' | prime_old_sessions"
  [ "$status" -eq 0 ]
  [ "$output" = $'A\nB' ]
}

@test "a slot verb given a prime's key says it is a prime and names the verb that starts it" {
  run --separate-stderr "$AGENT_SLOT" resume repoa/prime --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "repoa/prime"
    and (.message | contains("agent-slot prime repoa"))' <<<"$stderr"
}

# --- the verb ---------------------------------------------------------------------------------------------------------

# start [REPO]: runs the verb with JSON output.
start() {
  run --separate-stderr "$AGENT_SLOT" prime "${1:-repoa}" --output json
}

# transcript PROJECT ID [TITLE...]: a transcript under that project directory holding a message and each title in order.
transcript() {
  local file=$AGENT_SLOT_CLAUDE_PROJECTS/$1/$2.jsonl id=$2 title
  shift 2
  mkdir -p "${file%/*}"
  echo '{"type":"user","message":"hello"}' >"$file"
  for title in "$@"; do
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$title" "$id" >>"$file"
  done
}

# wrap_tmux BODY: runs BODY ahead of the fixture's tmux stub on every call, which then logs each call twice.
wrap_tmux() {
  cp "$STUBS/tmux" "$STUBS/tmux.inner"
  stub tmux "$1
exec \"\$STUBS/tmux.inner\" \"\$@\""
}

# old_style NAME COMMAND: a session of that name on the default tmux server with one pane running COMMAND, and the map
# giving repoa that display name.
old_style() {
  printf 'repoa\t%s\n' "$1" >"$T/map"
  export AGENT_SLOT_PRIMES=$T/map
  printf '%s\t%s\n' "$1" "$2" >"$STUBS/tmux-panes-default"
}

prime_starts() { jaq -c 'select(.event == "prime-start")' "$AGENT_SLOT_STATE_DIR/ledger.jsonl" 2>/dev/null || true; }

# dev_root DIR: the dev root moves to DIR.
dev_root() {
  export AGENT_SLOT_DEV=$1
  mkdir -p "$1"
}

# rex_helper BODY: a Rex helper the verb pushes a restore to, and waits for before it exits.
rex_helper() {
  stub agent-slot-rex "$1"
  export AGENT_SLOT_REX_HELPER=$STUBS/agent-slot-rex AGENT_SLOT_PUSH_WAIT=1
}

@test "with no sessions, three start on the slot socket at the checkout, typing what a slot's sessions type" {
  local checkout=$AGENT_SLOT_DEV/repoa json kind
  start
  [ "$status" -eq 0 ]
  json=$output
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 3 ]
  for kind in repoa-prime repoa-prime-files repoa-prime-git; do
    grep -qF -- "-L agent-slot-test -f $AGENT_SLOT_TMUX_CONF new-session -d -s $kind -c $checkout " "$CALLS"
  done
  [ "$(cat "$STUBS/typed-repoa-prime-files")" = 'command -v y >/dev/null && y || yazi' ]
  [ "$(cat "$STUBS/typed-repoa-prime-git")" = lazygit ]
  [[ $(cat "$STUBS/typed-repoa-prime") =~ ^claude\ --dangerously-skip-permissions\ --session-id\ [0-9a-f-]{36}\ -n\ repoa-prime$ ]]
  jaq -e --arg path "$checkout" '.key == "repoa/prime" and .repo == "repoa" and .path == $path
    and .name == "repoa-prime" and .server == "slots" and .session == "repoa-prime"
    and .started == ["repoa-prime", "repoa-prime-files", "repoa-prime-git"]
    and .conversation.mode == "fresh" and (.conversation.session_id | test("^[0-9a-f-]{36}$"))
    and .next_step.command == "agent-slot list --output json"
    and (.next_step.note | contains("repoa-prime") and contains("agent-slot-rex prime repoa"))' <<<"$json"
}

@test "a checkout keeps its dirty file, its branch, and its docs/solutions link, with nothing written to git" {
  local checkout=$AGENT_SLOT_DEV/repoa before
  git -C "$checkout" checkout -q -b feat/mine
  echo dirty >"$checkout/dirty.txt"
  mkdir -p "$checkout/docs"
  ln -s "$AGENT_SLOT_SOLUTIONS" "$checkout/docs/solutions"
  before=$(fingerprint "$checkout")
  start
  [ "$status" -eq 0 ]
  [ "$(fingerprint "$checkout")" = "$before" ]
  [ "$(git -C "$checkout" worktree list | wc -l)" -eq 1 ]
}

@test "a transcript titled for the prime is resumed under that name" {
  local id=aaaaaaaa-0000-4000-8000-000000000001
  transcript -fixture-dev-repoa "$id" repoa-prime
  start
  [ "$status" -eq 0 ]
  [ "$(cat "$STUBS/typed-repoa-prime")" = "claude --dangerously-skip-permissions --resume $id -n repoa-prime" ]
  jaq -e --arg id "$id" '.conversation == {mode: "resumed", session_id: $id}' <<<"$output"
}

@test "of two transcripts titled for the prime, the newer is resumed" {
  local old=aaaaaaaa-0000-4000-8000-000000000001 new=aaaaaaaa-0000-4000-8000-000000000002
  transcript -fixture-dev-repoa "$new" repoa-prime
  transcript -fixture-dev-repoa "$old" repoa-prime
  touch -d '-10 minutes' "$AGENT_SLOT_CLAUDE_PROJECTS/-fixture-dev-repoa/$old.jsonl"
  start
  jaq -e --arg id "$new" '.conversation.session_id == $id' <<<"$output"
}

@test "only a transcript's latest title counts, and it must match exactly" {
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000001 repoa-prime renamed
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000002 repoa-prime-old
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000003 xrepoa-prime
  start
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
}

@test "a transcript in another project's directory is found" {
  local id=aaaaaaaa-0000-4000-8000-000000000001
  transcript -somewhere-else-entirely "$id" repoa-prime
  start
  jaq -e --arg id "$id" '.conversation == {mode: "resumed", session_id: $id}' <<<"$output"
}

@test "a transcript a running Claude holds is skipped for the next newest, and with none left the start is fresh" {
  local old=aaaaaaaa-0000-4000-8000-000000000001 new=aaaaaaaa-0000-4000-8000-000000000002
  transcript -fixture-dev-repoa "$new" repoa-prime
  transcript -fixture-dev-repoa "$old" repoa-prime
  touch -d '-10 minutes' "$AGENT_SLOT_CLAUDE_PROJECTS/-fixture-dev-repoa/$old.jsonl"
  jaq -n --arg id "$new" '[{sessionId: $id, cwd: "/elsewhere", status: "busy"}]' >"$STUBS/claude-agents.json"
  start
  jaq -e --arg id "$old" '.conversation == {mode: "resumed", session_id: $id}' <<<"$output"

  : >"$STUBS/tmux-sessions"
  jaq -n --arg a "$new" --arg b "$old" '[{sessionId: $a}, {sessionId: $b}]' >"$STUBS/claude-agents.json"
  start
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
}

@test "a transcript with no title, as a claude -p run leaves, is never chosen" {
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000001
  start
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
}

@test "a transcript quoting a title in a tool result is not chosen" {
  local file=$AGENT_SLOT_CLAUDE_PROJECTS/-fixture-dev-repoa/aaaaaaaa-0000-4000-8000-000000000001.jsonl
  mkdir -p "${file%/*}"
  cat >"$file" <<'JSON'
{"type":"user","message":{"content":"{\"type\":\"custom-title\",\"customTitle\":\"repoa-prime\"}"}}
{"type":"user","note":{"type":"custom-title","customTitle":"repoa-prime"}}
JSON
  start
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
}

@test "a transcript holding a binary byte is still read" {
  local id=aaaaaaaa-0000-4000-8000-000000000001
  transcript -fixture-dev-repoa "$id" repoa-prime
  printf '{"type":"user","message":"\000\377"}\n' >>"$AGENT_SLOT_CLAUDE_PROJECTS/-fixture-dev-repoa/$id.jsonl"
  start
  jaq -e --arg id "$id" '.conversation.session_id == $id' <<<"$output"
}

@test "a titled transcript not named by a session ID is passed over, so its name never becomes an argument" {
  transcript -fixture-dev-repoa '--append-system-prompt=planted' repoa-prime
  transcript -fixture-dev-repoa not-a-session repoa-prime
  start
  [ "$status" -eq 0 ]
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
  [[ $(cat "$STUBS/typed-repoa-prime") == "claude --dangerously-skip-permissions --session-id "* ]]
}

@test "with no project directory yet, the start is fresh" {
  find "$AGENT_SLOT_CLAUDE_PROJECTS" -delete
  start
  [ "$status" -eq 0 ]
  jaq -e '.conversation.mode == "fresh"' <<<"$output"
}

@test "a flag where the repo goes is a usage error, not a search for a repo of that name" {
  run --separate-stderr "$AGENT_SLOT" prime --bogus --output json
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "usage" and .value == "--bogus" and (.message | contains("unknown option"))' <<<"$stderr"
}

@test "a title scan that fails stops the start with script-error and starts no session" {
  [ "$(id -u)" -ne 0 ] || skip "root reads an unreadable file"
  local file=$AGENT_SLOT_CLAUDE_PROJECTS/-fixture-dev-repoa/aaaaaaaa-0000-4000-8000-000000000001.jsonl
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000001 repoa-prime
  chmod 000 "$file"
  start
  chmod 644 "$file"
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "script-error" and .next_step.command == "agent-slot prime repoa"
    and (.log | type == "string")' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a claude agents that fails stops the start with script-error and starts no session" {
  stub claude 'exit 1'
  transcript -fixture-dev-repoa aaaaaaaa-0000-4000-8000-000000000001 repoa-prime
  start
  [ "$status" -eq 1 ]
  jaq -e '.reason == "script-error" and .next_step.command == "agent-slot prime repoa"' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a killed files session alone restarts, with no new Claude and no second session" {
  printf 'repoa-prime\nrepoa-prime-git\n' >"$STUBS/tmux-sessions"
  start
  [ "$status" -eq 0 ]
  jaq -e '.started == ["repoa-prime-files"] and .conversation == {mode: "running", session_id: null}' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 1 ]
  [ ! -e "$STUBS/typed-repoa-prime" ]
  [ "$(sort "$STUBS/tmux-sessions" | uniq -d)" = "" ]
}

@test "with all three running, nothing starts and the ledger gets no line" {
  printf 'repoa-prime\nrepoa-prime-files\nrepoa-prime-git\n' >"$STUBS/tmux-sessions"
  start
  [ "$status" -eq 0 ]
  jaq -e '.started == [] and .server == "slots" and .conversation.mode == "running"' <<<"$output"
  run ! grep -q ' new-session ' "$CALLS"
  [ -z "$(prime_starts)" ]
}

@test "a display-named session holding a Claude on the default server is the prime, and nothing starts" {
  old_style 'Repo A' claude
  start
  [ "$status" -eq 0 ]
  jaq -e '.server == "default" and .session == "Repo A" and .started == []
    and .conversation == {mode: "running", session_id: null} and .trust_prompt_expected == false' <<<"$output"
  run ! grep -q ' new-session ' "$CALLS"
  [ -z "$(prime_starts)" ]
}

@test "a display-named session holding no Claude is no prime: three start, and the default server is only read" {
  old_style 'Repo A' zsh
  start
  [ "$status" -eq 0 ]
  jaq -e '.server == "slots" and (.started | length) == 3' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 3 ]
  [ "$(grep -c -- '-L default ' "$CALLS")" -eq 1 ]
  grep -q -- '-L default list-panes -a ' "$CALLS"
}

@test "a default socket with no server gets no session and no server" {
  start
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/tmux-sessions-default" ]
  [ "$(grep -c -- '-L default ' "$CALLS")" -eq 1 ]
}

@test "a default server that does not answer exits tmux-unresponsive naming that socket, and starts nothing" {
  wrap_tmux '[[ " $* " != *" -L default "* ]] || exec sleep 60'
  start
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "tmux-unresponsive" and .value == "default"
    and (.next_step.command | startswith("timeout 5 ") and endswith("-L default list-sessions"))' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a read of the default server that fails for another reason exits tmux-failed, and starts nothing" {
  wrap_tmux '[[ " $* " != *" -L default "* ]] || { echo "lost server" >&2; exit 1; }'
  start
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "tmux-failed" and .value == "default"
    and .next_step.command == "agent-slot prime repoa"' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a prime's sessions carry the user bus where its socket exists, and only then" {
  export AGENT_SLOT_USER_BUS=$T/bus
  start
  run ! grep -q DBUS_SESSION_BUS_ADDRESS "$CALLS"

  : >"$AGENT_SLOT_USER_BUS"
  : >"$STUBS/tmux-sessions"
  : >"$CALLS"
  start
  [ "$(grep -c " new-session .*-e DBUS_SESSION_BUS_ADDRESS=unix:path=$T/bus " "$CALLS")" -eq 3 ]
}

@test "a start pushes a restore, a run that starts nothing does not, and neither does a helper's own call" {
  rex_helper 'exit 0'
  start
  [ "$status" -eq 0 ]
  [ "$(grep -c '^agent-slot-rex restore --by push' "$CALLS")" -eq 1 ]
  start
  [ "$(grep -c '^agent-slot-rex restore --by push' "$CALLS")" -eq 1 ]

  : >"$STUBS/tmux-sessions"
  export AGENT_SLOT_REX_CLIENT=1
  start
  [ "$status" -eq 0 ]
  [ "$(grep -c '^agent-slot-rex restore --by push' "$CALLS")" -eq 1 ]
  [ "$(tail -1 "$AGENT_SLOT_STATE_DIR/push.log" | jaq -r '.verb + " " + .result')" = 'prime skipped' ]
}

@test "the text line says what happened in each of its forms" {
  local id=aaaaaaaa-0000-4000-8000-000000000001
  transcript -fixture-dev-repoa "$id" repoa-prime
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
  run --separate-stderr "$AGENT_SLOT" prime repoa
  [ "$output" = "repoa/prime: started repoa-prime, repoa-prime-files, repoa-prime-git, resuming $id" ]
  run --separate-stderr "$AGENT_SLOT" prime repoa
  [ "$output" = 'repoa/prime: already running' ]

  old_style 'Repo A' 2.1.318
  run --separate-stderr "$AGENT_SLOT" prime repoa
  [ "$output" = 'repoa/prime: runs in Repo A on the default tmux server; close that session to rebuild it on the slot server' ]
}

@test "two concurrent runs give one set of sessions" {
  local one two
  wrap_tmux '[[ " $* " != *" new-session "* ]] || sleep 0.2'
  "$AGENT_SLOT" prime repoa --output json >"$T/one" 2>&1 &
  one=$!
  "$AGENT_SLOT" prime repoa --output json >"$T/two" 2>&1 &
  two=$!
  wait "$one"
  wait "$two"
  [ "$(wc -l <"$STUBS/tmux-sessions")" -eq 3 ]
  [ "$(sort "$STUBS/tmux-sessions" | uniq -d)" = "" ]
  [ "$(cat "$T/one" "$T/two" | jaq -s -c '[.[].started | length] | sort')" = '[0,3]' ]
}

@test "a run that waits past the bound on another's lock exits slot-busy, and retrying names the verb" {
  export AGENT_SLOT_LOCK_WAIT=1
  mkdir -p "$AGENT_SLOT_STATE_DIR/primes"
  spawn flock "$AGENT_SLOT_STATE_DIR/primes/repoa.lock" sleep 60 3>&-
  until [ -n "$(find /proc/$!/fd -lname "$AGENT_SLOT_STATE_DIR/primes/repoa.lock" 2>/dev/null)" ]; do sleep 0.1; done
  start
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-busy" and .next_step.command == "agent-slot prime repoa"' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a new-session that fails exits tmux-failed, and retrying names the verb" {
  wrap_tmux '[[ " $* " != *" new-session "* ]] || exit 1'
  start
  [ "$status" -eq 1 ]
  jaq -e '.reason == "tmux-failed" and .value == "repoa-prime"
    and .next_step.command == "agent-slot prime repoa"' <<<"$stderr"
}

@test "with 8 live slots the prime still starts, and a launch still refuses at the limit with it running" {
  local n
  for n in 1 2 3 4 5 6 7 8; do slot repoa "$n"; done
  start
  [ "$status" -eq 0 ]
  jaq -e '(.started | length) == 3' <<<"$output"
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-nine --output json
  [ "$status" -eq 78 ]
  jaq -e '.reason == "slot-limit-reached"' <<<"$stderr"
}

@test "an untrusted checkout starts Claude all the same, reports it, and leaves trust alone" {
  local state_before
  state_before=$(sha256sum <"$AGENT_SLOT_CLAUDE_STATE")
  start
  [ "$status" -eq 0 ]
  jaq -e '.trust_prompt_expected == true' <<<"$output"
  [ -e "$STUBS/typed-repoa-prime" ]
  [ "$(sha256sum <"$AGENT_SLOT_CLAUDE_STATE")" = "$state_before" ]
  run ! grep -q -- '-L agent-slot-trust' "$CALLS"
}

@test "a trusted checkout reports no prompt coming" {
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
  start
  jaq -e '.trust_prompt_expected == false' <<<"$output"
}

@test "an unknown repo exits repo-not-found" {
  start nope
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "repo-not-found" and .value == "nope"' <<<"$stderr"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "a repo name that climbs out of the dev root is no repo" {
  git -C "$T/dev" init -q
  git -C "$T/dev" remote add origin "$T/origins/repoa.git"
  dev_root "$T/dev/inner"
  start ..
  [ "$status" -eq 2 ]
  jaq -e '.reason == "repo-not-found"' <<<"$stderr"
  start ../repoa
  [ "$status" -eq 2 ]
  jaq -e '.reason == "repo-not-found"' <<<"$stderr"
}

@test "a repo named in the extra list is found by its directory's name, and the dev root wins a tie" {
  mkdir -p "$T/extras"
  git clone -q "$T/origins/repoa.git" "$T/extras/repoa"
  git clone -q "$T/origins/repoa.git" "$T/extras/only-here"
  export AGENT_SLOT_EXTRA_PRIMES=$T/extras/repoa:$T/extras/only-here
  start only-here
  [ "$status" -eq 0 ]
  jaq -e --arg p "$T/extras/only-here" '.path == $p' <<<"$output"
  start repoa
  jaq -e --arg p "$AGENT_SLOT_DEV/repoa" '.path == $p' <<<"$output"
}

@test "a start writes one prime-start line with the stamps a launch line carries, and a later no-op writes none" {
  local line
  start
  start
  line=$(prime_starts)
  [ "$(wc -l <<<"$line")" -eq 1 ]
  jaq -e --arg path "$AGENT_SLOT_DEV/repoa" '.repo == "repoa" and .key == "repoa/prime" and .path == $path
    and .started == ["repoa-prime", "repoa-prime-files", "repoa-prime-git"] and .conversation == "fresh"
    and (.session_id | type == "string") and (.started_at | type == "number") and .made_at >= .started_at' <<<"$line"
}

@test "a checkout whose .git is a file starts the same way" {
  local before
  split_prime "$AGENT_SLOT_DEV/splitrepo" "$T/gitdirs/splitrepo"
  rm -f "$STUBS/tmux-panes-default"
  before=$(fingerprint "$AGENT_SLOT_DEV/splitrepo")
  start splitrepo
  [ "$status" -eq 0 ]
  jaq -e '.session == "splitrepo-prime" and (.started | length) == 3' <<<"$output"
  [ "$(fingerprint "$AGENT_SLOT_DEV/splitrepo")" = "$before" ]
}

@test "a start creates nothing under the slot root" {
  start
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa" ]
}

@test "the verb takes one repo" {
  run --separate-stderr "$AGENT_SLOT" prime --output json
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  run --separate-stderr "$AGENT_SLOT" prime repoa repob --output json
  [ "$status" -eq 2 ]
}

@test "list's help names the primes it reports" {
  run "$AGENT_SLOT" list --help
  [ "$status" -eq 0 ]
  [[ $output == *'primes[] of {key, repo, server, session, label}'* ]]
}

@test "the verb's help names its usage, what it returns, and an example" {
  run "$AGENT_SLOT" prime --help
  [ "$status" -eq 0 ]
  [[ $output == *'usage: agent-slot prime <repo>'* ]]
  [[ $output == *'returns:'* ]]
  [[ $output == *'example: agent-slot prime '* ]]
}

# --- a slot starts its prime ------------------------------------------------------------------------------------------

# launch_slot [REQUEST]: launches a slot of repoa, its path already trusted.
launch_slot() {
  local n
  for n in 1 2 3; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id "${1:-r1}" --output json
}

PRIME_SESSIONS='["repoa-prime", "repoa-prime-files", "repoa-prime-git"]'

@test "a launch starts the slot's three sessions and the prime's three, and reports the prime" {
  launch_slot
  [ "$status" -eq 0 ]
  jaq -e --argjson started "$PRIME_SESSIONS" '.key == "repoa/1" and .created == true
    and .prime.key == "repoa/prime" and .prime.server == "slots" and .prime.started == $started' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 6 ]
  grep -qF -- "new-session -d -s repoa-prime -c $AGENT_SLOT_DEV/repoa " "$CALLS"
}

@test "a launch with the old-style session running reports it and starts no prime session" {
  old_style 'Repo A' claude
  launch_slot
  [ "$status" -eq 0 ]
  jaq -e '.prime.server == "default" and .prime.session == "Repo A" and .prime.started == []' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 3 ]
}

@test "a second launch finds the prime running and starts no prime session" {
  launch_slot r1
  launch_slot r2
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/2" and .prime.started == []' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 9 ]
}

@test "a launch that returns the slot already holding its request starts nothing and reports no prime" {
  launch_slot r1
  : >"$CALLS"
  launch_slot r1
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1" and .prime == null' <<<"$output"
  run ! grep -q ' new-session ' "$CALLS"
}

@test "resuming a dormant slot starts its prime from the checkout the record names" {
  slot repoa 1
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e --argjson started "$PRIME_SESSIONS" '.started == ["repoa-1", "repoa-1-files", "repoa-1-git"]
    and .prime.started == $started' <<<"$output"
  grep -qF -- "new-session -d -s repoa-prime -c $AGENT_SLOT_DEV/repoa " "$CALLS"
}

@test "a record cannot choose where a resume's prime starts" {
  mkdir -p "$T/planted"
  slot repoa 1 "{\"prime\": \"$T/planted\"}"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e --arg path "$AGENT_SLOT_DEV/repoa" '.prime.path == $path' <<<"$output"
  grep -qF -- "new-session -d -s repoa-prime -c $AGENT_SLOT_DEV/repoa " "$CALLS"
  run ! grep -qF -- "-c $T/planted " "$CALLS"
}

@test "a record naming no checkout still gets the repo's prime on a resume" {
  slot repoa 1 '{"prime": null}'
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.prime.key == "repoa/prime" and (.prime.started | length) == 3' <<<"$output"
}

@test "a resume of a repo with no checkout here still succeeds, reporting why the prime did not start" {
  slot repoz 1
  run --separate-stderr "$AGENT_SLOT" resume repoz/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '(.started | length) == 3 and .prime.error.reason == "repo-not-found"' <<<"$output"
  [ "$(grep -c ' new-session ' "$CALLS")" -eq 3 ]
}

@test "a prime that fails to start leaves the launch a success, its slot active, and the retry in the output" {
  wrap_tmux '[[ " $* " != *" new-session "*"-prime"* ]] || exit 1'
  launch_slot
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  jaq -e '.ok == true and .key == "repoa/1" and .prime.error.reason == "tmux-failed"
    and .prime.error.next_step.command == "agent-slot prime repoa"
    and (.prime.error.log | type == "string") and (.prime.error.message | type == "string")
    and .prime.error.exit_code == 1 and .prime.error.value == "repoa-prime"
    and (.prime.error.recovery.retryable | type == "boolean")' <<<"$output"
  [ -z "$stderr" ]
  [ "$(jaq -r '.state' "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json")" = active ]
  [ "$(sort -u "$STUBS/tmux-sessions")" = $'repoa-1\nrepoa-1-files\nrepoa-1-git' ]
}

@test "a launch's text line says its prime did not start" {
  local n
  for n in 1 2 3; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  wrap_tmux '[[ " $* " != *" new-session "*"-prime"* ]] || exit 1'
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r1
  [ "$status" -eq 0 ]
  [[ $output == *'; its prime did not start: tmux-failed'* ]]
}

@test "a prime start that dies with no error object reports script-error and keeps what it printed" {
  cat >"$STUBS/jq-dies" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'session_id: $id, prompt_file: null'*) echo 'the words it died with' >&2; exit 5 ;;
esac
exec jaq "$@"
EOF
  chmod +x "$STUBS/jq-dies"
  export AGENT_SLOT_JQ=$STUBS/jq-dies
  launch_slot
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .prime.error.reason == "script-error"
    and .prime.error.next_step.command == "agent-slot prime repoa"' <<<"$output"
  grep -q 'the words it died with' "$(jaq -r '.prime.error.log' <<<"$output")"
}

@test "the prime is up before the push, so the pass that opens the slot's tab opens the prime's too, and pushes once" {
  rex_helper 'cp "$STUBS/tmux-sessions" "$STUBS/sessions-at-push"'
  launch_slot
  [ "$status" -eq 0 ]
  grep -qx repoa-prime "$STUBS/sessions-at-push"
  [ "$(grep -c '^agent-slot-rex restore --by push' "$CALLS")" -eq 1 ]
}

@test "a prime that fails to start still pushes the slot's tab, once" {
  rex_helper 'exit 0'
  wrap_tmux '[[ " $* " != *" new-session "*"-prime"* ]] || exit 1'
  launch_slot
  [ "$status" -eq 0 ]
  [ "$(grep -c '^agent-slot-rex restore --by push' "$CALLS")" -eq 1 ]
}
