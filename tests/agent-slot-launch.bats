#!/usr/bin/env bats
# agent-slot launch and resume: claiming a slot, setting it up like the prime checkout, starting its tmux sessions, and
# rolling back what never finished.
#
# Run: bats tests/agent-slot-launch.bats
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

# head_on_origin_changes FILE CONTENT: launches PR 7, whose head on origin is one commit past main and changes only FILE,
# and expects its install left to the agent. Any tracked file can change what an install runs, so no list of files would do.
head_on_origin_changes() {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" switch -q -c feat/x
  mkdir -p "$(dirname "$T/seed-repoa/$1")"
  printf '%s\n' "$2" >"$T/seed-repoa/$1"
  git -C "$T/seed-repoa" add "$1"
  git -C "$T/seed-repoa" commit -q -m 'the head'
  git -C "$T/seed-repoa" push -q origin feat/x feat/x:refs/pull/7/head
  git -C "$T/seed-repoa" switch -q main
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1/node_modules" ]
  jaq -e '.deps.status == "head-not-on-base" and .deps.command == "bun install --frozen-lockfile" and .state == "active"' <<<"$output"
}

# github_origin: repoa's prime with its origin at GitHub's https URL for up/repoa, which the test's git config rewrites
# to the local bare origin, and gh answering from gh_item's fixtures.
github_origin() {
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/origins/.insteadOf" https://github.com/up/
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin https://github.com/up/repoa.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  stub_gh_items
}

# fork_urls: GitHub's https and ssh URLs for me/repoa, rewritten to a bare repo under $T/forks that fork_repo makes.
fork_urls() {
  git config --file "$GIT_CONFIG_GLOBAL" --add "url.$T/forks/.insteadOf" https://github.com/me/
  git config --file "$GIT_CONFIG_GLOBAL" --add "url.$T/forks/.insteadOf" git@github.com:me/
}

fork_repo() {
  fork_urls
  git clone -q --bare "$T/origins/repoa.git" "$T/forks/repoa.git"
}

# pr_head BARE BRANCH N: a commit on top of main pushed to BRANCH of the bare repo BARE, when BRANCH is not empty, and to
# origin's refs/pull/N/head, where GitHub keeps every PR's head. Sets HEAD_SHA.
pr_head() {
  HEAD_SHA=$(git -C "$T/seed-repoa" commit-tree -p HEAD -m "work for #$3" 'HEAD^{tree}')
  [ -z "$2" ] || git -C "$T/seed-repoa" push -q "$1" "$HEAD_SHA:refs/heads/$2"
  git -C "$T/seed-repoa" push -q "$T/origins/repoa.git" "$HEAD_SHA:refs/pull/$3/head"
}

SAME_REPO_HEAD='{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
FORK_HEAD='{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_2", "login": "me"}, "isCrossRepository": true}'

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

# split_prime_named: the prime ~/obsidian-vault's shape gives agent-slot, trusted so its slots start with no dialog. Sets
# SPLIT_PRIME, its checkout, SPLIT_GIT_DIR, its git directory, and SPLIT_SLOT, where its first slot goes.
split_prime_named() {
  SPLIT_PRIME=$T/outside/vault SPLIT_GIT_DIR=$AGENT_SLOT_DEV/vault-git SPLIT_SLOT=$AGENT_SLOT_ROOT/vault/1
  split_prime "$SPLIT_PRIME" "$SPLIT_GIT_DIR"
  export AGENT_SLOT_EXTRA_PRIMES=$SPLIT_PRIME
  trusted "$SPLIT_PRIME" "$(realpath -m "$SPLIT_SLOT")"
}

