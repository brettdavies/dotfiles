#!/usr/bin/env bats
# A slot whose head comes from another person's fork runs nothing from that head: no Claude project or local settings,
# no git hooks, and no setup step that follows or acts on what the head tracks. Origin's own heads and the heads of a
# trusted owner's forks keep the full setup.
#
# Run: bats tests/agent-slot-foreign-head.bats
#
# Each head tracks a Claude settings hook and git hooks that touch a marker under $T/marks. git is real, so the git hook
# tests run real commits and pushes. Claude is the suite's stub, except in the tests that run a typed line through the
# real binary: those give it a config directory of its own and an API port nothing listens on, and skip where Claude
# Code is not installed.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  REAL_CLAUDE=$(command -v claude || true)
  agent_slot_setup
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/projects AGENT_SLOT_LOCK_WAIT=2 AGENT_SLOT_TRUST_TIMEOUT=3
  export AGENT_SLOT_TRUSTED_OWNERS=me
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS" "$T/marks" "$T/outside"
  prime repoa
  local n owner
  for n in 1 2 3; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/origins/.insteadOf" https://github.com/up/
  for owner in me evil; do
    mkdir -p "$T/forks/$owner"
    git config --file "$GIT_CONFIG_GLOBAL" "url.$T/forks/$owner/.insteadOf" "https://github.com/$owner/"
    git clone -q --bare "$T/origins/repoa.git" "$T/forks/$owner/repoa.git"
  done
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin https://github.com/up/repoa.git
  git -C "$AGENT_SLOT_DEV/repoa" config core.hooksPath .githooks
  stub_gh_items
  printf 'say ok\n' >"$T/brief"
  SLOT=$AGENT_SLOT_ROOT/repoa/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
}

teardown() {
  stop_spawned
  assert_no_leaks
}

launch() {
  run --separate-stderr "$AGENT_SLOT" launch "$@" --output json
}

reopen() {
  run --separate-stderr "$AGENT_SLOT" reopen "$@" --output json
}

typed() { cat "$STUBS/typed-repoa-1"; }

# head_fields OWNER [IS-CROSS]: gh's answer for a head on feat/x of OWNER/repoa.
head_fields() {
  jaq -n -c --arg owner "$1" --argjson cross "${2:-true}" '{headRefName: "feat/x",
    headRepository: {id: "R_2", name: "repoa"}, headRepositoryOwner: {id: "U_2", login: $owner},
    isCrossRepository: $cross}'
}

# hostile_head BARE BRANCH N [EXTRA]: a head on top of main that tracks a Claude settings hook, an API key helper, an MCP
# server, and git hooks, each touching a marker, pushed to BRANCH of the bare repo BARE, when BRANCH is not empty, and to origin's refs/pull/N/head.
# EXTRA, when given, is a function run in the seed clone before the commit. Sets HEAD_SHA.
hostile_head() {
  local seed=$T/seed-repoa hook
  git -C "$seed" checkout -q -B "head-$3" main
  mkdir -p "$seed/.claude" "$seed/.githooks"
  jaq -n --arg m "$T/marks" '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)/settings-hook"}]}]},
    apiKeyHelper: "touch \($m)/api-key-helper; echo sk-ant-test", enableAllProjectMcpServers: true}' \
    >"$seed/.claude/settings.json"
  jaq -n --arg m "$T/marks" '{mcpServers: {tree: {command: "sh", args: ["-c", "touch \($m)/mcp-server; exec cat"]}}}' \
    >"$seed/.mcp.json"
  for hook in pre-commit post-commit pre-push post-checkout; do
    printf '#!/bin/sh\ntouch %s/git-%s\n' "$T/marks" "$hook" >"$seed/.githooks/$hook"
    chmod +x "$seed/.githooks/$hook"
  done
  if [ -n "${4:-}" ]; then (cd "$seed" && "$4"); fi
  git -C "$seed" add -A -f .
  git -C "$seed" commit -q -m "head for #$3"
  HEAD_SHA=$(git -C "$seed" rev-parse HEAD)
  [ -z "$2" ] || git -C "$seed" push -q "$1" "$HEAD_SHA:refs/heads/$2"
  git -C "$seed" push -q "$T/origins/repoa.git" "$HEAD_SHA:refs/pull/$3/head"
  git -C "$seed" checkout -q main
}

# foreign_pr / own_pr / same_repo_pr: PR 7 with the hostile head on evil's fork, on me's fork, or on origin. Owner up is
# on no list, as a third party's repo a prime's origin names is not: only the head being on origin keeps it unchanged.
foreign_pr() {
  hostile_head "$T/forks/evil/repoa.git" feat/x 7 "${1:-}"
  gh_item pr 7 "Fix the login" OPEN "$(head_fields evil)"
}
own_pr() {
  hostile_head "$T/forks/me/repoa.git" feat/x 7 "${1:-}"
  gh_item pr 7 "Fix the login" OPEN "$(head_fields me)"
}
same_repo_pr() {
  hostile_head "$T/origins/repoa.git" feat/x 7 "${1:-}"
  gh_item pr 7 "Fix the login" OPEN "$(head_fields up false)"
}

