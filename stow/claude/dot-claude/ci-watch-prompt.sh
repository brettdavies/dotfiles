#!/usr/bin/env bash
# ci-watch-prompt.sh — PostToolUse hook for Claude Code
#
# After ANY action that triggers GitHub Actions, list active runs and tell the
# agent to run ~/.claude/ci-verify.sh. That script is the gate: it waits for
# every required check (including reusable-workflow jobs and followed dispatch
# chains) and exits 0 only when they passed. This hook never blocks. It only
# informs. The Stop hook (ci-stop-gate.sh) refuses the turn while CI is red
# or still running.
#
# Matchers: git push, gh pr create/merge, gh release create, gh workflow run,
# gh api .../dispatches. Skip git push --dry-run and --delete.
#
# Policy source of truth: the ~/.claude/ci-verify.sh header.

set -uo pipefail

# Pick a JSON CLI — prefer jaq (faster, brettdavies default), fall back to jq
if command -v jaq >/dev/null 2>&1; then
  JQ=jaq
elif command -v jq >/dev/null 2>&1; then
  JQ=jq
else
  exit 0
fi

# Read PostToolUse payload from stdin
payload=$(cat)

# Only react to Bash tool calls
tool_name=$(printf '%s' "$payload" | "$JQ" -r '.tool_name // ""' 2>/dev/null)
[[ "$tool_name" == "Bash" ]] || exit 0

command=$(printf '%s' "$payload" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null)
[[ -n "$command" ]] || exit 0

# Match commands that trigger GitHub Actions.
#
# Here-strings, not pipes: `grep -q` exits at its first match, so a piped
# producer takes SIGPIPE on a command past the pipe buffer and `pipefail` turns
# the match into a non-zero pipeline — reading a CI-triggering command as one
# that triggers nothing, and skipping the watch prompt for it.
if ! grep -qE '\bgit push\b|\bgh pr (create|merge)\b|\bgh release create\b|\bgh workflow run\b|\bgh api .*/dispatches\b' <<<"$command"; then
  exit 0
fi

# Skip git push variants that don't actually trigger CI:
#   --dry-run        (no actual push)
#   --delete         (deleting a remote ref doesn't fire workflows)
#   --tags only      (tag pushes do trigger CI for tag-listening workflows, so don't skip)
if grep -qE '\bgit push\b' <<<"$command" \
  && grep -qE -- '--dry-run|--delete' <<<"$command"; then
  exit 0
fi

# We're in a git repo? (Hook fires for any Bash, command might run elsewhere.)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

# Determine which branch to query
branch=$(git branch --show-current 2>/dev/null)
[[ -n "$branch" ]] || exit 0

# Need gh
command -v gh >/dev/null 2>&1 || exit 0

# Give GitHub a moment to register the new runs (push → API visibility lag),
# then retry up to 5 times with a 2 s delay between attempts. The API can be
# slow to surface newly-triggered runs — especially after `gh pr create`,
# where the PR-creation call returns before workflow runs are visible to
# `gh run list`. Worst-case total wait is 2 + 4×2 = 10 s, within the 15 s
# hook timeout.
sleep 2
runs=""
for attempt in 1 2 3 4 5; do
  runs=$(gh run list --branch "$branch" --limit 10 \
    --json databaseId,name,status,workflowName,event,createdAt \
    --jq '[.[] | select(.status == "in_progress" or .status == "queued")]' 2>/dev/null)
  [[ -n "$runs" && "$runs" != "[]" ]] && break
  [[ "$attempt" -lt 5 ]] && sleep 2
done

# If gh failed or no active runs after all retries, stay silent
[[ -n "$runs" && "$runs" != "[]" ]] || exit 0

# Build the agent-facing reminder text
reminder=$({
  echo "[CI MONITORING] Active GitHub Actions runs detected after your last command."
  echo ""
  echo "Branch: $branch"
  echo "Repo:   $(basename "$repo_root")"
  echo ""
  echo "Active runs:"
  printf '%s' "$runs" | "$JQ" -r '.[] | "  - \(.databaseId)  \(.workflowName) / \(.name)  [\(.status), event=\(.event)]"'
  echo ""
  echo "REQUIRED ACTION — spawn this once with run_in_background: true:"
  echo ""
  echo "  ~/.claude/ci-verify.sh"
  echo ""
  echo "ci-verify waits for every required check (reusable-workflow jobs and"
  echo "followed dispatch chains included), then exits 0 only when they passed."
  echo "Do not treat a finished gh watcher as the gate."
  echo "Never proceed past a red run."
})

# Emit as Claude Code hook JSON (hookSpecificOutput.additionalContext)
# shellcheck disable=SC2016  # jaq filter uses single quotes; $ctx is a jaq variable, not shell
"$JQ" -n --arg ctx "$reminder" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'

exit 0