@test "a prime with a separate git dir gets an ordinary clone, set up like any slot, and stays untouched" {
  split_prime_named
  BEFORE=$(fingerprint "$SPLIT_PRIME")
  GIT_BEFORE=$(fingerprint "$SPLIT_GIT_DIR")
  launch vault --request-id r-split --task t1
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .key == "vault/1" and .base == "main" and .trust_prompt_expected == false' <<<"$output"
  [ -d "$SPLIT_SLOT/.git" ]
  [ ! -s "$SPLIT_SLOT/.git/objects/info/alternates" ]
  [ "$(git -C "$SPLIT_SLOT" config --get remote.origin.url)" = "$T/origins/vault.git" ]
  [ "$(git -C "$SPLIT_SLOT" symbolic-ref --short HEAD)" = main ]
  [ -L "$SPLIT_SLOT/docs/solutions" ]
  [ -f "$SPLIT_SLOT/.claude/settings.local.json" ]
  jaq -e --arg p "$SPLIT_PRIME" '.prime == $p' "$SPLIT_SLOT/.git/agent-slot.json"
  [ "$(cat "$STUBS/typed-vault-1")" = "claude --dangerously-skip-permissions --session-id $(jaq -r .session_id \
    "$SPLIT_SLOT/.git/agent-slot.json") -n t1" ]
  [ "$(fingerprint "$SPLIT_PRIME")" = "$BEFORE" ]
  [ "$(fingerprint "$SPLIT_GIT_DIR")" = "$GIT_BEFORE" ]
}

# A reference git cannot use costs no error, only a full transfer, so the clone has to be seen asking for nothing.
@test "a slot's clone borrows from a prime with a separate git dir instead of transferring its objects" {
  split_prime_named
  git -C "$SPLIT_PRIME" remote set-url origin "file://$T/origins/vault.git"
  export GIT_TRACE_PACKET=$T/packets
  launch vault --request-id r-borrow
  unset GIT_TRACE_PACKET
  [ "$status" -eq 0 ]
  [ -s "$T/packets" ]
  run ! grep -qE 'clone> (want|fetch)|clone> command=fetch' "$T/packets"
}

@test "a hook installed in a prime's separate git dir is copied into the slot, as one in a .git directory is" {
  split_prime_named
  printf '#!/bin/sh\nexit 0\n' >"$SPLIT_GIT_DIR/hooks/pre-commit"
  chmod +x "$SPLIT_GIT_DIR/hooks/pre-commit"
  launch vault --request-id r-split-hook
  [ "$status" -eq 0 ]
  [ -x "$SPLIT_SLOT/.git/hooks/pre-commit" ]
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
  rm -rf "$AGENT_SLOT_SOLUTIONS"
  launch repoa --request-id r-ae2
  [ "$status" -eq 78 ]
  jaq -e '.reason == "solutions-symlink-missing" and (.message | test("symlink could not be created"))' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/.1.claim.json" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
  assert_prime_untouched
}

# assert_own_worktree N: repoa/N's docs/solutions links to a linked worktree of the corpus, detached at origin/main,
# under the repo's .solutions directory, and the record names it. Sets WT to its path.
assert_own_worktree() {
  local slot=$AGENT_SLOT_ROOT/repoa/$1
  WT=$(readlink "$slot/docs/solutions")
  [[ $WT == "$AGENT_SLOT_ROOT/repoa/.solutions/$1-"* ]]
  [ "$(jaq -r .solutions_worktree "$slot/.git/agent-slot.json")" = "$WT" ]
  solutions_worktrees | grep -qxF "$WT"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$AGENT_SLOT_SOLUTIONS" rev-parse refs/remotes/origin/main)" ]
  ! git -C "$WT" symbolic-ref -q HEAD
}

