#!/usr/bin/env bats
# agent-slot launch and resume: claiming a slot, setting it up like the prime checkout, starting its tmux sessions, and
# rolling back what never finished.
#
# Run: bats tests/agent-slot-launch.bats

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
  export AGENT_SLOT_LOCK_WAIT=2 AGENT_SLOT_TRUST_TIMEOUT=3
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  prime repoa
  local n
  for n in 1 2 3 4 5 6 7 8 9; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# The prime checkout is never claimed, modified, or deleted.
assert_prime_untouched() {
  [ "$(fingerprint "$AGENT_SLOT_DEV/repoa")" = "$BEFORE" ]
}

launch() {
  run --separate-stderr "$AGENT_SLOT" launch "$@" --output json
}

# partial_prime NAME: a blobless clone of NAME's origin, served over file:// so the filter applies, whose origin/main
# has moved past its checkout as a fetch leaves it. The prime lacks the blob at origin/main, and the origin stores the
# next blob as a delta against that one, so a thin pack built against the prime's refs carries a delta it cannot
# resolve. Origin's dev, which the prime has never fetched, adds g, whose blob reaches a slot only when it checks out
# dev.
partial_prime() {
  local origin=$T/origins/$1.git seed=$T/seed-$1
  git init -q --bare "$origin"
  git -C "$origin" config uploadpack.allowFilter true
  git clone -q "$origin" "$seed" 2>/dev/null
  origin_file "$1" f "$(seq 1 20000)"
  git clone -q --filter=blob:none "file://$origin" "$AGENT_SLOT_DEV/$1"
  origin_file "$1" f "$(seq 1 30000)"
  git -C "$AGENT_SLOT_DEV/$1" fetch -q origin
  origin_file "$1" f "$(seq 1 29999)"
  git -C "$seed" checkout -q -b dev
  echo 'on dev only' >"$seed/g"
  git -C "$seed" add g
  git -C "$seed" commit -q -m 'add g'
  git -C "$seed" push -q origin dev
  git -C "$origin" repack -q -a -d -f
}

@test "AE1: with slots 1-3 holding tasks and slot 4 torn down, launch clones into slot 4" {
  slot repoa 1
  slot repoa 2
  slot repoa 3
  launch repoa --request-id r-ae1
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .key == "repoa/4" and .state == "active" and .base == "main"' <<<"$output"
  [ -d "$AGENT_SLOT_ROOT/repoa/4/.git" ]
  [ "$(git -C "$AGENT_SLOT_ROOT/repoa/4" config --get remote.origin.url)" = "$T/origins/repoa.git" ]
  [ ! -s "$AGENT_SLOT_ROOT/repoa/4/.git/objects/info/alternates" ]
  [ -z "$(git -C "$AGENT_SLOT_ROOT/repoa/4" config --get-regexp '^remote\.origin\.(promisor|partialclonefilter)$' || true)" ]
  printf 'repoa-4\nrepoa-4-files\nrepoa-4-git\n' | diff - <(grep '^repoa-4' "$STUBS/tmux-sessions")
  assert_prime_untouched
}