# hooks_path: the slot's core.hooksPath, or nothing.
hooks_path() { git -C "$SLOT" config --get core.hooksPath || true; }

# assert_unchanged_setup OUTPUT: what a head with the full setup gets: hooks at the tree's path, Claude's project
# settings loaded, and no foreign field in the output or the record.
assert_unchanged_setup() {
  [ "$(hooks_path)" = .githooks ]
  [ -f "$SLOT/.claude/settings.local.json" ]
  jaq -e '.head_foreign == false and .head_owner == null' <<<"$1"
  jaq -e 'has("head_foreign") | not' "$SLOT/.git/agent-slot.json"
  [[ $(typed) == "claude --dangerously-skip-permissions --session-id "* ]]
}

# real_claude_env: the environment the real claude runs under here: a config directory of its own and an API port nothing
# listens on, so Claude exits at its first request, after the session-start hooks have run. Called in a subshell.
real_claude_env() {
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR CLAUDE_CODE_SSE_PORT TMUX TMUX_PANE
  export CLAUDE_CONFIG_DIR=$T/claude-config ANTHROPIC_API_KEY=sk-ant-test ANTHROPIC_BASE_URL=http://127.0.0.1:9
  export CLAUDE_CODE_MAX_RETRIES=0 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

# run_typed_line: runs the line typed into the slot's Claude session, in the slot, through the real claude in print mode.
run_typed_line() {
  local line
  line=$(typed)
  (
    cd "$SLOT" || exit 1
    # shellcheck disable=SC2329 # the eval below calls it
    claude() { "$REAL_CLAUDE" -p "$@"; }
    real_claude_env
    eval "$line" </dev/null >"$T/real-claude.out" 2>&1 || true
  )
}

# run_plain_claude [DIR]: the real claude in print mode with none of the slot's flags, as a person or a tool in the slot
# would start it, in DIR under the slot.
run_plain_claude() {
  (
    cd "$SLOT/${1:-}" || exit 1
    real_claude_env
    "$REAL_CLAUDE" -p --dangerously-skip-permissions 'say ok' </dev/null >"$T/real-claude.out" 2>&1 || true
  )
}

@test "a foreign head's Claude starts with user settings only, and the output, record, and ledger say so" {
  foreign_pr
  launch repoa --pr 7 --request-id r-foreign
  [ "$status" -eq 0 ]
  local session
  session=$(jaq -r .session_id <<<"$output")
  jaq -e '.head_foreign == true and .head_owner == "evil"' <<<"$output"
  [ "$(typed)" = "claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config --session-id $session -n repoa-pr7-fix-the-login" ]
  jaq -e '.head_foreign == true and .head_owner == "evil"' "$SLOT/.git/agent-slot.json"
  jaq -e -s '[.[] | select(.event == "launch")][-1] | .head_foreign == true and .head_owner == "evil"' "$LEDGER"
  [ "$(git -C "$SLOT" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$SLOT" config --get remote.fork.url)" = https://github.com/evil/repoa.git ]
}

@test "the text output tells the operator a foreign head runs nothing" {
  foreign_pr
  run --separate-stderr "$AGENT_SLOT" launch repoa --pr 7
  [ "$status" -eq 0 ]
  [[ $output == *"its head is a fork of evil's, so nothing from the head runs"* ]]
}

@test "a foreign head's settings hook, key helper, and MCP server do not run in the real Claude" {
  [ -n "$REAL_CLAUDE" ] || skip "Claude Code is not installed"
  foreign_pr
  launch repoa --pr 7 --prompt-file "$T/brief"
  [ "$status" -eq 0 ]
  # With the tree's config back on disk, so this is the flags holding on their own.
  git -C "$SLOT" sparse-checkout disable
  [ -f "$SLOT/.claude/settings.json" ]
  run_typed_line
  [ -z "$(ls "$T/marks")" ] || {
    ls "$T/marks"
    cat "$T/real-claude.out"
    false
  }
  grep -q 'ECONNREFUSED\|Connection refused' "$T/real-claude.out"
}

@test "an own fork's settings hook, key helper, and MCP server do run in the real Claude, so the test above is not vacuous" {
  [ -n "$REAL_CLAUDE" ] || skip "Claude Code is not installed"
  own_pr
  launch repoa --pr 7 --prompt-file "$T/brief"
  [ "$status" -eq 0 ]
  run_typed_line
  [ -e "$T/marks/settings-hook" ] && [ -e "$T/marks/api-key-helper" ] && [ -e "$T/marks/mcp-server" ] || {
    ls "$T/marks"
    cat "$T/real-claude.out"
    false
  }
}

@test "a foreign head's git hook does not run on a commit, a checkout, or a push" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -f "$SLOT/.githooks/pre-commit" ]
  [ -z "$(hooks_path)" ]
  git -C "$SLOT" commit -q --allow-empty -m work
  git -C "$SLOT" checkout -q -b work-branch
  git -C "$SLOT" push -q fork HEAD:refs/heads/work-branch
  [ -z "$(ls "$T/marks")" ]
}

