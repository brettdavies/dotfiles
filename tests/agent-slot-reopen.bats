#!/usr/bin/env bats
# agent-slot reopen: finding a work item's torn-down slot in the ledger, refusing what a reopen must not do, the dry
# run that reports the whole plan and changes nothing, and the reopen that makes a slot resuming the conversation.
#
# Run: bats tests/agent-slot-reopen.bats
#
# repoa's prime has origin up/repoa on GitHub, gh answers from gh_item's fixtures, and transcripts live under the
# sandboxed Claude projects directory.

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  prime repoa
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/origins/.insteadOf" https://github.com/up/
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin https://github.com/up/repoa.git
  stub_gh_items
  export AGENT_SLOT_LOCK_WAIT=2 AGENT_SLOT_TRUST_TIMEOUT=3
  local n
  for n in 1 2 3; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  S1=4e0a3f33-f697-4dff-a32f-2b0202be99d4
  S2=e999f4ab-8387-4992-bb05-f4e6041b9b68
  S3=0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d
}

teardown() {
  stop_spawned
  assert_no_leaks
}

FORK_HEAD='{"headRefName": "feat/x", "headRepository": {"id": "R_2", "name": "repoa"},
  "headRepositoryOwner": {"id": "U_2", "login": "me"}, "isCrossRepository": true}'
FORK_BRANCH='{"name": "feat/x", "oid": "abc123", "remote": "fork", "url": "git@github.com:me/repoa.git"}'
PR7='{"kind": "pr", "repo": "up/repoa", "number": 7, "title": "Fix the login"}'
ISSUE12='{"kind": "issue", "repo": "up/repoa", "number": 12, "title": "Fix the widget"}'

reopen() {
  run --separate-stderr "$AGENT_SLOT" reopen "$@" --output json
}

# teardown_event FIELDS: a ledger line for the teardown of repoa/1, with FIELDS merged over its defaults.
teardown_event() {
  mkdir -p "$AGENT_SLOT_STATE_DIR"
  jaq -n -c --argjson f "$1" '{schema: "dotfiles.agent-slot/1", ts: "2026-10-01T00:00:00Z", event: "teardown",
    repo: "repoa", slot: 1, task: "t1", session_id: null, transcript: null, prs: [], request_id: null} + $f' \
    >>"$LEDGER"
}

# transcript ID [PROJECT-DIR]: a saved conversation under the sandboxed Claude projects directory; prints its path.
transcript() {
  local dir=$AGENT_SLOT_CLAUDE_PROJECTS/${2:--slots-repoa-1}
  mkdir -p "$dir"
  printf '{"type":"user","sessionId":"%s"}\n' "$1" >"$dir/$1.jsonl"
  printf '%s' "$dir/$1.jsonl"
}

# origin_branch BARE BRANCH: a commit on top of main pushed to BRANCH of the bare repo BARE. Sets HEAD_SHA.
origin_branch() {
  HEAD_SHA=$(git -C "$T/seed-repoa" commit-tree -p HEAD -m "work on $2" 'HEAD^{tree}')
  git -C "$T/seed-repoa" push -q "$1" "$HEAD_SHA:refs/heads/$2"
}

# fork_repo: a bare copy of repoa's origin that git reaches as git@github.com:me/repoa.git.
fork_repo() {
  mkdir -p "$T/forks"
  git clone -q --bare "$T/origins/repoa.git" "$T/forks/repoa.git"
  git config --file "$GIT_CONFIG_GLOBAL" --add "url.$T/forks/.insteadOf" git@github.com:me/
}

record_of() { jaq -c "$1" "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot.json"; }

# snapshot: every place a dry run must leave alone, as one string.
snapshot() {
  sha256sum "$LEDGER" 2>/dev/null || echo "no ledger"
  fingerprint "$AGENT_SLOT_ROOT"
  fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS"
}

