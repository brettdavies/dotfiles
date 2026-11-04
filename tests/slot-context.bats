#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-context.sh, the SessionStart hook that records a slot's Claude session and
# hands the agent its slot context.
#
# Run: bats tests/slot-context.bats
#
# The hook runs as the pane's top-level Claude: a pane shell that records its own pid as the pane's #{pane_pid}, then
# `claude` (a symlink to bash, so /proc comm reads claude), then the hook. The tmux stub answers display from files.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-context.sh"
RUNS='"$@"; exit $?'

setup_file() {
  load lib/platform
  require_linux "the hook finds the pane's top-level Claude through /proc"
}

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" TMUX_PANE=%3
  FAKE=$T/fake
  mkdir -p "$FAKE"
  ln -s "$(command -v bash)" "$FAKE/claude"
  printf '%s' repo-1 >"$STUBS/pane-session"
  printf '#!/usr/bin/env bash\nprintf %%s "$$" >"$STUBS/pane-pid"\n"$@"\nexit $?\n' >"$T/pane-shell"
  chmod +x "$T/pane-shell"
  stub tmux '
case " $* " in
  *" display "*) printf "%s\t%s\t%s\n" "$(cat "$STUBS/pane-session")" "$(cat "$STUBS/pane-pid")" /dev/null ;;
esac'
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  export AGENT_SLOT_SKILL=$T/SKILL.md
  cat >"$AGENT_SLOT_SKILL" <<'SKILL'
# Agent slots

## Hand a task to a slot

Launching text the slot's context leaves out.

## Inside a slot

Work only in the slot. Stage with `git add`, then run a plain `git commit`. Create no worktrees inside the slot.

Your task is finished when each of its PRs is open, closed, or merged, and nothing is left unpushed. Then close it out:

1. Run `/compound-engineering:ce-compound mode:non-interactive depth:full <finding>` once per finding.
2. Run `/compound-engineering:ce-compound mode:refresh mode:non-interactive <scope>`.
3. Run `agent-slot release --output json`.

A slot you launch from here is independent: hand off the brief, report its key, and neither wait on it nor watch it.

## When a slot goes away

Teardown text the slot's context leaves out.
SKILL
}

# start SESSION_ID SOURCE [CWD] [HOOK]: runs the hook, or the copy HOOK names, for a SessionStart as the pane's
# top-level Claude. The payload's transcript_path is REPORTED when set, else /t/<SESSION_ID>.jsonl.
start() {
  jaq -n -c --arg sid "$1" --arg src "$2" --arg cwd "${3:-$SLOT}" --arg tr "${REPORTED:-/t/$1.jsonl}" \
    '{hook_event_name: "SessionStart", session_id: $sid, transcript_path: $tr, cwd: $cwd,
      source: $src}' | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "${4:-$HOOK}"
}

record() { jaq -c "$1" "$SLOT/.git/agent-slot.json"; }

ledger() { jaq -c "select(.event == \"$1\")" "$LEDGER" 2>/dev/null || true; }

@test "inside a slot the hook returns additionalContext naming the slot, task, base, and prime" {
  slot repo 1 '{"task": "fix-login"}'
  run start s1 startup
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$output"
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"repo/1"* ]]
  [[ $context == *"$SLOT"* ]]
  [[ $context == *fix-login* ]]
  [[ $context == *"base branch is main"* ]]
  [[ $context == *"$AGENT_SLOT_DEV/repo"*read-only* ]]
  [[ $context == *"meant for Brett"*"$AGENT_SLOT_DEV/repo/.context/"* ]]
  [[ $context == *sd-commit-doc* ]]
  [[ $context == *"--output json"* ]]
  [[ $context == *"agent-slot whoami"* ]]
  [[ $context == *"agent-slot schema"* ]]
  [[ $context == *"agent-slot launch <repo> --model <opus|sonnet> --request-id <id> --prompt-file <brief>"* ]]
  [[ $context == *"ask the operator"* ]]
  [[ $context == *"--dangerously-skip-permissions"* ]]
}

@test "a slot of the vault is told to work on main, rebase before each push, and keep the vault's content in the vault" {
  printf '%s' obsidian-vault-1 >"$STUBS/pane-session"
  slot obsidian-vault 1 '{"task": "tidy-notes"}'
  run start s1 startup "$AGENT_SLOT_ROOT/obsidian-vault/1"
  [ "$status" -eq 0 ]
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"only your own task's work, on main"* ]]
  [[ $context == *'`git fetch` then `git rebase origin/main` before each push'* ]]
  [[ $context == *"Nothing automated commits in the vault"* ]]
  [[ $context == *"no vault content"*"docs/solutions"* ]]
  [[ $context == *"finished when its work is on origin/main"* ]]
  [[ $context == *"Commit only your own task's work, on main, with no branch or PR"* ]]
  [[ $context == *"record only a tooling or process lesson, with no note title, path, name, or quotation"* ]]
}

@test "a slot of any other repo gets no vault rules" {
  slot repo 1 '{"task": "fix-login"}'
  run start s1 startup
  [ "$status" -eq 0 ]
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context != *"This is the Obsidian vault."* ]]
  [[ $context != *"finished when its work is on origin/main"* ]]
}