@test "every slot's docs/solutions links to its own worktree of the shared repo, and the shared clone's tree is untouched" {
  local before
  before=$(fingerprint "$AGENT_SLOT_SOLUTIONS" | grep -v '\./\.git')
  launch repoa --request-id r-sol
  [ "$status" -eq 0 ]
  assert_own_worktree 1
  [ "$(fingerprint "$AGENT_SLOT_SOLUTIONS" | grep -v '\./\.git')" = "$before" ]
  [ -z "$(git -C "$AGENT_SLOT_SOLUTIONS" status --porcelain)" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "two slots of one repo get two different worktrees" {
  launch repoa --request-id r-sol1
  [ "$status" -eq 0 ]
  launch repoa --request-id r-sol2
  [ "$status" -eq 0 ]
  assert_own_worktree 1
  local first=$WT
  assert_own_worktree 2
  [ "$WT" != "$first" ]
  [ "$(solutions_worktrees | grep -c .)" -eq 2 ]
}

@test "a tracked docs/solutions link is pointed at the slot's worktree, and git status in the slot stays clean" {
  origin_symlink repoa docs/solutions ../../dev/solutions-docs
  launch repoa --request-id r-tracked
  [ "$status" -eq 0 ]
  assert_own_worktree 1
  [ -z "$(git -C "$AGENT_SLOT_ROOT/repoa/1" status --porcelain --untracked-files=no)" ]
  git -C "$AGENT_SLOT_ROOT/repoa/1" add -A
  git -C "$AGENT_SLOT_ROOT/repoa/1" add -f -- docs/solutions 2>/dev/null || true
  [ -z "$(git -C "$AGENT_SLOT_ROOT/repoa/1" diff --cached --name-only -- docs/solutions)" ]
}

@test "with the corpus's origin unreachable, the worktree is still made at the local origin/main" {
  mv "$T/solutions-origin.git" "$T/solutions-origin.away"
  launch repoa --request-id r-offline
  [ "$status" -eq 0 ]
  assert_own_worktree 1
}

@test "a corpus with no origin/main refuses with solutions-symlink-missing and leaves no slot and no worktree" {
  git -C "$AGENT_SLOT_SOLUTIONS" update-ref -d refs/remotes/origin/main
  mv "$T/solutions-origin.git" "$T/solutions-origin.away"
  launch repoa --request-id r-noref
  [ "$status" -eq 78 ]
  jaq -e '.reason == "solutions-symlink-missing" and (.message | test("origin/main"))' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ -z "$(ls -A "$AGENT_SLOT_ROOT/repoa/.solutions" 2>/dev/null)" ]
  [ -z "$(solutions_worktrees)" ]
  assert_prime_untouched
}

@test "a setup that fails after the worktree is made removes the worktree and its registration" {
  stub tmux 'exit 1'
  launch repoa --request-id r-rollback
  [ "$status" -ne 0 ]
  jaq -e '.reason == "tmux-failed"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ -z "$(ls -A "$AGENT_SLOT_ROOT/repoa/.solutions" 2>/dev/null)" ]
  [ -z "$(solutions_worktrees)" ]
}

# An unlocked clone of a git-crypt repo is plaintext, so a failed launch cannot leave it in the trash.
@test "a setup that fails after the clone purges the clone from the trash, and logs the purge" {
  stub tmux 'exit 1'
  launch repoa --request-id r-rollback-purge
  [ "$status" -ne 0 ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ -z "$(find "$TRASH/files" "$TRASH/info" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
  jaq -e -s 'any(.[]; .event == "purge" and .repo == "repoa" and .slot == 1 and .purged == true)' \
    "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "a slot links .context/repo-recon to its origin's repo-recon store before its upstream's, and writes no store" {
  github_origin
  git -C "$AGENT_SLOT_DEV/repoa" remote add upstream https://github.com/parent/repoa.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  recon_store parent/repoa
  recon_store up/repoa
  local before
  before=$(fingerprint "$AGENT_SLOT_REPO_RECON")
  launch repoa --request-id r-recon
  [ "$status" -eq 0 ]
  [ "$(readlink "$AGENT_SLOT_ROOT/repoa/1/.context/repo-recon")" = "$STORE" ]
  [ "$(fingerprint "$AGENT_SLOT_REPO_RECON")" = "$before" ]
  assert_prime_untouched
}

@test "a fork's slot links the store of the prime's upstream remote, matching its host and name in any case" {
  github_origin
  git -C "$AGENT_SLOT_DEV/repoa" remote add upstream git@GitHub.com:Parent/RepoA.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  recon_store parent/repoa
  launch repoa --request-id r-recon-fork
  [ "$status" -eq 0 ]
  [ "$(readlink "$AGENT_SLOT_ROOT/repoa/1/.context/repo-recon")" = "$STORE" ]
  assert_prime_untouched
}

@test "a slot of a repo with no repo-recon store gets no link, and no store is made" {
  github_origin
  git -C "$AGENT_SLOT_DEV/repoa" remote add upstream https://github.com/parent/repoa.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  recon_store other/repob
  local before
  before=$(fingerprint "$AGENT_SLOT_REPO_RECON")
  launch repoa --request-id r-recon-none
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1/.context" ]
  [ "$(fingerprint "$AGENT_SLOT_REPO_RECON")" = "$before" ]
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

@test "a launch with no slot tmux server starts it in a transient user scope wrapped around the empty-environment start" {
  launch repoa --request-id r-scope
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUBS/systemd-run.log")" -eq 1 ]
  local line
  line=$(cat "$STUBS/systemd-run.log")
  [[ $line == *" --user "* && $line == *" --scope "* && $line == *" --collect "* ]]
  [[ $line =~ \ --unit=agent-slots-tmux-[0-9]+-[0-9]+\ .*\ /usr/bin/env\ -i\ -C\ /\ .*\ new-session\ -d\ -s\ repoa-1\  ]]
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' | diff - "$STUBS/tmux-sessions"
}

@test "each start of the slot tmux server gets a scope of its own, past the old scopes orphaned shells keep alive" {
  launch repoa --request-id r-scope-1
  [ "$status" -eq 0 ]
  rm "$STUBS/tmux-sessions"
  launch repoa --request-id r-scope-2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUBS/systemd-run.log")" -eq 2 ]
  [ "$(sort -u "$STUBS/systemd-run.units" | wc -l)" -eq 2 ]
  grep -qx repoa-2 "$STUBS/tmux-sessions"
}

@test "a launch from a shell with no XDG_RUNTIME_DIR hands systemd-run the user's runtime directory" {
  run --separate-stderr env -u XDG_RUNTIME_DIR "$AGENT_SLOT" launch repoa --request-id r-xdg --output json
  [ "$status" -eq 0 ]
  grep -q "^XDG_RUNTIME_DIR=/run/user/$(id -u) .* --scope " "$STUBS/systemd-run.log"
}

@test "with the slot tmux server running, a launch starts its sessions without a scope" {
  echo other-1 >"$STUBS/tmux-sessions"
  launch repoa --request-id r-running
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/systemd-run.log" ]
  printf 'other-1\nrepoa-1\nrepoa-1-files\nrepoa-1-git\n' | diff - "$STUBS/tmux-sessions"
}

@test "with no user manager answering, or no systemd-run, a launch starts the slot tmux server directly" {
  : >"$STUBS/systemd-run.no-bus"
  launch repoa --request-id r-no-bus
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUBS/systemd-run.log")" -eq 1 ]
  [ ! -e "$STUBS/systemd-run.units" ]
  printf 'repoa-1\nrepoa-1-files\nrepoa-1-git\n' | diff - "$STUBS/tmux-sessions"
  rm "$STUBS/tmux-sessions"
  AGENT_SLOT_SYSTEMD_RUN=$T/no-such-systemd-run launch repoa --request-id r-no-systemd-run
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUBS/systemd-run.log")" -eq 1 ]
  grep -qx repoa-2 "$STUBS/tmux-sessions"
}