@test "AE1: a teardown line with prs and a fork branch but no items or head is found by --pr; the dry run changes nothing" {
  gh_item pr 7 "Fix the login" MERGED "$FORK_HEAD"
  slot repoa 1 '{"task": "other"}'
  local path
  path=$(transcript "$S1")
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$path\", \"prs\": [7], \"branches\": [$FORK_BRANCH]}"
  local before
  before=$(snapshot)
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e --arg s "$S1" --arg t "$path" --argjson item "$PR7" '.dry_run == true and .would_reopen == true
    and .refusal == null and .item == $item and .source.event == "teardown" and .source.slot == 1
    and .source.session_id == $s and .session_id == $s and .transcript == $t and .transcript_exists == true
    and .head == {branch: "feat/x", remote: "fork", url: "git@github.com:me/repoa.git", oid: "abc123",
                  source: {branch: "gh", remote: "ledger"}}
    and .slot == "repoa/2" and .name == "repoa-pr7-fix-the-login" and .items == [$item] and .task == "t1"
    and .command == "claude --dangerously-skip-permissions --resume \($s) -n repoa-pr7-fix-the-login"
    and .prompt_delivered == null' <<<"$output"
  [ "$(snapshot)" = "$before" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
}

@test "AE2: a live slot that holds the item is named as its holder, and the dry run reports the refusal with exit 0" {
  gh_item issue 12 "Fix the widget"
  slot repoa 1 "{\"items\": [$ISSUE12], \"name\": \"repoa-issue12-fix-the-widget\"}"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$ISSUE12]}"
  reopen repoa --issue 12 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "item-held-by-slot" and .refusal.value == "repoa/1"
    and .refusal.next_step.command == "agent-slot resume repoa/1" and .source.key == "repoa/1"
    and (.refusal.message | contains("repoa-issue12-fix-the-widget")) and .slot == null' <<<"$output"
  reopen repoa --issue 12
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-held-by-slot" and .recovery.side_effects == "none"
    and .next_step.command == "agent-slot resume repoa/1"' <<<"$stderr"
}

@test "AE2: a slot torn down before items existed is reopened through --session, on the base; without it, the item is not found" {
  gh_item issue 12 "Fix the widget"
  local path
  path=$(transcript "$S2" -slots-repoa-2)
  teardown_event "{\"slot\": 2, \"task\": \"issue-12-next-move\", \"session_id\": \"$S2\", \"transcript\": \"$path\",
    \"branches\": []}"
  reopen repoa --issue up/repoa#12 --session "$S2" --dry-run
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e --arg s "$S2" --arg t "$path" --argjson item "$ISSUE12" '.would_reopen == true and .source.slot == 2
    and .session_id == $s and .transcript == $t and .transcript_exists == true and .items == [$item]
    and .name == "repoa-issue12-fix-the-widget" and .task == "issue-12-next-move"
    and .head == {branch: "main", remote: "origin", url: "https://github.com/up/repoa.git", oid: null,
                  source: {branch: "base", remote: "base"}}' <<<"$output"
  reopen repoa --issue 12 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "item-not-found-in-ledger"
    and (.refusal.message | contains("--session")) and .refusal.next_step.command == "agent-slot launch repoa --issue 12"
    and .source == null' <<<"$output"
  reopen repoa --issue 12
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-not-found-in-ledger" and .value == "up/repoa#12"' <<<"$stderr"
}

@test "--issue on a PR's number fails the dry run with exit 2 and item-kind-mismatch, naming --pr" {
  gh_item pr 7 "Fix the login"
  reopen repoa --issue 7 --dry-run
  [ "$status" -eq 2 ]
  jaq -e '.reason == "item-kind-mismatch" and (.next_step.command | contains("--pr 7"))' <<<"$stderr"
}

