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
#   - VERIFY STATUS AFTER COMPLETION, NOT JUST EXIT CODE. `gh pr checks --watch`
#     exits 0 once all checks complete — pass OR fail. `gh run watch
#     --exit-status` is reliable for a single run, but the PR-scoped watcher is
#     not. After every completion notification, re-query and read per-check
#     conclusions explicitly:
#       gh pr view <num> --json statusCheckRollup,mergeStateStatus \
#         --jq '{merge: .mergeStateStatus, checks: [.statusCheckRollup[] | {name, conclusion}]}'
#     A check is green only when conclusion == "SUCCESS". A PR is green only
#     when every check is SUCCESS and mergeStateStatus is CLEAN (or BEHIND).
#     Same for run-scoped: re-query `gh run view <id> --json conclusion --jq
#     .conclusion` and assert it is "success" — not just that the watch exited.
#   - After each run completes, re-enumerate to catch dispatched chains. Two
#     dispatch shapes exist and both need watching:
#       (a) Same-repo chains: release.yml → finalize-release.yml triggered by
#           a `workflow_run` event in the same repo. Visible to
#           `gh run list --branch <branch>` after the parent completes.
#       (b) Cross-repo dispatches: release.yml fires a
#           `peter-evans/repository-dispatch` (or `gh api .../dispatches`) at
#           ANOTHER repo (e.g. brettdavies/homebrew-tap), which runs its own
#           workflow and may dispatch BACK to the originating repo
#           (e.g. homebrew-tap → finalize-release in agentnative-cli).
#           These are NOT visible to a branch-scoped `gh run list` on the
#           originating repo. The agent must:
#             1. Identify the target repo from the workflow source (look for
#                `repository_dispatch` / `repository-dispatch` action /
#                `gh api repos/<owner>/<repo>/dispatches`).
#             2. Watch the target repo: `gh run list -R <target>` filtered to
#                recent runs, then `gh run watch <id> -R <target>
#                --exit-status` for each.
#             3. After the target's runs complete, re-query the ORIGINATING
#                repo for callback dispatches. The chain can bounce multiple
#                times. Repeat until both repos quiesce.
#           Reference shape: agentnative-cli release.yml dispatches to
#           brettdavies/homebrew-tap → tap's workflow updates the formula and
#           dispatches back → cli's finalize-release.yml flips the GitHub
#           Release out of draft.
#   - Never proceed past a red CI run; investigate and fix before moving on.
#     Apply the same rule to cross-repo dispatched runs — a red run on the
#     dispatched repo blocks the originating workflow's contract just as
#     surely as a red run on the originating branch.
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