@test "a hook installed in the prime's git directory is not copied into a foreign head's slot" {
  git -C "$AGENT_SLOT_DEV/repoa" config --unset core.hooksPath
  printf '#!/bin/sh\ntouch %s/copied-hook\n' "$T/marks" >"$AGENT_SLOT_DEV/repoa/.git/hooks/pre-commit"
  chmod +x "$AGENT_SLOT_DEV/repoa/.git/hooks/pre-commit"
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$SLOT/.git/hooks/pre-commit" ]
  git -C "$SLOT" commit -q --allow-empty -m work
  [ -z "$(ls "$T/marks")" ]
}

@test "a same-repo PR on a third party's origin keeps today's setup, and its git hook runs" {
  same_repo_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  assert_unchanged_setup "$output"
  git -C "$SLOT" commit -q --allow-empty -m work
  [ -e "$T/marks/git-pre-commit" ]
}

@test "a PR from a trusted owner's fork keeps today's setup, and its git hook runs" {
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  assert_unchanged_setup "$output"
  git -C "$SLOT" commit -q --allow-empty -m work
  [ -e "$T/marks/git-pre-commit" ]
}

# trust_owners LIST: the trusted owner list this test's launches read.
trust_owners() { export AGENT_SLOT_TRUSTED_OWNERS=$1; }

@test "the trusted owner list matches in any case, as GitHub does" {
  trust_owners 'nobody ME'
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  assert_unchanged_setup "$output"
}

@test "an owner on no list counts as foreign, with an empty list trusting nobody" {
  trust_owners ''
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.head_foreign == true and .head_owner == "me"' <<<"$output"
  [ -z "$(hooks_path)" ]
}

@test "an owner that cannot be determined counts as foreign: the head's repository is gone" {
  hostile_head "" "" 7
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x", "headRepository": null, "headRepositoryOwner": null,
    "isCrossRepository": true}'
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  jaq -e '.head_foreign == true and .head_owner == null and .head_pushable == false' <<<"$output"
  [ "$(git -C "$SLOT" rev-parse HEAD)" = "$HEAD_SHA" ]
  [[ $(typed) == "claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config "* ]]
  [ -z "$(hooks_path)" ]
}

@test "a launch with no item and one on an issue keep today's setup" {
  gh_item issue 12 "Fix the widget"
  launch repoa --issue 12
  [ "$status" -eq 0 ]
  assert_unchanged_setup "$output"
  launch repoa --task other
  [ "$status" -eq 0 ]
  jaq -e '.head_foreign == false' <<<"$output"
}

@test "the trust step starts Claude with user settings only for a foreign head, since accepting runs what it loads" {
  jaq 'del(.projects[$p])' --arg p "$(realpath -m "$SLOT")" "$AGENT_SLOT_CLAUDE_STATE" >"$T/state.new"
  cp "$T/state.new" "$AGENT_SLOT_CLAUDE_STATE"
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
  printf '❯ \n' >"$STUBS/screen"
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  grep -E 'new-session .*trust-.* -c .*/claude --setting-sources user --strict-mcp-config$' "$CALLS"
}

@test "the trust step for an own fork starts Claude as it always has" {
  jaq 'del(.projects[$p])' --arg p "$(realpath -m "$SLOT")" "$AGENT_SLOT_CLAUDE_STATE" >"$T/state.new"
  cp "$T/state.new" "$AGENT_SLOT_CLAUDE_STATE"
  trusted "$(realpath -m "$AGENT_SLOT_DEV/repoa")"
  printf '❯ \n' >"$STUBS/screen"
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  grep -E 'new-session .*trust-.* -c .*/claude$' "$CALLS"
}

# links_out: tracked links that lead out of the slot, as slot setup would write through them.
links_out() {
  mkdir -p .claude
  ln -s "$T/outside/settings.json" .claude/settings.local.json
  ln -s "$T/outside/context" .context
}

@test "slot setup writes nothing through a foreign head's tracked links" {
  printf 'the guard hooks\n' >"$T/outside/settings.json"
  mkdir -p "$T/outside/context"
  foreign_pr links_out
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(cat "$T/outside/settings.json")" = 'the guard hooks' ]
  [ -z "$(ls -A "$T/outside/context")" ]
}

# docs_out: docs/ as a tracked link out of the slot, where the docs/solutions link would land.
docs_out() { ln -s "$T/outside/docs" docs; }

@test "a foreign head whose docs is a link out of the slot is refused, with nothing written there" {
  mkdir -p "$T/outside/docs"
  foreign_pr docs_out
  launch repoa --pr 7
  [ "$status" -ne 0 ]
  assert_error_shape "$stderr"
  jaq -e --arg docs "$SLOT/docs" '.reason == "tracked-link-leaves-slot" and .value == $docs' <<<"$stderr"
  [ -z "$(ls -A "$T/outside/docs")" ]
  [ ! -e "$SLOT" ]
}

@test "a foreign head's solutions worktree is linked as usual when docs stays inside the slot" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -L "$SLOT/docs/solutions" ]
  jaq -e '.solutions_worktree != null' "$SLOT/.git/agent-slot.json"
}

# sibling_link: a tracked link to a sibling checkout beside the slots.
sibling_link() { ln -s ../other/file sibling-file; }