@test "a recorded branch URL that is a local path or on another host gives way to gh's head repository" {
  gh_item pr 7 "Fix the login" OPEN "$FORK_HEAD"
  local url
  for url in "$T/forks/repoa.git" git@gitlab.com:me/repoa.git; do
    : >"$LEDGER"
    teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"prs\": [7],
      \"branches\": [{\"name\": \"feat/x\", \"oid\": \"abc123\", \"remote\": \"fork\", \"url\": \"$url\"}]}"
    reopen repoa --pr 7 --dry-run
    [ "$status" -eq 0 ]
    jaq -e '.would_reopen == true and .head == {branch: "feat/x", remote: "fork",
      url: "https://github.com/me/repoa.git", oid: "abc123", source: {branch: "gh", remote: "gh"}}' <<<"$output"
  done
}

@test "the ledger's head names the branch, and a recorded URL of origin's repo is origin" {
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x"}'
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7],
    \"name\": \"repoa-pr7-old-title\", \"head\": \"feat/y\", \"branches\": [{\"name\": \"feat/y\", \"oid\": \"def456\",
    \"remote\": \"origin\", \"url\": \"git@github.com:up/repoa.git\"}]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.name == "repoa-pr7-old-title" and .head == {branch: "feat/y", remote: "origin",
    url: "https://github.com/up/repoa.git", oid: "def456", source: {branch: "ledger", remote: "ledger"}}' <<<"$output"
}

@test "--session naming an event whose items hold another item refuses with item-not-found-in-ledger" {
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\",
    \"items\": [{\"kind\": \"issue\", \"repo\": \"up/repoa\", \"number\": 13, \"title\": \"Other\"}]}"
  reopen repoa --issue 12 --session "$S1" --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == false and .refusal.reason == "item-not-found-in-ledger"
    and (.refusal.message | contains($s))' <<<"$output"
}

@test "--pr of the upstream repo on a fork-origin repo does not match a legacy line whose prs hold the number" {
  git -C "$AGENT_SLOT_DEV/repoa" remote set-url origin https://github.com/me/repoa.git
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"prs\": [7]}"
  reopen repoa --pr up/repoa#7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "item-not-found-in-ledger"' <<<"$output"
  reopen repoa --pr me/repoa#7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == true and .session_id == $s' <<<"$output"
}

@test "a ref or origin URL whose case differs from GitHub's name finds the item's teardown event and its holder" {
  gh_item pr 7 "Fix the login" MERGED '{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_1", "login": "up"}}' \
    Up/RepoA
  origin_branch "$T/origins/repoa.git" feat/x
  local pr7='{"kind": "pr", "repo": "Up/RepoA", "number": 7, "title": "Fix the login"}'
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$pr7]}"
  reopen repoa --pr up/repoa#7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == true and .session_id == $s and .item.repo == "Up/RepoA"' <<<"$output"
  : >"$LEDGER"
  teardown_event "{\"session_id\": \"$S2\", \"transcript\": \"$(transcript "$S2")\", \"prs\": [7]}"
  reopen repoa --pr 7
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e --arg s "$S2" '.created == true and .session_id == $s and .settled_prs == [7]' <<<"$output"
  record_of '.prs == [7] and .items[0].repo == "Up/RepoA"' | grep -qx true
  reopen repoa --pr UP/REPOA#7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "item-held-by-slot" and .refusal.value == "repoa/1"' \
    <<<"$output"
}

@test "of two teardown events for the item the newer wins, and --session picks the older one" {
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7]}"
  teardown_event '{"event": "launch", "slot": 3}'
  teardown_event "{\"slot\": 2, \"session_id\": \"$S2\", \"transcript\": \"$(transcript "$S2")\", \"items\": [$PR7]}"
  teardown_event "{\"slot\": 3, \"session_id\": \"$S3\", \"transcript\": \"$(transcript "$S3")\", \"prs\": [7]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S2" '.session_id == $s and .source.slot == 2' <<<"$output"
  reopen repoa --pr 7 --session "$S1" --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == true and .session_id == $s and .source.slot == 1' <<<"$output"
  run "$AGENT_SLOT" reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "up/repoa#7: would reopen repoa/2, torn down 2026-10-01T00:00:00Z, in repoa/1 as repoa-pr7-fix-the-login" ]]
  [[ $output == *"command: claude --dangerously-skip-permissions --resume $S2 -n repoa-pr7-fix-the-login"* ]]
}

