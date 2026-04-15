#!/usr/bin/env bash
set -euo pipefail

# Nightly autocommit: commit and push pending changes in selected repos.
# Runs via systemd timer between 2-4 AM CT. Delegates staging and commit
# message generation to claude -p, which follows the project's Conventional
# Commits template and applies SRP (multiple commits when appropriate).
#
# Falls back to git add -A + generic message only if claude is unavailable.
#
# Usage: nightly-autocommit.sh [--dry-run]

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

LOG_DIR="$HOME/.local/share/nightly-autocommit"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nightly-autocommit.log"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" | tee -a "$LOG_FILE"; }

# --- Repo Configuration ---
# Each entry: path|default_branch
REPOS=(
    "$HOME/obsidian-vault|main"
    "$HOME/dev/solutions-docs|main"
    "$HOME/dev/agent-skills|main"
)

# Claude timeout: 2 minutes per repo (enough time to read diffs, split commits, write messages)
CLAUDE_TIMEOUT=120

COMMITTED=0
SKIPPED=0
FAILED=0

log "=== Nightly autocommit started (dry_run=$DRY_RUN) ==="

for entry in "${REPOS[@]}"; do
    IFS='|' read -r repo_path default_branch <<< "$entry"
    repo_name=$(basename "$repo_path")
    log "--- $repo_name ---"

    # Pre-flight: repo exists
    if [[ ! -d "$repo_path/.git" ]]; then
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
    if [[ -f "$repo_path/.git/index.lock" ]]; then
        log "SKIP: $repo_name — index.lock exists (another process has the repo)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Pre-flight: git-crypt check (for obsidian-vault)
    if [[ "$repo_name" == "obsidian-vault" ]]; then
        if git -C "$repo_path" crypt status -e 2>/dev/null | head -1 | grep -q "encrypted:"; then
            log "SKIP: $repo_name — git-crypt is locked"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # Check for changes (unstaged, staged, or untracked)
    if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet && \
       [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
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
        if timeout "$CLAUDE_TIMEOUT" claude -p "$PROMPT" \
            --allowedTools "Bash(git *)" \
            -d "$repo_path" \
            --verbose 2>>"$LOG_FILE" >>"$LOG_FILE"; then
            # Verify claude actually committed (check if working tree is clean)
            if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet && \
               [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
                CLAUDE_SUCCESS=true
                # Log what claude committed
                latest_commits=$(git -C "$repo_path" log --oneline -5 --since="5 minutes ago" 2>/dev/null || true)
                if [[ -n "$latest_commits" ]]; then
                    log "  Claude committed:"
                    while IFS= read -r line; do
                        log "    $line"
                    done <<< "$latest_commits"
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

    # Push (no pull/rebase — just push, log failure)
    if ! git -C "$repo_path" push 2>>"$LOG_FILE"; then
        log "WARNING: $repo_name — push failed (resolve manually)"
        FAILED=$((FAILED + 1))
        continue
    fi
    log "  Pushed to origin/$default_branch"

    COMMITTED=$((COMMITTED + 1))
done

log "=== Summary: committed=$COMMITTED skipped=$SKIPPED failed=$FAILED ==="
