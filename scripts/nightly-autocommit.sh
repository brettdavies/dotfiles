#!/usr/bin/env bash
set -euo pipefail

# Nightly autocommit: fast-forward selected repos, then commit and push their
# pending changes, or in sync mode only report them.
# Runs via systemd timer between 2-4 AM CT. Delegates staging and commit
# message generation to claude -p, which follows the project's Conventional
# Commits template and applies SRP (multiple commits when appropriate).
#
# Falls back to git add -A + generic message only if claude is unavailable.
#
# Usage: nightly-autocommit.sh [--dry-run]
#
# NIGHTLY_AUTOCOMMIT_REPOS (newline-separated entries) replaces the repo list
# below, and NIGHTLY_AUTOCOMMIT_LOG_DIR the log directory.

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

LOG_DIR=${NIGHTLY_AUTOCOMMIT_LOG_DIR:-$HOME/.local/share/nightly-autocommit}
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nightly-autocommit.log"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" | tee -a "$LOG_FILE"; }

# --- Repo Configuration ---
# Each entry: path|default_branch|mode, where mode is commit (the default) or
# sync. A sync repo is fast-forwarded and each change origin lacks is logged as
# a WARNING, never staged, committed, or deleted. solutions-docs is sync because
# prime sessions draft in it and publish by sd-commit-doc's copy-out, so a
# change there can be a draft still in progress. The Obsidian vault is never
# listed: its contents are sensitive, so it is committed by hand.
REPOS=(
  "$HOME/dev/solutions-docs|main|sync"
  "$HOME/dev/agent-skills|main"
)
if [[ -n ${NIGHTLY_AUTOCOMMIT_REPOS:-} ]]; then
  REPOS=()
  while IFS= read -r entry; do
    [[ -z $entry ]] || REPOS+=("$entry")
  done <<<"$NIGHTLY_AUTOCOMMIT_REPOS"
fi

# Claude timeout: 2 minutes per repo (enough time to read diffs, split commits, write messages)
CLAUDE_TIMEOUT=120

COMMITTED=0
SKIPPED=0
FAILED=0
SYNCED=0

# Usage: log_strays <repo_path> <repo_name>; one WARNING line per path that
# differs from HEAD, untracked files included and ignored ones not.
log_strays() {
  local entry
  while IFS= read -r -d '' entry; do
    log "WARNING: $2 — stray not committed (sync mode): ${entry:3}"
  done < <(git -C "$1" status --porcelain=v1 -z --untracked-files=all --no-renames)
}

log "=== Nightly autocommit started (dry_run=$DRY_RUN) ==="