@test "AE4: a transcript gone from every project directory refuses with transcript-missing and creates no slot" {
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repoa-1/$S1.jsonl\",
    \"items\": [$PR7]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == false and .transcript_exists == false and .session_id == $s
    and .refusal.reason == "transcript-missing" and .refusal.value == $s
    and .refusal.next_step.command == "agent-slot launch repoa --pr 7"' <<<"$output"
  reopen repoa --pr 7
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e --arg s "$S1" '.reason == "transcript-missing" and .value == $s and .recovery.side_effects == "none"
    and .next_step.command == "agent-slot launch repoa --pr 7"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
}

@test "a transcript gone from its recorded path is found by its session ID in another project directory" {
  gh_item pr 7 "Fix the login"
  local found
  found=$(transcript "$S1" -elsewhere)
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repoa-1/$S1.jsonl\",
    \"items\": [$PR7]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg t "$found" '.would_reopen == true and .transcript == $t and .transcript_exists == true' <<<"$output"
}

@test "no matching teardown event, an empty ledger, and no ledger at all each refuse with item-not-found-in-ledger" {
  gh_item pr 7 "Fix the login"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "item-not-found-in-ledger"' <<<"$output"
  [ ! -e "$LEDGER" ]
  run "$AGENT_SLOT" reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "up/repoa#7: would refuse with item-not-found-in-ledger: "* ]]
  [[ ${lines[1]} == "  next: agent-slot launch repoa --pr 7" ]]
  mkdir -p "$AGENT_SLOT_STATE_DIR"
  : >"$LEDGER"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.refusal.reason == "item-not-found-in-ledger"' <<<"$output"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"prs\": [8]}"
  teardown_event "{\"repo\": \"repob\", \"session_id\": \"$S2\", \"transcript\": \"$(transcript "$S2")\", \"prs\": [7]}"
  reopen repoa --pr 7
  [ "$status" -eq 1 ]
  jaq -e '.reason == "item-not-found-in-ledger" and .value == "up/repoa#7"
    and .next_step.command == "agent-slot launch repoa --pr 7"' <<<"$stderr"
}

@test "a holder that is tearing down refuses with retryable slot-busy" {
  gh_item pr 7 "Fix the login"
  slot repoa 1 "{\"state\": \"tearing-down\", \"prs\": [7]}"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"prs\": [7]}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "slot-busy" and .refusal.value == "repoa/1"
    and .refusal.recovery.retryable == true' <<<"$output"
}

@test "a live slot or a Claude agent that has the source's session open refuses the reopen" {
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7]}"
  slot repob 1 "{\"session_id\": \"$S1\"}"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.would_reopen == false and .refusal.reason == "item-held-by-slot"
    and .refusal.value == "repob/1" and .source.session_id == $s and .transcript_exists == true' <<<"$output"
  jaq '.session_id = "other"' "$AGENT_SLOT_ROOT/repob/1/.git/agent-slot.json" >"$T/r"
  mv "$T/r" "$AGENT_SLOT_ROOT/repob/1/.git/agent-slot.json"
  jaq -n -c --arg s "$S1" '[{pid: 4242, cwd: "/home/x/work", status: "idle", sessionId: $s}]' \
    >"$STUBS/claude-agents.json"
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "session-in-use" and .refusal.value == "4242 /home/x/work"
    and .refusal.next_step.action == "ask-operator"
    and .refusal.next_step.command == "agent-slot reopen repoa --pr 7"' <<<"$output"
  reopen repoa --pr 7
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "session-in-use" and .value == "4242 /home/x/work"' <<<"$stderr"
  stub claude '[ "$*" != "agents --json" ] || exit 1'
  reopen repoa --pr 7 --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal.reason == "session-in-use" and .refusal.value == null
    and (.refusal.message | contains("claude agents --json failed"))' <<<"$output"
}

