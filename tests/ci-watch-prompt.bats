#!/usr/bin/env bats
# Tests for the PostToolUse hook that lists the GitHub Actions runs an action
# started and prints the watcher command for each. A stubbed `gh` answers
# `gh run list` from a fixture the way gh does, filtering by --commit or
# --branch and then applying --jq; a stubbed `sleep` skips the hook's wait for
# GitHub to register new runs.
#
# Run: bats tests/ci-watch-prompt.bats
# run-tests: parallel

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ci-watch-prompt.sh"

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  # An inherited GIT_DIR outranks the fixture's cwd, and git exports it to hooks.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b feat/x "$REPO"
  commit() { git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m "$1"; }
  commit one
  OLD_SHA=$(git -C "$REPO" rev-parse HEAD)
  commit two
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

  # 101 is the replaced head's run, still in progress while cancel-in-progress
  # stops it; 202 is the pushed head's run, pending behind it.
  export RUNS="$BATS_TEST_TMPDIR/runs.json"
  jaq -n --arg old "$OLD_SHA" --arg head "$HEAD_SHA" '[
    {databaseId: 101, headSha: $old, headBranch: "feat/x", status: "in_progress"},
    {databaseId: 202, headSha: $head, headBranch: "feat/x", status: "pending"},
    {databaseId: 303, headSha: $old, headBranch: "feat/x", status: "completed"}
  ] | map(. + {name: "CI", workflowName: "CI", event: "push", createdAt: "2026-11-04T00:00:00Z"})' >"$RUNS"

  STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/sleep"
  cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "run list" ] || exit 1
shift 2
commit="" branch="" filter="."
while [ $# -gt 0 ]; do
  case $1 in
    --commit) commit=$2 ;;
    --branch) branch=$2 ;;
    --jq) filter=$2 ;;
    --limit | --json) ;;
    *) exit 1 ;;
  esac
  shift 2
done
jaq -c --arg c "$commit" --arg b "$branch" \
  'map(select(($c == "" or .headSha == $c) and ($b == "" or .headBranch == $b)))' "$RUNS" | jaq -c "$filter"
EOF
  chmod +x "$STUBS/sleep" "$STUBS/gh"
}

# Runs the hook after a Bash call of the given command. Sets CTX to the
# reminder the hook adds, empty when it prints nothing.
# Args: command
remind() {
  local out
  out=$(cd "$REPO" && jaq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}' |
    PATH="$STUBS:$PATH" "$HOOK")
  CTX=$(printf '%s' "$out" | jaq -r '.hookSpecificOutput.additionalContext // ""')
}

@test "a push lists the pushed commit's unfinished runs and no other head's" {
  remind 'git push origin HEAD:feat/x'
  [[ "$CTX" != *101* ]]
  [[ "$CTX" == *"  - 202  CI / CI  [pending, event=push]"* ]]
  [[ "$CTX" != *303* ]]
}

@test "a workflow dispatch lists every unfinished run on the branch, pending included" {
  remind 'gh workflow run ci.yml'
  [[ "$CTX" == *"  - 101  CI / CI  [in_progress, event=push]"* ]]
  [[ "$CTX" == *"  - 202  CI / CI  [pending, event=push]"* ]]
  [[ "$CTX" != *303* ]]
}

@test "the printed watcher polls every 30 s" {
  remind 'gh workflow run ci.yml'
  [[ "$CTX" == *"  gh run watch 101 --exit-status --interval 30"* ]]
}

@test "the reminder tells the agent to watch only the runs its own action started" {
  remind 'gh workflow run ci.yml'
  [[ "$CTX" == *"Watch only the runs your own action started."* ]]
}

@test "the reminder bounds each watcher near its usual length and says to read the state on a timeout" {
  remind 'gh workflow run ci.yml'
  [[ "$CTX" == *"Wrap each in the shell's timeout command (timeout <seconds> gh run"* ]]
  [[ "$CTX" == *"gh run view <id> --json status,conclusion before waiting again."* ]]
}