@test "a prime that is a partial clone gets a slot cloned with the prime's filter, which needs no blob the prime lacks" {
  partial_prime pc
  local prime=$AGENT_SLOT_DEV/pc slot=$AGENT_SLOT_ROOT/pc/1
  trusted "$(realpath -m "$slot")"
  BEFORE=$(fingerprint "$prime")
  launch pc --request-id r-partial
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .key == "pc/1" and .base == "dev"' <<<"$output"
  [ "$(git -C "$slot" config --get remote.origin.partialclonefilter)" = blob:none ]
  [ "$(git -C "$slot" config --get remote.origin.promisor)" = true ]
  [ ! -s "$slot/.git/objects/info/alternates" ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$(git -C "$T/origins/pc.git" rev-parse dev)" ]
  [ "$(wc -l <"$slot/f")" -eq 29999 ]
  [ "$(cat "$slot/g")" = 'on dev only' ]
  [ "$(fingerprint "$prime")" = "$BEFORE" ]
}

@test "a partial slot whose base checkout cannot fetch its blobs fails with clone-failed and leaves no slot" {
  partial_prime pc
  local blob slot=$AGENT_SLOT_ROOT/pc/1
  blob=$(git -C "$T/origins/pc.git" rev-parse dev:g)
  # A pack-objects hook only global config can set: origin refuses the one fetch that asks for dev's blob.
  printf '#!/usr/bin/env bash\nin=%s/pack-objects-in.$$\ncat >"$in"\n! grep -q %s "$in" || exit 1\nexec "$@" <"$in"\n' \
    "$T" "$blob" >"$T/refuse-g"
  chmod +x "$T/refuse-g"
  git config --file "$GIT_CONFIG_GLOBAL" uploadpack.packObjectsHook "$T/refuse-g"
  trusted "$(realpath -m "$slot")"
  launch pc --request-id r-partial-fail
  [ "$status" -eq 1 ]
  jaq -e '.reason == "clone-failed" and .value == "dev" and (.message | test("checking out dev"))
    and .next_step.command == "agent-slot launch pc --request-id r-partial-fail"' <<<"$stderr"
  grep -q 'could not fetch' "$(jaq -r .log <<<"$stderr")"
  [ ! -e "$slot" ]
  [ ! -e "$AGENT_SLOT_ROOT/pc/.1.claim.json" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
}

@test "AE2: with the shared solutions repo missing, launch refuses and leaves no slot and no session" {
  rmdir "$AGENT_SLOT_SOLUTIONS"
  launch repoa --request-id r-ae2
  [ "$status" -eq 78 ]
  jaq -e '.reason == "solutions-symlink-missing" and (.message | test("symlink could not be created"))' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/.1.claim.json" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
  assert_prime_untouched
}

@test "every slot gets docs/solutions as an absolute link to the shared repo" {
  launch repoa --request-id r-sol
  [ "$status" -eq 0 ]
  [ "$(readlink "$AGENT_SLOT_ROOT/repoa/1/docs/solutions")" = "$AGENT_SLOT_SOLUTIONS" ]
}

@test "AE3: a prime core.hooksPath inside the prime becomes the same path relative to the slot" {
  origin_file repoa scripts/hooks/pre-commit '#!/bin/sh'
  git -C "$AGENT_SLOT_DEV/repoa" pull -q origin main
  git -C "$AGENT_SLOT_DEV/repoa" config core.hooksPath "$AGENT_SLOT_DEV/repoa/scripts/hooks"
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  launch repoa --request-id r-ae3
  [ "$status" -eq 0 ]
  [ "$(git -C "$AGENT_SLOT_ROOT/repoa/1" config --local --get core.hooksPath)" = scripts/hooks ]
  hooks=$(git -C "$AGENT_SLOT_ROOT/repoa/1" rev-parse --path-format=absolute --git-path hooks)
  [ "$hooks" = "$AGENT_SLOT_ROOT/repoa/1/scripts/hooks" ]
  assert_prime_untouched
}

@test "a prime core.hooksPath outside the prime is refused with hooks-path-outside-checkout" {
  git -C "$AGENT_SLOT_DEV/repoa" config core.hooksPath "$T/elsewhere/hooks"
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  launch repoa --request-id r-out
  [ "$status" -eq 78 ]
  jaq -e --arg v "$T/elsewhere/hooks" '.reason == "hooks-path-outside-checkout" and .value == $v' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  assert_prime_untouched
}

@test "with no core.hooksPath, the prime's own non-sample hooks are copied into the slot" {
  printf '#!/bin/sh\necho hook\n' >"$AGENT_SLOT_DEV/repoa/.git/hooks/pre-commit"
  chmod +x "$AGENT_SLOT_DEV/repoa/.git/hooks/pre-commit"
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  launch repoa --request-id r-hooks
  [ "$status" -eq 0 ]
  cmp "$AGENT_SLOT_DEV/repoa/.git/hooks/pre-commit" "$AGENT_SLOT_ROOT/repoa/1/.git/hooks/pre-commit"
  [ -x "$AGENT_SLOT_ROOT/repoa/1/.git/hooks/pre-commit" ]
}

@test "a git-crypt repo with the key absent is refused with git-crypt-locked, leaving nothing behind" {
  origin_file repoa .gitattributes 'secret/** filter=git-crypt diff=git-crypt'
  rm "$AGENT_SLOT_GIT_CRYPT_KEY"
  launch repoa --request-id r-crypt
  [ "$status" -eq 78 ]
  jaq -e --arg k "$AGENT_SLOT_GIT_CRYPT_KEY" '.reason == "git-crypt-locked" and .value == $k' <<<"$stderr"
  [ "$(grep -c '^git-crypt unlock' "$CALLS")" -eq 0 ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
}

@test "a git-crypt repo with git-crypt missing is refused with git-crypt-locked" {
  origin_file repoa .gitattributes 'secret/** filter=git-crypt diff=git-crypt'
  export AGENT_SLOT_GIT_CRYPT=$T/no-git-crypt
  launch repoa --request-id r-crypt2
  [ "$status" -eq 78 ]
  jaq -e '.reason == "git-crypt-locked" and .value == "git-crypt"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
}

@test "a git-crypt repo is unlocked with the key before setup goes on" {
  origin_file repoa .gitattributes 'secret/** filter=git-crypt diff=git-crypt'
  stub git-crypt 'git config filter.git-crypt.smudge "git-crypt smudge"'
  launch repoa --request-id r-unlock
  [ "$status" -eq 0 ]
  grep -q "git-crypt unlock $AGENT_SLOT_GIT_CRYPT_KEY" "$CALLS"
}

@test "a file still encrypted after unlock is refused with git-crypt-locked" {
  origin_file repoa .gitattributes 'secret/** filter=git-crypt diff=git-crypt'
  printf '\0GITCRYPT\0rest' >"$T/seed-repoa/secret/x" 2>/dev/null || {
    mkdir -p "$T/seed-repoa/secret"
    printf '\0GITCRYPT\0rest' >"$T/seed-repoa/secret/x"
  }
  git -C "$T/seed-repoa" add secret/x
  git -C "$T/seed-repoa" commit -q -m secret
  git -C "$T/seed-repoa" push -q origin HEAD:main
  stub git-crypt 'git config filter.git-crypt.smudge "git-crypt smudge"'
  launch repoa --request-id r-still
  [ "$status" -eq 78 ]
  jaq -e '.reason == "git-crypt-locked" and .value == "secret/x"' <<<"$stderr"
}

@test "the slot's local Claude settings carry the prime's memory directory and its rewritten permissions only" {
  local prime=$AGENT_SLOT_DEV/repoa project
  project=$AGENT_SLOT_CLAUDE_PROJECTS/some-project-dir
  mkdir -p "$project/memory"
  printf '{"cwd":"%s","type":"user"}\n' "$prime" >"$project/s1.jsonl"
  mkdir -p "$prime/.claude"
  jaq -n --arg p "$prime" '{permissions: {allow: ["Read(/\($p)/**)", "Bash(ls \($p))", "Read(\($p)-old/**)"], deny: []},
    hooks: {Stop: []}, env: {X: "1"}}' >"$prime/.claude/settings.local.json"
  BEFORE=$(fingerprint "$prime")
  launch repoa --request-id r-settings
  [ "$status" -eq 0 ]
  local slot=$AGENT_SLOT_ROOT/repoa/1
  jaq -e --arg mem "$project/memory" --arg s "$slot" --arg p "$prime" '
    (keys == ["autoMemoryDirectory", "permissions"]) and .autoMemoryDirectory == $mem
    and .permissions.allow == ["Read(/\($s)/**)", "Bash(ls \($s))", "Read(\($p)-old/**)"]' "$slot/.claude/settings.local.json"
  [ ! -L "$slot/.claude/settings.local.json" ]
  assert_prime_untouched
}

@test "a tracked link to a sibling repo resolves in the slot through a link to the sibling's prime" {
  prime meum-control
  origin_file meum-control brand/VOICE.md 'the voice'
  git -C "$AGENT_SLOT_DEV/meum-control" pull -q origin main
  origin_symlink repoa VOICE.md ../meum-control/brand/VOICE.md
  launch repoa --request-id r-sib
  [ "$status" -eq 0 ]
  [ "$(cat "$AGENT_SLOT_ROOT/repoa/1/VOICE.md")" = 'the voice' ]
  [ "$(readlink "$AGENT_SLOT_ROOT/repoa/meum-control")" = "$AGENT_SLOT_DEV/meum-control" ]
  jaq -e '.missing_siblings == []' <<<"$output"
}

@test "a tracked link to a sibling with no prime checkout is reported, not fatal" {
  origin_symlink repoa VOICE.md ../nowhere/VOICE.md
  launch repoa --request-id r-nosib
  [ "$status" -eq 0 ]
  jaq -e '.missing_siblings == ["nowhere"]' <<<"$output"
}

@test "a second launch with the same repo and task returns the existing slot" {
  launch repoa --task fix-login
  [ "$status" -eq 0 ]
  launch repoa --task fix-login
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1" and .task == "fix-login"' <<<"$output"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/2" ]
}

@test "a repeat launch by task says its first message was not delivered; a retry of the same request says it was" {
  echo 'first brief' >"$T/brief.md"
  launch repoa --task t1 --request-id r-a --prompt-file "$T/brief.md"
  jaq -e '.created == true and .prompt_delivered == true' <<<"$output"
  launch repoa --task t1 --request-id r-b --prompt-file "$T/brief.md"
  jaq -e '.created == false and .prompt_delivered == false' <<<"$output"
  launch repoa --task t1 --request-id r-a --prompt-file "$T/brief.md"
  jaq -e '.created == false and .prompt_delivered == true' <<<"$output"
  launch repoa --task t2
  jaq -e '.prompt_delivered == null' <<<"$output"
}

@test "a launch's next step is a command the caller on the server can run" {
  launch repoa --request-id r-next
  [ "$status" -eq 0 ]
  jaq -e '.next_step.command == "agent-slot check \(.key) --output json" and .next_step.action == "run"' <<<"$output"
}

@test "AE16: a second launch with the same request ID returns the existing slot; launches with neither each create one" {
  launch repoa --request-id same
  launch repoa --request-id same
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1"' <<<"$output"
  launch repoa
  jaq -e '.key == "repoa/2"' <<<"$output"
  launch repoa
  jaq -e '.key == "repoa/3"' <<<"$output"
}

@test "an unreadable prompt file exits 2 with prompt-file-unreadable and creates nothing" {
  launch repoa --prompt-file "$T/missing.md"
  [ "$status" -eq 2 ]
  jaq -e '.reason == "prompt-file-unreadable"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa" ]
}

@test "a first message with quotes, \$, and newlines reaches Claude unchanged" {
  printf '%s' $'Fix the "login" bug: it'"'"'s $HOME and `date`\nsecond line\n\nfourth' >"$T/brief.md"
  launch repoa --request-id r-prompt --prompt-file "$T/brief.md" --task brief-task
  [ "$status" -eq 0 ]
  mkdir -p "$T/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${@: -1}" >"%s/received"\n' "$T" >"$T/fakebin/claude"
  chmod +x "$T/fakebin/claude"
  (cd "$AGENT_SLOT_ROOT/repoa/1" && PATH="$T/fakebin:$PATH" bash -c "$(cat "$STUBS/typed-repoa-1")")
  cmp "$T/brief.md" "$T/received"
}

@test "the claude session skips permission prompts and gets its session ID, the task only when given, and the first message only when given" {
  launch repoa --request-id r-plain
  session=$(jaq -r .session_id <<<"$output")
  [ "$(cat "$STUBS/typed-repoa-1")" = "claude --dangerously-skip-permissions --session-id $session" ]
  launch repoa --request-id r-task --task t1
  session=$(jaq -r .session_id <<<"$output")
  [ "$(cat "$STUBS/typed-repoa-2")" = "claude --dangerously-skip-permissions --session-id $session -n t1" ]
}

@test "the three sessions are rooted at the slot on the slot server, with the tmuxinator commands typed into shells" {
  launch repoa --request-id r-sessions
  [ "$status" -eq 0 ]
  local name
  for name in repoa-1 repoa-1-files repoa-1-git; do
    grep -qF -- "-L agent-slot-test -f $AGENT_SLOT_TMUX_CONF new-session -d -s $name -c $AGENT_SLOT_ROOT/repoa/1 " "$CALLS"
  done
  [ "$(cat "$STUBS/typed-repoa-1-files")" = 'command -v y >/dev/null && y || yazi' ]
  [ "$(cat "$STUBS/typed-repoa-1-git")" = 'lazygit' ]
  [ "$(grep -c 'send-keys -t =repoa-1-files: Enter' "$CALLS")" -eq 1 ]
}

@test "the launch's ledger line carries requested_at, each phase's duration, and the schema" {
  launch repoa --request-id r-ledger --requested-at 1793000000.5
  [ "$status" -eq 0 ]
  jaq -e -s '.[-1] | .event == "launch" and .request_id == "r-ledger" and .requested_at == 1793000000.5
    and .schema == "dotfiles.agent-slot/1" and (.phases | keys) == ["claude", "clone", "setup", "tmux", "trust"]
    and ([.phases[] | type] | unique) == ["number"]' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "task names with ., :, spaces, or a leading - exit 2 naming the allowed characters" {
  local bad
  for bad in 'a.b' 'a:b' 'a b' '-a'; do
    launch repoa --task "$bad"
    [ "$status" -eq 2 ]
    jaq -e '.reason == "invalid-task-name" and (.message | test("letters, digits"))' <<<"$stderr"
  done
  [ ! -e "$AGENT_SLOT_ROOT/repoa" ]
}

@test "with 8 live slots a ninth launch refuses with slot-limit-reached; the override raises the limit" {
  local n
  for n in 1 2 3 4 5 6 7 8; do slot repoa "$n"; done
  launch repoa --request-id r-nine
  [ "$status" -eq 78 ]
  jaq -e '.reason == "slot-limit-reached" and (.value | split(" ") | length) == 8
    and (.next_step.command | test("AGENT_SLOT_MAX_PER_REPO=9"))' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/9" ]
  AGENT_SLOT_MAX_PER_REPO=9 launch repoa --request-id r-nine
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/9"' <<<"$output"
}

@test "two concurrent launches of different tasks get different slot numbers" {
  "$AGENT_SLOT" launch repoa --task alpha --output json >"$T/a.json" 2>"$T/a.err" &
  local a=$!
  "$AGENT_SLOT" launch repoa --task beta --output json >"$T/b.json" 2>"$T/b.err" &
  wait "$a"
  wait $!
  [ "$(cat "$T/a.json" "$T/b.json" | jaq -s -c '[.[].key] | sort')" = '["repoa/1","repoa/2"]' ]
}

@test "a launch killed mid-clone is rolled back by the next launch, which reuses its number" {
  mkdir -p "$AGENT_SLOT_ROOT/repoa/1/.git"
  echo '{"schema":"dotfiles.agent-slot/1","repo":"repoa","slot":1,"state":"setting-up","request_id":"dead"}' \
    >"$AGENT_SLOT_ROOT/repoa/.1.claim.json"
  launch repoa --request-id r-after
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/1" and .request_id == "r-after" and .created == true' <<<"$output"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/.1.claim.json" ]
  grep -q 'kill-session -t =repoa-1$' "$CALLS"
}