for entry in "${REPOS[@]}"; do
  IFS='|' read -r repo_path default_branch mode <<<"$entry"
  mode=${mode:-commit}
  repo_name=$(basename "$repo_path")
  log "--- $repo_name ---"

  if [[ $mode != commit && $mode != sync ]]; then
    log "ERROR: $repo_name — unknown mode '$mode' (expected commit or sync); skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Pre-flight: repo exists. Its .git is a directory, or a file naming the git
  # directory, as `git clone --separate-git-dir` leaves it.
  if [[ ! -e "$repo_path/.git" ]] \
    || ! git_dir=$(git -C "$repo_path" rev-parse --absolute-git-dir 2>/dev/null); then
    log "SKIP: $repo_name — not a git repo"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Pre-flight: on default branch
  current_branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "$current_branch" != "$default_branch" ]]; then
    log "SKIP: $repo_name — on branch '$current_branch', not '$default_branch'"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Pre-flight: no lock file
  if [[ -f "$git_dir/index.lock" ]]; then
    log "SKIP: $repo_name — index.lock exists (another process has the repo)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Sync local branch to origin BEFORE detecting changes. On a shared clone that
  # concurrent agents push to via their own worktrees, already-pushed content shows
  # up here as phantom working-tree changes and the local branch silently falls
  # behind. Fast-forward first so the sweep below only ever sees genuinely
  # uncommitted leftovers, never a re-commit (or stale re-commit) of upstream
  # content. --ff-only refuses to merge or clobber if the branch has diverged.
  # In commit mode --autostash carries in-flight edits across the fast-forward.
  # Sync mode never stashes: a conflicting re-apply would write conflict markers
  # into another session's draft, and a plain fast-forward instead refuses,
  # writing nothing, when origin changed a path that holds a local change.
  ff_flags=(--ff-only)
  [[ $mode == sync ]] || ff_flags+=(--autostash)
  if ! git -C "$repo_path" fetch --quiet origin "$default_branch" 2>>"$LOG_FILE"; then
    log "  WARNING: $repo_name — fetch failed; proceeding without sync"
  elif $DRY_RUN; then
    behind=$(git -C "$repo_path" rev-list --count "HEAD..origin/$default_branch" 2>/dev/null || echo '?')
    log "DRY-RUN: $repo_name — would fast-forward ($behind behind origin/$default_branch)"
  elif ! git -C "$repo_path" merge "${ff_flags[@]}" "origin/$default_branch" 2>>"$LOG_FILE"; then
    log "WARNING: $repo_name — ff-only to origin/$default_branch refused (diverged, or a local change is in the way); skipping, needs manual reconcile"
    FAILED=$((FAILED + 1))
    [[ $mode != sync ]] || log_strays "$repo_path" "$repo_name"
    continue
  fi

  if [[ $mode == sync ]]; then
    log_strays "$repo_path" "$repo_name"
    SYNCED=$((SYNCED + 1))
    continue
  fi

  # Check for changes (unstaged, staged, or untracked)
  if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet \
    && [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
    log "SKIP: $repo_name — no changes"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  changes=$(git -C "$repo_path" status --porcelain | wc -l)
  log "  $changes file(s) changed"

  if $DRY_RUN; then
    log "DRY-RUN: $repo_name — would commit and push ($changes files)"
    COMMITTED=$((COMMITTED + 1))
    continue
  fi

  # --- Commit via claude -p (primary) or fallback ---
  CLAUDE_SUCCESS=false

  if command -v claude >/dev/null 2>&1; then
    PROMPT="You are running a nightly autocommit for the $repo_name repo.

## Your job

1. Run git status and git diff to understand what changed
2. Stage and commit the changes
3. After committing, do NOT push (the caller handles push)
4. Stage ALL changes. Do not leave anything unstaged or untracked.

## Commit message rules (from Conventional Commits specification)

Structure: <type>[optional scope]: <description>

Types: feat (new feature), fix (bug fix), docs (documentation), style (formatting),
refactor (code change, no new feature/fix), perf (performance), test (tests),
build (build system), ci (CI config), chore (maintenance).

Scope: optional context in parens, e.g. feat(parser): add array support

## Single Responsibility Principle

Each commit should do ONE thing. If changes are logically separable:
- Separate feature additions from refactors
- Separate documentation updates from code changes
- Separate formatting/style from functional changes

When splitting: stage files selectively with git add <files>, commit, then stage
the next group. Use git add -p <file> if a single file has unrelated changes.

## Quality bar

- NEVER use generic messages like 'chore: nightly autocommit' or 'chore: update files'
- Read the actual diff content to understand WHAT changed and WHY
- Name the specific thing: 'docs(tailscale): rewrite setup guide with CLI examples'
  not 'docs: update documentation'
- If multiple skills/modules changed independently, make separate commits for each"

    log "  Running claude -p for staging and commit..."
    # claude has no flag naming its project: the directory it starts in sets the
    # Bash tool's cwd and which CLAUDE.md and project settings load.
    if (cd "$repo_path" && exec timeout "$CLAUDE_TIMEOUT" claude -p "$PROMPT" \
      --allowedTools "Bash(git *)" \
      --verbose) 2>>"$LOG_FILE" >>"$LOG_FILE"; then
      # Verify claude actually committed (check if working tree is clean)
      if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet \
        && [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
        CLAUDE_SUCCESS=true
        # Log what claude committed
        latest_commits=$(git -C "$repo_path" log --oneline -5 --since="5 minutes ago" 2>/dev/null || true)
        if [[ -n "$latest_commits" ]]; then
          log "  Claude committed:"
          while IFS= read -r line; do
            log "    $line"
          done <<<"$latest_commits"
        fi
      else
        log "  WARNING: claude ran but left uncommitted changes — falling back"
      fi
    else
      log "  WARNING: claude -p failed or timed out — falling back"
    fi
  fi

  # Fallback: git add -A + generic message
  if ! $CLAUDE_SUCCESS; then
    log "  Using fallback: git add -A + generic message"
    git -C "$repo_path" add -A
    FALLBACK_MSG="chore($repo_name): nightly autocommit $(date +%Y-%m-%d)"
    if ! git -C "$repo_path" commit -m "$FALLBACK_MSG" 2>>"$LOG_FILE"; then
      log "ERROR: $repo_name — commit failed"
      FAILED=$((FAILED + 1))
      continue
    fi
    log "  Committed (fallback): $FALLBACK_MSG"
  fi

  # Push; if origin advanced during the run, rebase our new commit(s) on top and
  # retry once so a commit can never strand behind origin.
  if ! git -C "$repo_path" push 2>>"$LOG_FILE"; then
    log "  push rejected — fetching and rebasing onto origin/$default_branch to retry"
    if git -C "$repo_path" fetch --quiet origin "$default_branch" 2>>"$LOG_FILE" \
      && git -C "$repo_path" rebase "origin/$default_branch" 2>>"$LOG_FILE" \
      && git -C "$repo_path" push 2>>"$LOG_FILE"; then
      :
    else
      git -C "$repo_path" rebase --abort 2>/dev/null || true
      log "WARNING: $repo_name — push failed after rebase (resolve manually)"
      FAILED=$((FAILED + 1))
      continue
    fi
  fi
  log "  Pushed to origin/$default_branch"

  COMMITTED=$((COMMITTED + 1))
done

log "=== Summary: committed=$COMMITTED skipped=$SKIPPED failed=$FAILED synced=$SYNCED ==="