@test "a slot that holds the reopen's request ID is the one the reopen returns" {
  gh_item pr 7 "Fix the login"
  slot repoa 1 "{\"request_id\": \"r-1\", \"items\": [$PR7], \"name\": \"repoa-pr7-fix-the-login\"}"
  printf 'reply to the review\n' >"$T/brief.md"
  reopen repoa --pr 7 --request-id r-1 --prompt-file "$T/brief.md" --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == false and .refusal == null and .slot == "repoa/1" and .source.key == "repoa/1"
    and .name == "repoa-pr7-fix-the-login" and .prompt_delivered == false' <<<"$output"
}

@test "a prompt file a reopen would deliver is reported as delivered" {
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7]}"
  printf 'reply to the review\n' >"$T/brief.md"
  reopen repoa --pr 7 --prompt-file "$T/brief.md" --dry-run
  [ "$status" -eq 0 ]
  jaq -e '.would_reopen == true and .prompt_delivered == true and .slot == "repoa/1"' <<<"$output"
  local expected
  printf -v expected 'claude --dangerously-skip-permissions --resume %s -n repoa-pr7-fix-the-login "$(cat %q)"' "$S1" \
    "$AGENT_SLOT_ROOT/repoa/1/.git/agent-slot-prompt.md"
  [ "$(jaq -r .command <<<"$output")" = "$expected" ]
}

@test "reopen takes exactly one of --pr or --issue, and only the options it documents" {
  reopen repoa --pr 7 --issue 12 --dry-run
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and (.message | contains("--pr or --issue"))' <<<"$stderr"
  reopen repoa --dry-run
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and (.message | contains("--pr <ref> or --issue <ref>"))' <<<"$stderr"
  reopen repoa --pr 7 --task x
  [ "$status" -eq 2 ]
  jaq -e '.reason == "usage" and .value == "--task"' <<<"$stderr"
  [ "$(grep -c '^gh ' "$CALLS")" -eq 0 ]
}

@test "reopen's help names name and items among the dry run's returns, with an example" {
  run "$AGENT_SLOT" reopen --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: agent-slot reopen <repo> (--pr <ref> | --issue <ref>)"* ]]
  [[ $output == *"--session"*"--dry-run"* ]]
  [[ $output == *$'\nreturns: '*name*items*would_reopen* ]] || [[ $output == *$'\nreturns: '*would_reopen*name*items* ]]
  [[ $output == *"example: agent-slot reopen "*"--dry-run"* ]]
}

# --- the reopen --------------------------------------------------------------------------------------------------------