@test "a retry of a request whose slot is still setting up is told to retry, never that its brief landed" {
  mkdir -p "$AGENT_SLOT_ROOT/repoa"
  echo '{"schema":"dotfiles.agent-slot/1","repo":"repoa","slot":1,"state":"setting-up","request_id":"r-live"}' \
    >"$AGENT_SLOT_ROOT/repoa/.1.claim.json"
  spawn flock "$AGENT_SLOT_ROOT/repoa/.1.lock" sleep 60 3>&-
  until [ -n "$(find /proc/$!/fd -lname "$AGENT_SLOT_ROOT/repoa/.1.lock" 2>/dev/null)" ]; do sleep 0.1; done
  echo 'brief' >"$T/brief.md"
  launch repoa --request-id r-live --prompt-file "$T/brief.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  jaq -e '.reason == "slot-busy" and .recovery.retryable == true
    and (.next_step.command | contains("--request-id r-live"))' <<<"$stderr"
}

@test "a launch holding slot 2's lock is left alone: the next launch takes slot 3 and resume of slot 2 waits" {
  slot repoa 1
  echo '{"schema":"dotfiles.agent-slot/1","repo":"repoa","slot":2,"state":"setting-up","request_id":"live"}' \
    >"$AGENT_SLOT_ROOT/repoa/.2.claim.json"
  spawn flock "$AGENT_SLOT_ROOT/repoa/.2.lock" sleep 60 3>&-
  until [ -n "$(find /proc/$!/fd -lname "$AGENT_SLOT_ROOT/repoa/.2.lock" 2>/dev/null)" ]; do sleep 0.1; done
  launch repoa --request-id r-third
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/3"' <<<"$output"
  [ -f "$AGENT_SLOT_ROOT/repoa/.2.claim.json" ]
  SECONDS=0
  run --separate-stderr "$AGENT_SLOT" resume repoa/2 --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-busy"' <<<"$stderr"
  ((SECONDS >= 2))
}