@test "a slot with its own solutions worktree is told docs/solutions is that worktree; an older slot, the shared repo" {
  slot repo 1 '{"task": "t", "solutions_worktree": "/s/repo/.solutions/1-abc"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"docs/solutions is this slot's own worktree of the solutions repo"*sd-commit-doc* ]]
  [[ $context != *"shared with every other agent"* ]]
  jaq '.solutions_worktree = null' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  run start s1 resume
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"docs/solutions is the solutions repo shared with every other agent"*sd-commit-doc* ]]
  [[ $context != *"own worktree"* ]]
}

@test "the context carries the agent-slot skill's Inside a slot section, from its heading to the next" {
  slot repo 1 '{"task": "t"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"agent-slot skill's \"Inside a slot\" section ($AGENT_SLOT_SKILL), and they bind you"* ]]
  [[ $context == *"Stage with \`git add\`"*"finished when each of its PRs is open, closed, or merged"*\
"/compound-engineering:ce-compound mode:non-interactive depth:full"*\
"/compound-engineering:ce-compound mode:refresh mode:non-interactive"*"agent-slot release --output json"* ]]
  [[ $context != *"Launching text the slot's context leaves out."* ]]
  [[ $context != *"Teardown text the slot's context leaves out."* ]]
  [[ $context == *"need not run \`agent-slot check\` on this slot"*"checked-by-own-agent"* ]]
}

@test "with no readable skill, the context tells the agent to load /agent-slot before anything else" {
  slot repo 1 '{"task": "t"}'
  export AGENT_SLOT_SKILL=$T/missing/SKILL.md
  run start s1 startup
  [ "$status" -eq 0 ]
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"Before anything else, load the \`/agent-slot\` skill and follow its \"Inside a slot\" section"* ]]
}

@test "the context makes a slot the agent launches fire-and-forget, and keeps it watching its own PRs and CI" {
  slot repo 1 '{"task": "t"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"A slot you launch from here is independent: hand off the brief, report its key"* ]]
  [[ $context == *"Launching a slot is not a delegated wait: set no watchdog or watcher on it;"* ]]
  [[ $context == *"watch your own PRs and CI to the end."* ]]
}

@test "the context runs every plan through three reviews and sends a person's decision to the brief's session" {
  slot repo 1 '{"task": "t"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"every plan you write"*"/plan-eng-review"*"/plan-devex-review"*\
"/compound-engineering:ce-doc-review"*"commit and push the plan once it is written and again after each review."*\
"Your task is finished when"* ]]
  [[ $context == *"Answer each review question yourself"*"record the choice and its evidence in the plan."* ]]
  [[ $context == *"Nobody watches this tab, so a question asked here, \`AskUserQuestion\` included, is never answered."* ]]
  [[ $context == *"a name, a breaking change, a version call, or a scope cut, to the session your brief reports to"*\
"one \`SendMessage\`: the question, the options, your recommendation, and its evidence."* ]]
  [[ $context == *"then end your turn; the answer arrives as a message."* ]]
  [[ $context == *"If the brief names no such session, leave the decision open in the plan and in your report."* ]]
}

@test "the context sends a reopen to the brief's session, since its ask rule prompts on --help and --dry-run too" {
  slot repo 1 '{"task": "t"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"\`agent-slot reopen\` asks for permission, \`--help\` and \`--dry-run\` included, and nobody here \
can grant it: send a reopen to the session your brief reports to."* ]]
}

@test "the context says the agent runs unattended and that its dialogs are denied" {
  slot repo 1 '{"task": "t"}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"You run unattended: nobody answers a prompt or a question in this tab, so a hook denies every \
permission request, \`AskUserQuestion\`, and plan mode here; do the work another way within your brief, and send a \
decision only a person can make to the session your brief reports to."* ]]
}

@test "a slot lock that cannot be opened is logged, and the context still prints" {
  slot repo 1 '{"task": "t"}'
  mkdir -p "$AGENT_SLOT_ROOT/repo/.1.lock"
  run start s1 startup
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.additionalContext | contains("repo/1")' <<<"$output"
  grep -q 'slot repo/1 lock not taken' "$AGENT_SLOT_STATE_DIR/logs/hooks.log"
}

@test "a slot with no task says so" {
  slot repo 1
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"no task name"* ]]
  [[ $context != *"Work items"* ]]
}

@test "a slot with work items has its context name each one by kind, repo, number, and title" {
  slot repo 1 '{"task": "t", "name": "repo-pr887-fix-trns", "items": [
    {"kind": "pr", "repo": "up/repo", "number": 887, "title": "Fix 16-bit to 8-bit reduction with tRNS"},
    {"kind": "issue", "repo": "up/repo", "number": 886, "title": "16-bit tRNS lost"}]}'
  run start s1 startup
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"Task: t."*"Work items: PR up/repo#887 (Fix 16-bit to 8-bit reduction with tRNS), \
issue up/repo#886 (16-bit tRNS lost)."* ]]
}