# ssh_origins [SLOW]: points the prime's origin and the solutions repo's origin at ssh URLs served by an ssh stub, which
# runs the remote git command against the bare repo on this host. Each call logs its start and end times, the $SHELL it
# was given, and its argv to $STUBS/ssh.log; a call whose command names SLOW takes a second longer, as a remote does.
ssh_origins() {
  cat >"$STUBS/ssh" <<EOF
#!/usr/bin/env bash
cmd=\${!#}
printf '%s start SHELL=%s %s\n' "\$EPOCHREALTIME" "\${SHELL-}" "\$*" >>'$STUBS/ssh.log'
[[ -z '${1:-}' || \$cmd != *'${1:-}'* ]] || sleep 1
sh -c "\$cmd"
rc=\$?
printf '%s end %s\n' "\$EPOCHREALTIME" "\$cmd" >>'$STUBS/ssh.log'
exit \$rc
EOF
  chmod +x "$STUBS/ssh"
  export AGENT_SLOT_SSH=$STUBS/ssh
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin "ssh://example.invalid$T/origins/repoa.git"
  git -C "$AGENT_SLOT_SOLUTIONS" remote set-url origin "ssh://example.invalid$T/solutions-origin.git"
}

@test "every git call that reaches a remote runs ssh in batch mode, with /bin/sh for the ssh config's Match exec lines" {
  ssh_origins
  launch repoa --request-id r-ssh
  [ "$status" -eq 0 ]
  [ "$(grep -c ' start ' "$STUBS/ssh.log")" -eq 2 ]
  grep ' start .*repoa.git' "$STUBS/ssh.log"
  grep ' start .*solutions-origin.git' "$STUBS/ssh.log"
  run grep -v ' start SHELL=/bin/sh -o BatchMode=yes ' <(grep ' start ' "$STUBS/ssh.log")
  [ "$status" -eq 1 ]
}

@test "the solutions repo's fetch runs while the clone does, since both wait on the network" {
  local clone_end fetch_start
  ssh_origins repoa.git
  launch repoa --request-id r-overlap
  [ "$status" -eq 0 ]
  clone_end=$(awk '$2 == "end" && /repoa.git/ { print $1; exit }' "$STUBS/ssh.log")
  fetch_start=$(awk '$2 == "start" && /solutions-origin.git/ { print $1; exit }' "$STUBS/ssh.log")
  [ -n "$clone_end" ] && [ -n "$fetch_start" ]
  awk -v f="$fetch_start" -v c="$clone_end" 'BEGIN { exit !(f < c) }'
}

@test "the launch's ledger line carries requested_at, each phase's duration, and the schema" {
  launch repoa --request-id r-ledger --requested-at 1793000000.5
  [ "$status" -eq 0 ]
  jaq -e -s '.[-1] | .event == "launch" and .request_id == "r-ledger" and .requested_at == 1793000000.5
    and .schema == "dotfiles.agent-slot/1" and (.phases | keys) == ["claude", "clone", "deps", "setup", "tmux", "trust"]
    and ([.phases[] | type] | unique) == ["number"]' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "a key's launch line carries when its tab opened and was shown, and when the slot's setup started and ended" {
  launch repoa --request-id r-key --requested-at 1793000002.5 --opened-at 1793000000.25 --shown-at 1793000002.25
  [ "$status" -eq 0 ]
  jaq -e -s '.[-1] | .event == "launch" and .opened_at == 1793000000.25 and .shown_at == 1793000002.25
    and .started_at > .requested_at and .made_at >= .started_at
    and .made_at - .started_at >= ([.phases[]] | add) - 0.01' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  launch repoa --request-id r-agent
  [ "$status" -eq 0 ]
  jaq -e -s '.[-1] | .request_id == "r-agent" and .opened_at == null and .shown_at == null
    and (.started_at | type) == "number"' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
}

@test "--opened-at and --shown-at take seconds since the epoch, and refuse anything else before touching a slot" {
  local flag
  for flag in --opened-at --shown-at; do
    launch repoa "$flag" yesterday
    [ "$status" -eq 2 ]
    jaq -e --arg f "$flag" '.reason == "usage" and .value == "yesterday" and (.message | startswith($f))' <<<"$stderr"
  done
  [ ! -e "$AGENT_SLOT_ROOT/repoa" ]
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
  slot repoa 1 '{"session_id": "aaaaaaaa-1111-2222-3333-444444444444", "task": "fix-login", "name": "repoa-pr7-fix-login",
    "prompt_file": "/srv/slots/repoa/1/.git/agent-slot-prompt.md"}'
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1"
  : >"$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  jaq -e '.started == ["repoa-1", "repoa-1-files", "repoa-1-git"]' <<<"$output"
  [ "$(cat "$STUBS/typed-repoa-1")" = 'claude --dangerously-skip-permissions --resume aaaaaaaa-1111-2222-3333-444444444444 -n repoa-pr7-fix-login' ]
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

@test "launch --pr of a same-repo PR checks out its head tracking origin and names the slot and its Claude session" {
  github_origin
  pr_head "$T/origins/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD"
  launch repoa --pr 7 --request-id r-pr
  [ "$status" -eq 0 ]
  local slot=$AGENT_SLOT_ROOT/repoa/1 session
  local items='[{"kind": "pr", "repo": "up/repoa", "number": 7, "title": "Fix the login"}]'
  jaq -e --argjson items "$items" '.created == true and .name == "repoa-pr7-fix-the-login"
    and .task == "repoa-pr7-fix-the-login" and .label_name == "repoa-pr7-fix-the-login" and .items == $items
    and .head_pushable == true' <<<"$output"
  session=$(jaq -r .session_id <<<"$output")
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$slot" rev-parse --abbrev-ref 'feat/x@{upstream}')" = origin/feat/x ]
  [ "$(cat "$STUBS/typed-repoa-1")" = "claude --dangerously-skip-permissions --session-id $session -n repoa-pr7-fix-the-login" ]
  jaq -e --argjson items "$items" '.items == $items and .name == "repoa-pr7-fix-the-login"
    and .named_as == "repoa-pr7-fix-the-login" and .prs == [7] and .task == "repoa-pr7-fix-the-login"' \
    "$slot/.git/agent-slot.json"
  jaq -e -s --argjson items "$items" '.[-1] | .event == "launch" and .items == $items
    and .name == "repoa-pr7-fix-the-login"' "$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  assert_prime_untouched
}