@test "a record write that fails leaves the record as it was, even where errexit is off" {
  slot repoa 1
  local lib=$BATS_TEST_DIRNAME/../scripts/agent-slot/lib record=$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json before
  before=$(cat "$record")
  bash -c 'source "$1/env.sh"; source "$1/contract.sh"; source "$1/record.sh"; agent_slot_env "$1/.."
    record_write repoa 1 "not json" || true' _ "$lib"
  [ "$(cat "$record")" = "$before" ]
}

@test "two writers updating one record both land" {
  slot repoa 1
  local lib=$BATS_TEST_DIRNAME/../scripts/agent-slot/lib
  cat >"$T/writer.sh" <<EOF
set -euo pipefail
source "$lib/env.sh"; source "$lib/contract.sh"; source "$lib/record.sh"
agent_slot_env "$lib/.."
for i in \$(seq 1 15); do record_update repoa 1 --arg k "\$1" --argjson i "\$i" '.[\$k] = \$i'; done
EOF
  bash "$T/writer.sh" first &
  local a=$!
  bash "$T/writer.sh" second &
  wait "$a"
  wait $!
  jaq -e '.first == 15 and .second == 15 and .repo == "repoa"' "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json"
}

@test "resume of a dormant slot starts its three sessions, the Claude one resuming the recorded session with permission prompts skipped" {
  slot repoa 1 '{"session_id": "aaaaaaaa-1111-2222-3333-444444444444"}'
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1"
  : >"$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.started == ["repoa-1", "repoa-1-files", "repoa-1-git"]' <<<"$output"
  [ "$(cat "$STUBS/typed-repoa-1")" = 'claude --dangerously-skip-permissions --resume aaaaaaaa-1111-2222-3333-444444444444' ]
}