@test "a context line holding an apostrophe prints as written" {
  # The hook finds agent-slot from its own path, so the copy sits in a tree shaped like the repo.
  local copy=$T/checkout/stow/claude/dot-claude/slot-context.sh
  mkdir -p "${copy%/*}" "$T/checkout/scripts"
  ln -s "$BATS_TEST_DIRNAME/../scripts/agent-slot" "$T/checkout/scripts/agent-slot"
  sed "s/names this slot\./names this slot's clone./" "$HOOK" >"$copy"
  chmod +x "$copy"
  grep -qF "this slot's clone" "$copy"
  slot repo 1 '{"task": "t"}'
  run start s1 startup "$SLOT" "$copy"
  context=$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ $context == *"names this slot's clone."* ]]
}

@test "outside a slot the hook prints nothing" {
  slot repo 1
  mkdir -p "$T/elsewhere"
  run start s1 startup "$T/elsewhere"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
}

@test "the slot is found from the working directory when the payload has none" {
  slot repo 1 '{"task": "t"}'
  cd "$SLOT"
  output=$(printf '{"hook_event_name":"SessionStart","session_id":"s1"}' \
    | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK")
  [[ $(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output") == *"repo/1"* ]]
}

@test "outside the slot socket, or for a Claude not on the pane's shell, the hook prints nothing" {
  slot repo 1
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run start s1 startup
  [ -z "$output" ]

  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0"
  output=$(printf '{"session_id":"s1","cwd":"%s"}' "$SLOT" | "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude \
    bash -c "$RUNS" tool "$FAKE/claude" -c "$RUNS" claude "$HOOK")
  [ -z "$output" ]

  printf '%s' repo-1-git >"$STUBS/pane-session"
  run start s1 startup
  [ -z "$output" ]
  [ "$(record .session_id)" = '"11111111-2222-3333-4444-555555555555"' ]
  [ ! -e "$LEDGER" ]
}

@test "a clear with a new session ID updates the record and appends a session line" {
  slot repo 1 '{"task": "t", "session_id": "s1", "transcript": "/t/s1.jsonl", "ready_at": 5}'
  run start s2 clear
  [ "$status" -eq 0 ]
  [ "$(record .session_id)" = '"s2"' ]
  [ "$(record .transcript)" = '"/t/s2.jsonl"' ]
  [ "$(ledger session | wc -l)" -eq 1 ]
  ledger session | jaq -e '.repo == "repo" and .slot == 1 and .task == "t" and .session_id == "s2"
    and .transcript == "/t/s2.jsonl" and .source == "clear" and .schema == "dotfiles.agent-slot/1"'
}

@test "a resume whose reported transcript is missing records the session's transcript, found by its ID" {
  local sid=e999f4ab-8387-4992-bb05-f4e6041b9b68 real
  real=$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repo-2/$sid.jsonl
  mkdir -p "${real%/*}"
  echo '{}' >"$real"
  slot repo 1 "{\"session_id\": \"$sid\", \"transcript\": \"$real\", \"ready_at\": 5}"
  export REPORTED=$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repo-1/$sid.jsonl
  start "$sid" resume >/dev/null
  [ "$(record .transcript)" = "\"$real\"" ]
  [ -z "$(ledger session)" ]
  start "$sid" compact >/dev/null
  [ "$(record .transcript)" = "\"$real\"" ]
  [ -z "$(ledger session)" ]
}

@test "a start whose session has no transcript anywhere yet records the reported path" {
  local sid=0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0 reported
  reported=$AGENT_SLOT_CLAUDE_PROJECTS/-slots-repo-1/$sid.jsonl
  slot repo 1
  REPORTED=$reported start "$sid" startup >/dev/null
  [ "$(record .transcript)" = "\"$reported\"" ]
  ledger session | jaq -e --arg t "$reported" '.transcript == $t'
}

@test "a start with the session already recorded appends no session line" {
  slot repo 1 '{"session_id": "s1", "transcript": "/t/s1.jsonl", "ready_at": 5}'
  start s1 resume >/dev/null
  [ -z "$(ledger session)" ]
}

@test "the first start appends one ready line with the launch's request ID; later starts append none" {
  slot repo 1 '{"request_id": "req-1", "session_id": "s1"}'
  start s1 startup >/dev/null
  [ "$(ledger ready | wc -l)" -eq 1 ]
  ledger ready | jaq -e '.request_id == "req-1" and (.ready_at | type == "number") and .repo == "repo"
    and .slot == 1 and .session_id == "s1"'
  [ "$(record '.ready_at | type')" = '"number"' ]
  ready_at=$(record .ready_at)

  start s2 clear >/dev/null
  start s2 resume >/dev/null
  [ "$(ledger ready | wc -l)" -eq 1 ]
  [ "$(record .ready_at)" = "$ready_at" ]
}

@test "a first start with no request ID marks the slot ready and appends no ready line" {
  slot repo 1
  start s1 startup >/dev/null
  [ "$(record '.ready_at | type')" = '"number"' ]
  [ -z "$(ledger ready)" ]
}