@test "launch --pr of a PR from a fork adds remote fork at the head repo's URL and checks out the head pushing there" {
  github_origin
  fork_repo
  pr_head "$T/forks/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local slot=$AGENT_SLOT_ROOT/repoa/1
  jaq -e '.head_pushable == true and .name == "repoa-pr7-fix-the-login"' <<<"$output"
  [ "$(git -C "$slot" config --get remote.fork.url)" = https://github.com/me/repoa.git ]
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$slot" for-each-ref --format='%(upstream:short) %(push:remotename)' refs/heads/feat/x)" = 'fork/feat/x fork' ]
}

# bun_repo: makes repoa's origin a bun repo, with a bun stub whose prepare script leaves a mark, as a real install runs
# the head's lifecycle scripts.
bun_repo() {
  origin_file repoa .gitignore 'node_modules/'
  origin_file repoa package.json '{"name": "repoa"}'
  origin_file repoa bun.lock 'locked'
  stub bun 'mkdir -p node_modules; touch "$STUBS/prepare-ran"'
  export AGENT_SLOT_BUN=$STUBS/bun
  mkdir -p "$AGENT_SLOT_DEV/repoa/node_modules/some-tool"
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
}

@test "launch --pr never runs a fork head's install, which would run a stranger's lifecycle scripts unread" {
  github_origin
  bun_repo
  fork_repo
  pr_head "$T/forks/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1/node_modules" ]
  jaq -e '.deps.status == "head-not-on-base" and .deps.command == "bun install --frozen-lockfile" and .state == "active"' <<<"$output"
}