@test "a reopen resumes the source's conversation in a fresh slot under its name, typing the first message as written" {
  gh_item pr 7 "Fix the login" MERGED '{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  origin_branch "$T/origins/repoa.git" feat/x
  local path brief=$T/brief.md before expected slot=$AGENT_SLOT_ROOT/repoa/1
  path=$(transcript "$S1")
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$path\", \"items\": [$PR7],
    \"name\": \"repoa-pr7-fix-the-login\", \"prs\": [7], \"head\": \"feat/x\", \"branches\": [{\"name\": \"feat/x\",
    \"oid\": \"$HEAD_SHA\", \"remote\": \"origin\", \"url\": \"https://github.com/up/repoa.git\"}]}"
  printf '%s' $'Answer the "review": it'"'"'s $HOME, $(touch '"$T"'/pwned), and `date`\nsecond line' >"$brief"
  before=$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")
  reopen repoa --pr 7 --prompt-file "$brief" --request-id r-1
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e --arg s "$S1" --argjson items "[$PR7]" '.created == true and .key == "repoa/1"
    and .name == "repoa-pr7-fix-the-login" and .items == $items and .session_id == $s and .prompt_delivered == true
    and .head_pushable == true and .settled_prs == [7] and .reopened_from.slot == 1' <<<"$output"
  jaq -e --arg s "$S1" --arg t "$path" --argjson items "[$PR7]" '.state == "active" and .session_id == $s
    and .transcript == $t and .items == $items and .name == "repoa-pr7-fix-the-login" and .named_as == .name
    and .task == "t1" and .prs == [7] and .settled_prs == [7] and .request_id == "r-1"
    and .reopened_from == {slot: 1, session_id: $s, ts: "2026-10-01T00:00:00Z"} and .finished_by_operator == false
    and ([has("release", "not_yet", "closing_sent_at", "last_check")] | any | not)
    and .created_at != "2026-10-01T00:00:00Z"' "$slot/.git/agent-slot.json"
  printf -v expected 'claude --dangerously-skip-permissions --resume %s -n repoa-pr7-fix-the-login "$(cat %q)"' "$S1" \
    "$slot/.git/agent-slot-prompt.md"
  [ "$(cat "$STUBS/typed-repoa-1")" = "$expected" ]
  mkdir -p "$T/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${@: -1}" >"%s/received"\n' "$T" >"$T/fakebin/claude"
  chmod +x "$T/fakebin/claude"
  (cd "$slot" && PATH="$T/fakebin:$PATH" bash -c "$(cat "$STUBS/typed-repoa-1")")
  cmp "$brief" "$T/received"
  [ ! -e "$T/pwned" ]
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$slot" rev-parse --abbrev-ref 'feat/x@{upstream}')" = origin/feat/x ]
  jaq -e -s --arg s "$S1" --argjson item "$PR7" '.[-1] | .event == "reopen" and .slot == 1 and .item == $item
    and .items == [$item] and .name == "repoa-pr7-fix-the-login" and .session_id == $s
    and .reopened_from == {slot: 1, session_id: $s, ts: "2026-10-01T00:00:00Z"}
    and .head.source == {branch: "ledger", remote: "ledger"}' "$LEDGER"
  [ "$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")" = "$before" ]
}

@test "the head comes from the ledger's head and branches: remote fork is added at the recorded URL and the branch tracks it" {
  fork_repo
  origin_branch "$T/forks/repoa.git" feat/x
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/gh", "headRepositoryOwner": {"id": "U_3", "login": "other"},
    "isCrossRepository": true}'
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7], \"prs\": [7],
    \"head\": \"feat/x\", \"branches\": [{\"name\": \"feat/x\", \"oid\": \"$HEAD_SHA\", \"remote\": \"fork\",
    \"url\": \"git@github.com:me/repoa.git\"}]}"
  local before slot=$AGENT_SLOT_ROOT/repoa/1
  before=$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")
  reopen repoa --pr 7
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.head_pushable == true and .settled_prs == []' <<<"$output"
  [ "$(git -C "$slot" config --get remote.fork.url)" = git@github.com:me/repoa.git ]
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$slot" for-each-ref --format='%(upstream:short) %(push:remotename)' refs/heads/feat/x)" = 'fork/feat/x fork' ]
  record_of '.prs == [7] and .settled_prs == []' | grep -qx true
  [ "$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")" = "$before" ]
}

@test "a reopen from a teardown line without branches takes the head from gh's view of the PR" {
  gh_item pr 7 "Fix the login" OPEN '{"headRefName": "feat/x", "headRepositoryOwner": {"id": "U_1", "login": "up"}}'
  origin_branch "$T/origins/repoa.git" feat/x
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"prs\": [7]}"
  local before slot=$AGENT_SLOT_ROOT/repoa/1
  before=$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")
  reopen repoa --pr 7
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e --argjson items "[$PR7]" '.name == "repoa-pr7-fix-the-login" and .items == $items' <<<"$output"
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = feat/x ]
  [ "$(git -C "$slot" rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git -C "$slot" rev-parse --abbrev-ref 'feat/x@{upstream}')" = origin/feat/x ]
  [ "$(cat "$STUBS/typed-repoa-1")" = "claude --dangerously-skip-permissions --resume $S1 -n repoa-pr7-fix-the-login" ]
  jaq -e -s '.[-1] | .event == "reopen" and .head.source == {branch: "gh", remote: "gh"}' "$LEDGER"
  [ "$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")" = "$before" ]
}