@test "a foreign head's links to sibling checkouts add no link beside the slots" {
  prime other
  foreign_pr sibling_link
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/other" ]
  jaq -e '.missing_siblings == []' <<<"$output"
}

@test "an own fork's links to sibling checkouts still get theirs" {
  prime other
  own_pr sibling_link
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -L "$AGENT_SLOT_ROOT/repoa/other" ]
}

# lfs_file: a tracked file under the LFS filter.
lfs_file() {
  printf 'big.bin filter=lfs -text\n' >.gitattributes
  git config --file "$GIT_CONFIG_GLOBAL" filter.lfs.clean cat
  printf 'x\n' >big.bin
}

@test "a foreign head's checkout runs no LFS smudge, so its .lfsconfig reaches no server" {
  command -v git-lfs >/dev/null || skip "git-lfs is not installed"
  foreign_pr lfs_file
  git config --file "$GIT_CONFIG_GLOBAL" filter.lfs.smudge "sh -c 'touch $T/marks/lfs-smudge; cat'"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -e "$T/marks/lfs-smudge" ]
  [ "$(git -C "$SLOT" config --local --get filter.lfs.smudge)" = 'git-lfs smudge --skip -- %f' ]
  [ "$(git -C "$SLOT" config --local --get filter.lfs.process)" = 'git-lfs filter-process --skip' ]
}

@test "an own fork's checkout runs the LFS smudge as it always has" {
  own_pr lfs_file
  git config --file "$GIT_CONFIG_GLOBAL" filter.lfs.smudge "sh -c 'touch $T/marks/lfs-smudge; cat'"
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -e "$T/marks/lfs-smudge" ]
  run ! git -C "$SLOT" config --local --get filter.lfs.smudge
}

# crypt_attr: a .gitattributes naming git-crypt, which asks for an unlock with the host's key.
crypt_attr() { printf 'lifted.bin filter=git-crypt diff=git-crypt\n' >.gitattributes; }

@test "a foreign head's .gitattributes does not get the host's git-crypt key used when the base does not use it" {
  foreign_pr crypt_attr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(grep -c '^git-crypt unlock' "$CALLS")" -eq 0 ]
}

@test "a foreign head on a base that uses git-crypt is still unlocked" {
  origin_file repoa .gitattributes 'secret/** filter=git-crypt diff=git-crypt'
  git -C "$AGENT_SLOT_DEV/repoa" fetch -q origin
  stub git-crypt '[ "$1" != unlock ] || git config filter.git-crypt.smudge cat'
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(grep -c '^git-crypt unlock' "$CALLS")" -eq 1 ]
}

@test "resume starts a foreign head's Claude with the same flags" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  : >"$STUBS/tmux-sessions"
  trash "$STUBS/typed-repoa-1"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  [[ $(typed) == "claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config "* ]]
}

S1=11111111-2222-4333-8444-555555555555
PR7='{"kind": "pr", "repo": "up/repoa", "number": 7, "title": "Fix the login"}'
ISSUE12='{"kind": "issue", "repo": "up/repoa", "number": 12, "title": "Fix the widget"}'

# teardown_event FIELDS: a ledger line for the teardown of repoa/1, whose conversation is saved, with FIELDS merged over.
teardown_event() {
  local dir=$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repoa-1
  mkdir -p "$dir" "$AGENT_SLOT_STATE_DIR"
  printf '{"type":"user","sessionId":"%s"}\n' "$S1" >"$dir/$S1.jsonl"
  jaq -n -c --argjson f "$1" --arg s "$S1" --arg t "$dir/$S1.jsonl" '{schema: "dotfiles.agent-slot/1",
    ts: "2026-10-01T00:00:00Z", event: "teardown", repo: "repoa", slot: 1, task: "t1", session_id: $s, transcript: $t,
    prs: [], request_id: null} + $f' >>"$LEDGER"
}

# branch_entry OWNER: a teardown event's feat/x branch at HEAD_SHA, on OWNER's repoa.
branch_entry() {
  local remote=fork
  [ "$1" != up ] || remote=origin
  jaq -n -c --arg sha "$HEAD_SHA" --arg remote "$remote" --arg url "https://github.com/$1/repoa.git" \
    '{name: "feat/x", oid: $sha, remote: $remote, url: $url}'
}

# assert_reopened_foreign OWNER OUTPUT: a reopen's output, typed line, and git config for a foreign head of OWNER.
assert_reopened_foreign() {
  jaq -e --arg owner "$1" '.head_foreign == true and .head_owner == $owner' <<<"$2"
  [[ $(typed) == "claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config --resume $S1"* ]]
  [ -z "$(hooks_path)" ]
}

@test "a reopen of a foreign slot stays foreign, even when the ledger puts its branch on origin" {
  same_repo_pr
  teardown_event "{\"items\": [$PR7], \"prs\": [7], \"head\": \"feat/x\", \"head_foreign\": true,
    \"head_owner\": \"evil\", \"branches\": [$(branch_entry up)]}"
  reopen repoa --pr 7
  [ "$status" -eq 0 ]
  assert_reopened_foreign evil "$output"
}