@test "launch --pr never runs the install of a head that only refs/pull/N/head still holds" {
  github_origin
  bun_repo
  pr_head "$T/origins/repoa.git" "" 7
  gh_item pr 7 "Fix the login" CLOSED '{"headRefName": "feat/x", "headRepository": null, "headRepositoryOwner": null}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(git -C "$AGENT_SLOT_ROOT/repoa/1" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "head-not-on-base"' <<<"$output"
}

@test "launch --pr leaves a head on origin that changes the lockfile to its agent" {
  head_on_origin_changes bun.lock 'a release younger than the age gate allows'
}

@test "launch --pr leaves a head on origin that changes only package.json to its agent" {
  head_on_origin_changes package.json '{"name": "repoa", "scripts": {"postinstall": "./evil"}}'
}

@test "launch --pr leaves a head on origin that adds only .npmrc to its agent" {
  head_on_origin_changes .npmrc 'script-shell=./evil'
}

@test "launch --pr leaves a head on origin that adds only npm-shrinkwrap.json to its agent" {
  head_on_origin_changes npm-shrinkwrap.json '{"lockfileVersion": 3}'
}

@test "launch --pr leaves a head on origin that changes only a file a lifecycle script calls to its agent" {
  head_on_origin_changes scripts/build.js 'evil()'
}

@test "launch --pr leaves a PR from a branch named dev to its agent, on a repo the prime holds no dev for" {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" switch -q -c dev
  printf '%s\n' '{"name": "repoa", "scripts": {"postinstall": "./evil"}}' >"$T/seed-repoa/package.json"
  git -C "$T/seed-repoa" add package.json
  git -C "$T/seed-repoa" commit -q -m 'the head'
  git -C "$T/seed-repoa" push -q origin dev dev:refs/pull/7/head
  git -C "$T/seed-repoa" switch -q main
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "dev", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "head-not-on-base"' <<<"$output"
}

