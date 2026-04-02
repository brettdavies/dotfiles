#!/usr/bin/env bash
set -euo pipefail

# Nightly autocommit: commit and push pending changes in selected repos.
# Runs via systemd timer at 23:45 CT. Uses claude -p for commit messages
# with fallback to generic messages on failure.
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

    # Check for changes
    if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet && \
       [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
        log "SKIP: $repo_name — no changes"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if $DRY_RUN; then
        log "DRY-RUN: $repo_name — would commit and push"
        changes=$(git -C "$repo_path" status --porcelain | wc -l)
        log "  $changes file(s) changed"
        COMMITTED=$((COMMITTED + 1))
        continue
    fi

    # Stage all changes
    git -C "$repo_path" add -A

    # Generate commit message via claude -p (with timeout and fallback)
    FALLBACK_MSG="chore: nightly autocommit $(date +%Y-%m-%d)"
    COMMIT_MSG=""

    if command -v claude >/dev/null 2>&1; then
        DIFF_STAT=$(git -C "$repo_path" diff --cached --stat 2>/dev/null | tail -1)
        DIFF_NAMES=$(git -C "$repo_path" diff --cached --name-only 2>/dev/null | head -20)
        PROMPT="You are generating a git commit message. Here is the staged diff summary:

$DIFF_STAT

Files changed:
$DIFF_NAMES

Write a single conventional commit message (type(scope): description). Be concise — one line, no body. If the changes span multiple concerns, pick the dominant one. Use 'chore' for mixed/housekeeping changes."

        COMMIT_MSG=$(timeout 30 claude -p "$PROMPT" --allowedTools "" 2>/dev/null || true)
    fi

    # Validate commit message (non-empty, single line, reasonable length)
    if [[ -z "$COMMIT_MSG" ]] || [[ $(echo "$COMMIT_MSG" | wc -l) -gt 3 ]] || [[ ${#COMMIT_MSG} -gt 200 ]]; then
        COMMIT_MSG="$FALLBACK_MSG"
        log "  Using fallback message (claude unavailable or produced bad output)"
    fi

    # Commit
    if ! git -C "$repo_path" commit -m "$COMMIT_MSG" 2>>"$LOG_FILE"; then
        log "ERROR: $repo_name — commit failed"
        FAILED=$((FAILED + 1))
        continue
    fi
    log "  Committed: $COMMIT_MSG"

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