@test "a reopen of an issue whose recorded branch the remote no longer has makes the slot on the base, not pushable" {
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$ISSUE12],
    \"head\": \"feat/gone\", \"branches\": [{\"name\": \"feat/gone\", \"oid\": \"abc123\", \"remote\": \"origin\",
    \"url\": \"https://github.com/up/repoa.git\"}]}"
  reopen repoa --issue 12
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.created == true and .key == "repoa/1" and .head_pushable == false' <<<"$output"
  [ "$(git -C "$AGENT_SLOT_ROOT/repoa/1" symbolic-ref --short HEAD)" = main ]
}

@test "a reopen whose clone fails rolls the slot back, leaves no claim, and writes no reopen line" {
  gh_item pr 7 "Fix the login"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$PR7]}"
  mv "$T/origins/repoa.git" "$T/origins/moved.git"
  local before
  before=$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")
  reopen repoa --pr 7 --request-id r-2
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "clone-failed" and .recovery.retryable == true and .recovery.side_effects == "none"
    and .next_step.command == "agent-slot reopen repoa --pr 7 --request-id r-2"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ ! -e "$AGENT_SLOT_ROOT/repoa/.1.claim.json" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
  jaq -e -s 'all(.[]; .event != "reopen")' "$LEDGER"
  [ "$(fingerprint "$AGENT_SLOT_CLAUDE_PROJECTS")" = "$before" ]
}

@test "a retry with the reopen's request ID returns its slot; a second reopen without it is refused with item-held-by-slot" {
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$ISSUE12],
    \"name\": \"repoa-issue12-fix-the-widget\"}"
  printf 'pick it back up\n' >"$T/brief.md"
  reopen repoa --issue 12 --request-id r-1 --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  jaq -e '.created == true and .key == "repoa/1" and .prompt_delivered == true' <<<"$output"
  [ "$(git -C "$AGENT_SLOT_ROOT/repoa/1" symbolic-ref --short HEAD)" = main ]
  reopen repoa --issue 12 --request-id r-1 --prompt-file "$T/brief.md"
  [ "$status" -eq 0 ]
  jaq -e --arg s "$S1" '.created == false and .key == "repoa/1" and .name == "repoa-issue12-fix-the-widget"
    and .session_id == $s and .prompt_delivered == true' <<<"$output"
  reopen repoa --issue 12
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-held-by-slot" and .value == "repoa/1"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/2" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 3 ]
  [ "$(jaq -s '[.[] | select(.event == "reopen")] | length' "$LEDGER")" -eq 1 ]
}

@test "the settled PRs are the source's PRs that are merged or closed when the slot is reopened" {
  gh_item issue 12 "Fix the widget"
  jaq -n -c '[{number: 7, state: "MERGED"}, {number: 8, state: "CLOSED"}, {number: 9, state: "OPEN"}]
    | map(. + {headRefName: "b\(.number)", headRefOid: "0", createdAt: "2026-09-01T00:00:00Z", title: "t", url: "u"})' \
    >"$STUBS/gh-prs.json"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$ISSUE12],
    \"prs\": [7, 8, 9]}"
  reopen repoa --issue 12
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  record_of '.prs == [7, 8, 9] and .settled_prs == [7, 8]' | grep -qx true
}

@test "a reopen that cannot read which of the source's PRs have settled fails with pr-state-unknown and makes no slot" {
  gh_item issue 12 "Fix the widget"
  teardown_event "{\"session_id\": \"$S1\", \"transcript\": \"$(transcript "$S1")\", \"items\": [$ISSUE12],
    \"prs\": [7]}"
  reopen repoa --issue 12
  [ "$status" -eq 1 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "pr-state-unknown" and .recovery.retryable == true and .recovery.side_effects == "none"
    and .next_step.command == "agent-slot reopen repoa --issue 12"' <<<"$stderr"
  [ ! -e "$AGENT_SLOT_ROOT/repoa/1" ]
  [ "$(grep -c 'new-session' "$CALLS")" -eq 0 ]
}