@test "launch --pr holds a PR's head to the PR's own base, even where the prime holds the head's branch" {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" switch -q -c dev
  git -C "$T/seed-repoa" commit -q --allow-empty -m 'the head'
  git -C "$T/seed-repoa" push -q origin dev dev:refs/pull/7/head
  git -C "$T/seed-repoa" switch -q main
  git -C "$AGENT_SLOT_DEV/repoa" fetch -q origin dev:refs/heads/dev
  gh_item pr 7 "Release" OPEN '{"headRefName": "dev", "baseRefName": "main", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "head-not-on-base" and .deps.off_base == "pr-base-lacks-head"' <<<"$output"
}

@test "launch --pr with no base from gh is off the base rather than unchecked" {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" push -q origin main:refs/heads/feat/x main:refs/pull/7/head
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "head-not-on-base" and .deps.off_base == "pr-base-lacks-head"' <<<"$output"
}

@test "launch --pr on a head set back to an older commit of the base does not install" {
  github_origin
  bun_repo
  origin_file repoa notes.txt 'later'
  git -C "$T/seed-repoa" push -q origin main~1:refs/heads/feat/x main~1:refs/pull/7/head
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x", "baseRefName": "main", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "head-not-on-base" and .deps.off_base == "pr-head-behind-base"' <<<"$output"
}

@test "launch --pr installs a head that is the tip of its PR's base" {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" push -q origin main:refs/heads/feat/x main:refs/pull/7/head
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x", "baseRefName": "main", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.status == "installed"' <<<"$output"
}

@test "launch --pr on a fork head with a prime never installed reads prime-not-set-up, and runs nothing" {
  github_origin
  bun_repo
  rm -rf "$AGENT_SLOT_DEV/repoa/node_modules"
  fork_repo
  pr_head "$T/forks/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$STUBS/prepare-ran" ]
  jaq -e '.deps.off_base == "base-lacks-head"' <<<"$output"
  jaq -e '.deps.status == "prime-not-set-up"' <<<"$output"
}

@test "launch --pr leaves a head behind a base lockfile change to its agent, without claiming it changed the lockfile" {
  github_origin
  bun_repo
  git -C "$T/seed-repoa" switch -q -c feat/x
  git -C "$T/seed-repoa" commit -q --allow-empty -m 'the head'
  git -C "$T/seed-repoa" push -q origin feat/x feat/x:refs/pull/7/head
  git -C "$T/seed-repoa" switch -q main
  origin_file repoa bun.lock 'a newer lock on the base'
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "head-not-on-base"' <<<"$output"
}

@test "a fork head whose URL a prime remote holds in the other form gets that remote's name in the slot" {
  github_origin
  fork_repo
  git -C "$AGENT_SLOT_DEV/repoa" remote add mine git@github.com:me/repoa.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  pr_head "$T/forks/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local slot=$AGENT_SLOT_ROOT/repoa/1
  [ "$(git -C "$slot" remote | sort | paste -sd ' ' -)" = 'mine origin' ]
  [ "$(git -C "$slot" for-each-ref --format='%(upstream:short) %(push:remotename)' refs/heads/feat/x)" = 'mine/feat/x mine' ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  assert_prime_untouched
}

@test "a head whose branch or repository is gone is checked out from refs/pull/N/head under its name, with no upstream" {
  github_origin
  pr_head '' '' 7
  local gone_branch=$HEAD_SHA
  gh_item pr 7 "Fix the login" MERGED "$SAME_REPO_HEAD"
  pr_head '' '' 8
  gh_item pr 8 "Fix the logout" CLOSED '{"headRefName": "feat/y", "headRepository": null,
    "headRepositoryOwner": null, "isCrossRepository": true}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.head_pushable == false' <<<"$output"
  local slot=$AGENT_SLOT_ROOT/repoa/1
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$gone_branch" ]
  [ -z "$(git -C "$slot" for-each-ref --format='%(upstream)' refs/heads/feat/x)" ]
  launch repoa --pr 8
  [ "$status" -eq 0 ]
  jaq -e '.key == "repoa/2" and .head_pushable == false' <<<"$output"
  slot=$AGENT_SLOT_ROOT/repoa/2
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/y ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ -z "$(git -C "$slot" for-each-ref --format='%(upstream)' refs/heads/feat/y)" ]
  [ "$(git -C "$slot" remote)" = origin ]
}

