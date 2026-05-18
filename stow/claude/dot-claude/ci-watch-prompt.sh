#!/usr/bin/env bash
# ci-watch-prompt.sh — PostToolUse hook for Claude Code
#
# Policy (single source of truth — keep this header current):
# ============================================================
# After ANY action that triggers GitHub Actions, the agent must monitor every
# triggered run to completion before moving on. This hook fires after Bash
# tool invocations matching:
#
#   - git push (any branch, any ref, including tags)
#   - gh pr create
#   - gh pr merge
#   - gh release create
#   - gh workflow run / gh api ... dispatches
#
# When matched, the hook:
#   1. Enumerates currently-active runs on the relevant branch via gh run list
#   2. Emits a system reminder listing the active runs + the exact commands
#      the agent should spawn in background to watch them
#
# The agent must:
#   - Spawn `gh run watch <id> --exit-status` per active run with
#     run_in_background: true (one Bash call per run, in parallel)
#   - For PR creates/merges, prefer `gh pr checks <pr> --watch` which covers
#     all checks across all triggered workflows on the PR head
#   - After each run completes, re-enumerate to catch dispatched chains
#     (release.yml → homebrew dispatch → finalize-release etc.)
#   - Never proceed past a red CI run; investigate and fix before moving on
#
# This hook never blocks. It only informs. The agent decides what to watch.
# ============================================================

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

# Match commands that trigger GitHub Actions
if ! printf '%s' "$command" | grep -qE '\bgit push\b|\bgh pr (create|merge)\b|\bgh release create\b|\bgh workflow run\b|\bgh api .*/dispatches\b'; then
  exit 0
fi

# Skip git push variants that don't actually trigger CI:
#   --dry-run        (no actual push)
#   --delete         (deleting a remote ref doesn't fire workflows)
#   --tags only      (tag pushes do trigger CI for tag-listening workflows, so don't skip)
if printf '%s' "$command" | grep -qE '\bgit push\b' \
   && printf '%s' "$command" | grep -qE -- '--dry-run|--delete'; then
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
  echo "REQUIRED ACTION — spawn one Bash call per run in parallel,"
  echo "all with run_in_background: true:"
  echo ""
  printf '%s' "$runs" | "$JQ" -r '.[] | "  gh run watch \(.databaseId) --exit-status"'
  echo ""
  echo "If this was a PR action, prefer the PR-scoped watcher instead:"
  echo "  gh pr checks <pr-number> --watch"
  echo ""
  echo "After all watchers complete, re-run gh run list to catch any"
  echo "dispatched chains (release.yml → homebrew dispatch → finalize-release etc.)."
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