@test "resume of a slot whose conversation Claude never saved starts Claude with its session ID and task, as launch does" {
  slot repoa 1 '{"session_id": "aaaaaaaa-1111-2222-3333-444444444444", "task": "fix-login"}'
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  [ "$(cat "$STUBS/typed-repoa-1")" = 'claude --dangerously-skip-permissions --session-id aaaaaaaa-1111-2222-3333-444444444444 -n fix-login' ]
}

@test "a session ID in the record that holds shell syntax is typed as one argument" {
  slot repoa 1 "$(jaq -n -c --arg s "x; touch $T/pwned" '{session_id: $s}')"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  mkdir -p "$T/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${@: -1}" >"%s/received"\n' "$T" >"$T/fakebin/claude"
  chmod +x "$T/fakebin/claude"
  PATH="$T/fakebin:$PATH" bash -c "$(cat "$STUBS/typed-repoa-1")"
  [ ! -e "$T/pwned" ]
  [ "$(cat "$T/received")" = "x; touch $T/pwned" ]
}

@test "two concurrent resumes create each session once" {
  slot repoa 1
  "$AGENT_SLOT" resume repoa/1 --output json >/dev/null 2>&1 &
  local a=$!
  "$AGENT_SLOT" resume repoa/1 --output json >/dev/null 2>&1 &
  wait "$a"
  wait $!
  [ "$(grep -c 'new-session' "$CALLS")" -eq 3 ]
  [ "$(sort -u "$STUBS/tmux-sessions" | wc -l)" -eq 3 ]
}

@test "resume of a slot that is gone exits 1 with slot-not-found" {
  run --separate-stderr "$AGENT_SLOT" resume repoa/7 --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-not-found"' <<<"$stderr"
}