@test "a fork fetch that fails for another reason rolls the slot back with retryable clone-failed naming the remote" {
  github_origin
  fork_urls
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  launch repoa --pr 7 --request-id r-fork
  [ "$status" -eq 1 ]
  jaq -e '.reason == "clone-failed" and .value == "fork" and .recovery.retryable == true
    and .recovery.side_effects == "none" and .next_step.command == "agent-slot launch repoa --pr 7 --request-id r-fork"' \
    <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/.1.claim.json" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
  assert_prime_untouched
}

@test "launch --issue keeps the base checked out, records the issue, and names the slot; a given task stays as given" {
  github_origin
  gh_item issue 12 "Widget breaks on resize"
  launch repoa --issue 12 --task widget
  [ "$status" -eq 0 ]
  local slot=$AGENT_SLOT_ROOT/repoa/1 session
  local items='[{"kind": "issue", "repo": "up/repoa", "number": 12, "title": "Widget breaks on resize"}]'
  jaq -e --argjson items "$items" '.name == "repoa-issue12-widget-breaks-on-resize" and .task == "widget"
    and .items == $items and .head_pushable == null' <<<"$output"
  session=$(jaq -r .session_id <<<"$output")
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = main ]
  jaq -e '.prs == [] and .named_as == "repoa-issue12-widget-breaks-on-resize"' "$slot/.git/agent-slot.json"
  [ "$(cat "$STUBS/typed-repoa-1")" = "claude --dangerously-skip-permissions --session-id $session -n repoa-issue12-widget-breaks-on-resize" ]
}

@test "launch --pr of an item a torn-down slot worked on reports that slot as prior and names reopen" {
  github_origin
  pr_head "$T/origins/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD"
  gh_item issue 12 "Fix the widget"
  mkdir -p "$AGENT_SLOT_STATE_DIR"
  jaq -n -c '{schema: "dotfiles.agent-slot/1", ts: "2026-10-01T00:00:00Z", event: "teardown", repo: "repoa", slot: 3,
    session_id: "aaaaaaaa-1111-2222-3333-444444444444", prs: [7], items: []}' >>"$AGENT_SLOT_STATE_DIR/ledger.jsonl"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .prior.session_id == "aaaaaaaa-1111-2222-3333-444444444444"
    and .prior.ts == "2026-10-01T00:00:00Z" and (.prior.note | contains("agent-slot reopen repoa --pr 7"))' <<<"$output"
  launch repoa --issue 12
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .prior == null' <<<"$output"
}

@test "--pr with --issue fails before anything is claimed" {
  launch repoa --pr 7 --issue 12
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa" ]
  [ "$(grep -c '^gh ' "$CALLS")" -eq 0 ]
}

@test "a repeat launch --pr returns the slot that holds the PR, even after the PR's title changed" {
  github_origin
  pr_head "$T/origins/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  gh_item pr 7 "Fix the login page" OPEN "$SAME_REPO_HEAD"
  launch repoa --pr up/repoa#7
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1" and .name == "repoa-pr7-fix-the-login"' <<<"$output"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/2" ]
}

@test "an item takes GitHub's name for its repo, and a ref or origin URL in another case still finds the slot holding it" {
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/origins/.insteadOf" https://github.com/Up/
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin https://github.com/Up/repoa.git
  BEFORE=$(fingerprint "$AGENT_SLOT_DEV/repoa")
  stub_gh_items
  pr_head "$T/origins/repoa.git" feat/x 7
  gh_item pr 7 "Fix the login" OPEN "$SAME_REPO_HEAD" up/repoa
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.created == true and .items[0].repo == "up/repoa"' <<<"$output"
  jaq -e '.prs == [7]' "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json"
  launch repoa --pr UP/REPOA#7
  [ "$status" -eq 0 ]
  jaq -e '.created == false and .key == "repoa/1"' <<<"$output"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/2" ]
  assert_prime_untouched
}

@test "launch's help documents --pr and --issue with the ref forms, and names name and items among its returns" {
  run "$AGENT_SLOT" launch --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot launch <repo> [--pr <ref> | --issue <ref>]"* ]]
  [[ $output == *"owner/name#N"*"https://github.com/owner/name/pull/N"* ]]
  [[ $output == *$'\nreturns: '*name*items*label_name*head_pushable* ]]
  [[ $output == *"example: agent-slot launch "*"--pr "* ]]
}