@test "a reopen is foreign when GitHub's head is, whatever a ledger line that predates the field says" {
  foreign_pr
  teardown_event "{\"items\": [$PR7], \"prs\": [7], \"head\": \"feat/x\", \"branches\": [$(branch_entry me)]}"
  git -C "$T/seed-repoa" push -q "$T/forks/me/repoa.git" "$HEAD_SHA:refs/heads/feat/x"
  reopen repoa --pr 7
  [ "$status" -eq 0 ]
  assert_reopened_foreign evil "$output"
}

@test "a reopen is foreign when the branch the ledger names is on a foreign fork" {
  own_pr
  gh_item pr 7 "Fix the login" OPEN "$(head_fields me)"
  git -C "$T/seed-repoa" push -q "$T/forks/evil/repoa.git" "$HEAD_SHA:refs/heads/feat/x"
  teardown_event "{\"items\": [$PR7], \"prs\": [7], \"head\": \"feat/x\", \"branches\": [$(branch_entry evil)]}"
  reopen repoa --pr 7
  [ "$status" -eq 0 ]
  assert_reopened_foreign evil "$output"
}

@test "a reopen on an issue is foreign when the ledger's branch is on a foreign fork" {
  hostile_head "$T/forks/evil/repoa.git" feat/x 7
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"items\": [$ISSUE12], \"head\": \"feat/x\", \"branches\": [$(branch_entry evil)]}"
  reopen repoa --issue 12
  [ "$status" -eq 0 ]
  assert_reopened_foreign evil "$output"
}

@test "a reopen of a trusted owner's fork keeps today's setup" {
  own_pr
  teardown_event "{\"items\": [$PR7], \"prs\": [7], \"head\": \"feat/x\", \"branches\": [$(branch_entry me)]}"
  reopen repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(hooks_path)" = .githooks ]
  jaq -e '.head_foreign == false' <<<"$output"
  [[ $(typed) == "claude --dangerously-skip-permissions --resume $S1"* ]]
}

@test "a reopen's dry run reports a foreign head and the command it would type" {
  foreign_pr
  teardown_event "{\"items\": [$PR7], \"prs\": [7], \"head\": \"feat/x\", \"branches\": [$(branch_entry evil)]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == true and .head_foreign == true and .head_owner == "evil"
    and (.command | startswith("claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config --resume \($s)"))' <<<"$output"
  [ ! -e "$SLOT" ]
}

@test "a teardown's ledger line carries the foreign fields, which is what a later reopen reads" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  echo '[]' >"$STUBS/gh-prs.json"
  pr 7 MERGED feat/x
  run --separate-stderr "$AGENT_SLOT" finish repoa/1 --yes --output json
  jaq -e -s '[.[] | select(.event == "teardown")][-1] | .head_foreign == true and .head_owner == "evil"' "$LEDGER" || {
    echo "$output $stderr"
    false
  }
}

# tracked_local_settings: the head tracks .claude/settings.local.json with a hook. Any git operation that restores a
# tracked file puts it back, so setup overwriting the file could not keep the hook out: only leaving local settings
# unloaded does.
tracked_local_settings() {
  mkdir -p .claude
  jaq -n --arg m "$T/marks/local-hook" '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)"}]}]}}' \
    >.claude/settings.local.json
}

@test "the flags alone keep a tracked settings.local.json's hook from running, after any git restore" {
  [ -n "$REAL_CLAUDE" ] || skip "Claude Code is not installed"
  foreign_pr tracked_local_settings
  launch repoa --pr 7 --prompt-file "$T/brief"
  [ "$status" -eq 0 ]
  git -C "$SLOT" sparse-checkout disable
  [ -f "$SLOT/.claude/settings.local.json" ]
  run_typed_line
  [ ! -e "$T/marks/local-hook" ]
  git -C "$SLOT" checkout -q -- .
  git -C "$SLOT" stash -q || true
  run_typed_line
  [ ! -e "$T/marks/local-hook" ]
}

# nested_config: Claude config below the root too, which a Claude started in that directory would read.
nested_config() {
  mkdir -p sub/.claude
  cp .claude/settings.json sub/.claude/settings.json
  printf 'nested\n' >sub/CLAUDE.md
  printf 'kept\n' >sub/kept.txt
  printf 'tree prompt\n' >CLAUDE.md
  printf 'tree prompt\n' >CLAUDE.local.md
}

@test "a foreign head's Claude config stays off disk through git restores and branch switches" {
  foreign_pr nested_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local path restored=restored
  for path in .claude .mcp.json CLAUDE.md CLAUDE.local.md sub/.claude sub/CLAUDE.md; do [ ! -e "$SLOT/$path" ]; done
  [ -f "$SLOT/sub/kept.txt" ]
  [ -f "$SLOT/.githooks/pre-commit" ]
  [ -z "$(git -C "$SLOT" status --porcelain -- .claude .mcp.json CLAUDE.md CLAUDE.local.md sub)" ]
  git -C "$SLOT" checkout -q -- .
  git -C "$SLOT" reset -q --hard
  git -C "$SLOT" stash -q || true
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" checkout -q feat/x
  [ ! -e "$SLOT/.claude" ] || restored=
  [ "$restored" = restored ]
}

@test "a foreign head's Claude config stays readable from git and goes on in what the agent pushes" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  git -C "$SLOT" show HEAD:.claude/settings.json | jaq -e '.hooks.SessionStart'
  git -C "$SLOT" diff --name-only origin/main...HEAD | grep -qx .claude/settings.json
  git -C "$SLOT" commit -q --allow-empty -m work
  git -C "$SLOT" push -q fork HEAD:refs/heads/pushed
  git -C "$T/forks/evil/repoa.git" ls-tree -r --name-only pushed | grep -qx .claude/settings.json
}

@test "a plain claude started in a foreign head's slot finds no config to run, at the root or below it" {
  [ -n "$REAL_CLAUDE" ] || skip "Claude Code is not installed"
  foreign_pr nested_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  run_plain_claude
  run_plain_claude sub
  [ -z "$(ls "$T/marks")" ] || {
    ls "$T/marks"
    false
  }
  grep -q 'ECONNREFUSED\|Connection refused' "$T/real-claude.out"
}

@test "a foreign head's files session starts no file browser, whose previewers would parse the tree unattended" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(cat "$STUBS/typed-repoa-1-files")" = 'ls -A' ]
}

@test "an own fork's files session starts yazi as it always has" {
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ "$(cat "$STUBS/typed-repoa-1-files")" = 'command -v y >/dev/null && y || yazi' ]
}

@test "launch's help names the foreign head fields and the owner list" {
  run "$AGENT_SLOT" launch --help
  [ "$status" -eq 0 ]
  [[ $output == *AGENT_SLOT_TRUSTED_OWNERS* ]]
  [[ $output == *head_foreign* ]]
  [[ $output == *head_owner* ]]
}

# lazygit_config: a .lazygit.yml whose pager touches a marker, which lazygit runs to draw a diff as it starts.
lazygit_config() {
  printf 'git:\n  pagers:\n    - pager: "sh -c '"'"'touch %s/%s; cat'"'"'"\n' "$T/marks" "$1" >"$2"
}
tree_lazygit_config() { lazygit_config lazygit-tree .lazygit.yml; }

# run_lazygit SECONDS MARK: real lazygit in the slot on a tmux server of this test's own, until MARK appears or SECONDS
# pass. A tree's git session starts it unattended, so what it loads from the tree would run with no key pressed.
run_lazygit() {
  local i
  export TMUX_TMPDIR=$T
  tmux -L lazygit-test -f /dev/null new-session -d -x 200 -y 50 -c "$SLOT" lazygit
  for ((i = 0; i < $1 * 10; i++)); do
    [ ! -e "$T/marks/$2" ] || break
    sleep 0.1
  done
  tmux -L lazygit-test kill-server 2>/dev/null || true
}

@test "lazygit runs nothing from a .lazygit.yml the head tracks, though the same file in a parent directory does run" {
  command -v lazygit >/dev/null || skip "lazygit is not installed"
  command -v tmux >/dev/null || skip "tmux is not installed"
  foreign_pr tree_lazygit_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  printf 'changed\n' >>"$SLOT/.githooks/pre-commit"
  run_lazygit 3 lazygit-tree
  [ ! -e "$T/marks/lazygit-tree" ]
  lazygit_config lazygit-parent "$AGENT_SLOT_ROOT/repoa/.lazygit.yml"
  run_lazygit 8 lazygit-parent
  [ -e "$T/marks/lazygit-parent" ]
}

# lockfile: a package.json and bun.lock whose install scripts touch a marker, with an install tool that runs them.
lockfile() {
  jaq -n --arg m "$T/marks/lifecycle-script" '{name: "tree", version: "1.0.0", scripts: {postinstall: "touch \($m)"}}' \
    >package.json
  printf '{"lockfileVersion": 1, "workspaces": {"": {"name": "tree"}}, "packages": {}}\n' >bun.lock
  printf 'node_modules/\n' >.gitignore
}

@test "a foreign head installs nothing from its lockfile, and its agent gets no advice to" {
  mkdir -p "$AGENT_SLOT_DEV/repoa/node_modules"
  stub bun 'for arg in "$@"; do [ "$arg" != install ] || touch "$T_MARKS/bun-install"; done'
  export T_MARKS=$T/marks AGENT_SLOT_BUN=$STUBS/bun
  foreign_pr lockfile
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -z "$(ls "$T/marks")" ]
  jaq -e '(.deps // null) == null' <<<"$output"
  jaq -e '(.deps // null) == null' "$SLOT/.git/agent-slot.json"
}

# claude_links: .claude as a tracked link, at the root and below it, to a tracked directory holding the settings.
claude_links() {
  mkdir -p cfg sub
  cp .claude/settings.json cfg/settings.json
  rm -rf .claude
  ln -s cfg .claude
  ln -s ../cfg sub/.claude
  printf 'kept\n' >sub/kept.txt
}

@test "a tracked .claude link stays off disk at the root and below it, and a plain claude runs nothing through it" {
  foreign_pr claude_links
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ ! -L "$SLOT/.claude" ] && [ ! -e "$SLOT/.claude" ]
  [ ! -L "$SLOT/sub/.claude" ] && [ ! -e "$SLOT/sub/.claude" ]
  [ -f "$SLOT/sub/kept.txt" ]
  git -C "$SLOT" checkout -q -- .
  git -C "$SLOT" reset -q --hard
  [ ! -L "$SLOT/.claude" ]
  if [ -n "$REAL_CLAUDE" ]; then
    run_plain_claude
    run_plain_claude sub
    [ -z "$(ls "$T/marks")" ] || {
      ls "$T/marks"
      false
    }
  fi
}

# tool_config: what a host tool started in the tree reads from its working directory: a Bun preload and .env files, which
# every Bun-run CLI loads, and a node_modules/.bin, which bunx prefers over the tool it was asked for.
tool_config() {
  printf 'preload = ["./tree-preload.js"]\n' >bunfig.toml
  printf 'require("fs").writeFileSync("%s/bun-preload", "");\n' "$T/marks" >tree-preload.js
  printf 'FROM_TREE=1\n' >.env
  printf 'FROM_TREE=1\n' >.env.local
  mkdir -p node_modules/.bin sub
  printf '#!/bin/sh\ntouch %s/tree-bin\n' "$T/marks" >node_modules/.bin/qmd
  chmod +x node_modules/.bin/qmd
  cp bunfig.toml sub/bunfig.toml
  printf 'FROM_TREE=1\n' >sub/.env
}

@test "the config host tools read from their working directory stays off disk on a foreign head" {
  foreign_pr tool_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local path
  for path in bunfig.toml .env .env.local node_modules sub/bunfig.toml sub/.env; do [ ! -e "$SLOT/$path" ]; done
  [ -f "$SLOT/tree-preload.js" ]
  git -C "$SLOT" show HEAD:bunfig.toml | grep -q preload
}

# run_qmd: the real qmd, whose launcher runs under Bun, listing its collections from the slot's root.
run_qmd() { (cd "$SLOT" && qmd collection list >/dev/null 2>&1) || true; }

@test "the real qmd started in a foreign head's slot runs nothing from the tree" {
  command -v qmd >/dev/null || skip "qmd is not installed"
  foreign_pr tool_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  run_qmd
  [ -z "$(ls "$T/marks")" ]
}

@test "the real qmd started in an own fork's slot does run a tracked preload, so the test above is not vacuous" {
  command -v qmd >/dev/null || skip "qmd is not installed"
  own_pr tool_config
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  run_qmd
  [ -e "$T/marks/bun-preload" ]
}

# bare_shaped: a tracked directory git takes for a bare repository once a command runs below it, whose config runs a
# command on `git status` and names the directory itself as its work tree.
bare_shaped() {
  mkdir -p src/objects/info src/refs/heads src/code
  printf 'ref: refs/heads/main\n' >src/HEAD
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = .\n\tfsmonitor = touch %s/fsmonitor; false\n' \
    "$T/marks" >src/config
  printf 'x\n' >src/objects/info/keep
  printf 'x\n' >src/refs/heads/keep
  printf 'x\n' >src/code/file.txt
}

# session_env KIND: the -e values the slot's session of that kind started with, one per line.
session_env() {
  grep -E "^tmux .*new-session .*-s repoa-1$1 " "$CALLS" | grep -oE -- '-e [^ ]+' | cut -d' ' -f2
}

@test "each of a foreign head's sessions starts with bare repository discovery off" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local kind expected
  expected=$'GIT_CONFIG_COUNT=1\nGIT_CONFIG_KEY_0=safe.bareRepository\nGIT_CONFIG_VALUE_0=explicit'
  for kind in '' -files -git; do [ "$(session_env "$kind")" = "$expected" ]; done
}

@test "an own fork's sessions start with no such environment" {
  own_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -z "$(session_env '')" ]
}

@test "resume starts a foreign head's sessions with the same environment" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  : >"$STUBS/tmux-sessions"
  : >"$CALLS"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  [ "$(session_env '' | wc -l)" -eq 3 ]
}

@test "under that environment git below a bare-shaped directory runs nothing, though without it git does" {
  foreign_pr bare_shaped
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  [ -f "$SLOT/src/config" ]
  git -C "$SLOT/src/code" status --short >/dev/null 2>&1 || true
  [ -e "$T/marks/fsmonitor" ]
  rm "$T/marks/fsmonitor"
  local -a settings
  mapfile -t settings < <(session_env '')
  (
    export "${settings[@]}"
    git -C "$SLOT/src/code" status --short >/dev/null 2>&1 || true
    "$BATS_TEST_DIRNAME/../stow/claude/dot-claude/statusline.sh" >/dev/null 2>&1 \
      <<<"{\"workspace\": {\"current_dir\": \"$SLOT/src/code\"}, \"model\": {}, \"cost\": {}, \"context_window\": {}}" || true
  )
  [ ! -e "$T/marks/fsmonitor" ]
}

@test "that environment leaves git working at the slot's root, below it, and in the solutions worktree" {
  foreign_pr bare_shaped
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local -a settings
  mapfile -t settings < <(session_env '')
  (
    export "${settings[@]}"
    git -C "$SLOT" status --short >/dev/null
    git -C "$SLOT/.githooks" log -1 --format=%h >/dev/null
    git -C "$SLOT/docs/solutions" status --short >/dev/null
    git -C "$SLOT" commit -q --allow-empty -m work
    git -C "$SLOT" push -q fork HEAD:refs/heads/pushed
  )
}

# tracked_solutions_link: docs/solutions as a tracked link, as this repo's own branches hold it.
tracked_solutions_link() {
  mkdir -p docs
  ln -s ../../dev/solutions-docs docs/solutions
}

@test "a foreign head's tracked docs/solutions link keeps the slot's worktree and stays out of every commit" {
  foreign_pr tracked_solutions_link
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  local worktree
  worktree=$(jaq -r .solutions_worktree "$SLOT/.git/agent-slot.json")
  [ "$(readlink "$SLOT/docs/solutions")" = "$worktree" ]
  [ -z "$(git -C "$SLOT" status --porcelain -- docs)" ]
  git -C "$SLOT" checkout -q -b work
  git -C "$SLOT" reset -q --hard
  [ "$(readlink "$SLOT/docs/solutions")" = "$worktree" ]
  [ -z "$(git -C "$SLOT" status --porcelain -- docs)" ]
  printf 'x\n' >"$SLOT/work.txt"
  git -C "$SLOT" add -A
  git -C "$SLOT" commit -q -m work
  [ "$(git -C "$SLOT" show HEAD:docs/solutions)" = ../../dev/solutions-docs ]
}

# real_solutions_dir: docs/solutions as a real directory, which the slot's link has nowhere to go.
real_solutions_dir() {
  mkdir -p docs/solutions
  printf 'x\n' >docs/solutions/a.md
}

@test "a foreign head with a real docs/solutions directory is refused, as any other head is" {
  foreign_pr real_solutions_dir
  launch repoa --pr 7
  [ "$status" -ne 0 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "solutions-symlink-missing"' <<<"$stderr"
  [ ! -e "$SLOT" ]
}

@test "a reopen's dry run reports no verdict, rather than a safe one, while a live slot holds the item" {
  foreign_pr
  launch repoa --pr 7
  [ "$status" -eq 0 ]
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .head_foreign == null and .head_owner == null' <<<"$output"
}

@test "a reopen's dry run reports no verdict when no teardown names the item" {
  foreign_pr
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .head_foreign == null and .head_owner == null' <<<"$output"
}

@test "a reopen on an issue with no branch stays on the base and is not foreign" {
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"items\": [$ISSUE12]}"
  reopen repoa --issue 12
  [ "$status" -eq 0 ]
  jaq -e '.head_foreign == false' <<<"$output"
  [ "$(hooks_path)" = .githooks ]
}

@test "a refused head's next step shows the PR, since an agent cannot repair a link in someone else's branch" {
  mkdir -p "$T/outside/docs"
  foreign_pr docs_out
  launch repoa --pr 7
  [ "$status" -ne 0 ]
  jaq -e '.next_step.action == "ask-operator" and .next_step.command == "gh pr view 7 --repo up/repoa"' <<<"$stderr"
}

@test "launch and reopen's help say a dry run with no plan reports null, and whoami's says the record carries the verdict" {
  run "$AGENT_SLOT" reopen --help
  [ "$status" -eq 0 ]
  [[ $output == *'head_owner, null when a dry run plans no head'* ]]
  run "$AGENT_SLOT" whoami --help
  [ "$status" -eq 0 ]
  [[ $output == *head_foreign* ]]
}

# encrypted_head: a head with a Claude settings file under the git-crypt filter the base branch declares.
encrypted_head() {
  mkdir -p .claude
  printf '{"under": "the filter"}\n' >.claude/filtered.json
}

@test "the real git-crypt unlocks a foreign head under its sparse checkout, and the tree's config stays off disk" {
  command -v git-crypt >/dev/null || skip "git-crypt is not installed"
  local seed=$T/seed-repoa
  (cd "$seed" && git-crypt init >/dev/null && git-crypt export-key "$AGENT_SLOT_GIT_CRYPT_KEY")
  mkdir -p "$seed/secret"
  printf 'secret/** filter=git-crypt diff=git-crypt\n.claude/filtered.json filter=git-crypt diff=git-crypt\n' \
    >"$seed/.gitattributes"
  printf 'THE-SECRET\n' >"$seed/secret/x"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m 'encrypted base'
  git -C "$seed" push -q origin HEAD:main
  export AGENT_SLOT_GIT_CRYPT
  AGENT_SLOT_GIT_CRYPT=$(command -v git-crypt)
  foreign_pr encrypted_head
  launch repoa --pr 7
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  [ "$(cat "$SLOT/secret/x")" = THE-SECRET ]
  [ ! -e "$SLOT/.claude" ]
  [ -z "$(git -C "$SLOT" status --porcelain -- secret .claude)" ]
  printf 'new\n' >"$SLOT/secret/y"
  git -C "$SLOT" add secret/y
  git -C "$SLOT" commit -q -m work
  [ "$(git -C "$SLOT" cat-file blob HEAD:secret/y | head -c 8 | tail -c 7)" = GITCRYP ]
}
