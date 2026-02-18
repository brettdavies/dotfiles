---
title: Consolidate repo-local enforcement (hooks, rulesets, config)
type: refactor
status: completed
date: 2026-02-16
---

# Consolidate repo-local enforcement (hooks, rulesets, config)

## Overview

Consolidate all repo-enforcement mechanisms so they are clearly repo-local: git hooks in `.githooks/`, GitHub platform config in `.github/`, nothing stowed or symlinked as global defaults. Fix loose ends from previous sessions (stale comments, uncommitted files, broken LFS hooks).

## Problem Statement

The current state works but has organizational issues:

1. **Hooks in `scripts/git-hooks/`** -- non-standard location. The de facto convention is `.githooks/`. The `scripts/` directory previously held a large library system that was removed; keeping `scripts/git-hooks/` as the sole remaining content is vestigial.
2. **Pre-commit has a stale comment** -- line 5 says `# Install: cp scripts/git-hooks/pre-commit .git/hooks/pre-commit` but the repo uses `core.hooksPath`, not manual copying.
3. **Uncommitted files** -- `.github/rulesets/`, `scripts/git-hooks/pre-commit`, `CLAUDE.md`, and a plan doc are all modified/untracked on `development`.
4. **Git LFS hooks broken** -- `core.hooksPath` overrides `.git/hooks/` where LFS hooks live. The repo-local hooks don't chain-call LFS, so LFS file tracking silently fails.
5. **No deployment automation for `core.hooksPath`** -- it's set in `.git/config` (not tracked), and the old install scripts were removed. New clones won't have hooks active unless they know to run `git config core.hooksPath .githooks`.

## Proposed Solution

### 1. Move hooks from `scripts/git-hooks/` to `.githooks/`

**Why `.githooks/` instead of `scripts/git-hooks/`:** The `.github/` directory is reserved by GitHub for platform configuration (Actions workflows, issue templates, rulesets, CODEOWNERS, FUNDING.yml). Git hooks are local git client behavior, not GitHub platform config. `.githooks/` is the de facto community standard (recommended by Atlassian, githooks.com, and git documentation examples).

**Steps:**

- Move `scripts/git-hooks/pre-commit` → `.githooks/pre-commit`
- Move `scripts/git-hooks/post-checkout` → `.githooks/post-checkout`
- Move `scripts/git-hooks/post-merge` → `.githooks/post-merge`
- Remove empty `scripts/git-hooks/` (and `scripts/` if nothing else remains)
- Remove the stale install comment from pre-commit (line 5: `# Install: cp scripts/git-hooks/pre-commit .git/hooks/pre-commit`)

**Update `core.hooksPath`:** After moving, run `git config core.hooksPath .githooks` to point at the new location.

### 2. Fix LFS hook chaining

When `core.hooksPath` is set, git ignores `.git/hooks/` entirely -- including the LFS hooks that `git lfs install` places there. The fix is to chain-call LFS from the custom hooks using the guard pattern from `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`.

**Hooks that need LFS chaining:**

| Hook | LFS chain call |
|------|---------------|
| `post-checkout` | `command -v git-lfs >/dev/null 2>&1 && git lfs post-checkout "$@"` |
| `post-merge` | `command -v git-lfs >/dev/null 2>&1 && git lfs post-merge "$@"` |
| `pre-push` (new) | `command -v git-lfs >/dev/null 2>&1 && git lfs pre-push "$@"` |

**Note:** `pre-commit` does NOT need LFS chaining -- LFS uses `pre-push`, not `pre-commit`.

**Target `.githooks/post-checkout`:**

```bash
#!/bin/bash
# Auto-unlock git-crypt if key is available
if command -v git-crypt >/dev/null 2>&1; then
    if [ -f ~/.config/git-crypt/key ]; then
        if git-crypt status 2>/dev/null | grep -q "not unlocked"; then
            git-crypt unlock ~/.config/git-crypt/key 2>/dev/null || true
        fi
    fi
fi

# Chain Git LFS hook (core.hooksPath overrides .git/hooks/)
command -v git-lfs >/dev/null 2>&1 && git lfs post-checkout "$@"
```

**Target `.githooks/post-merge`:**

```bash
#!/bin/bash
# Auto-unlock git-crypt if key is available
if command -v git-crypt >/dev/null 2>&1; then
    if [ -f ~/.config/git-crypt/key ]; then
        if git-crypt status 2>/dev/null | grep -q "not unlocked"; then
            git-crypt unlock ~/.config/git-crypt/key 2>/dev/null || true
        fi
    fi
fi

# Chain Git LFS hook (core.hooksPath overrides .git/hooks/)
command -v git-lfs >/dev/null 2>&1 && git lfs post-merge "$@"
```

**Target `.githooks/pre-push` (new file):**

```bash
#!/usr/bin/env bash
# Chain Git LFS pre-push hook (core.hooksPath overrides .git/hooks/)
command -v git-lfs >/dev/null 2>&1 && git lfs pre-push "$@"
```

**Target `.githooks/pre-commit` (cleaned up):**

```bash
#!/usr/bin/env bash
# Pre-commit hook: block direct commits to protected branches
# and verify commit signing is enabled.

set -euo pipefail

branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)

# Block direct commits to main
if [ "$branch" = "main" ]; then
    echo "error: direct commits to 'main' are blocked." >&2
    echo "       Create a feature branch and submit a PR instead." >&2
    echo "       git checkout -b feat/your-feature development" >&2
    exit 1
fi

# Verify commit signing is enabled
gpgsign=$(git config --get commit.gpgsign 2>/dev/null || true)
if [ "$gpgsign" != "true" ]; then
    echo "error: commit signing is not enabled (commit.gpgsign != true)." >&2
    echo "       Run: git config commit.gpgsign true" >&2
    exit 1
fi
```

### 3. Add `core.hooksPath` setup to bootstrap

Add both a README step and a scriptable setup command:

**README bootstrap guide** -- add after the "Clone and unlock" step:

```bash
git config core.hooksPath .githooks
```

**`.githooks/setup` script** -- for dotfiles-cli integration:

```bash
#!/usr/bin/env bash
# Configure core.hooksPath to use repo-local hooks
git config core.hooksPath "$(dirname "$0")"
```

Run with: `bash .githooks/setup` after cloning.

### 4. Keep `.github/` for GitHub platform config only

The `.github/` directory contains only GitHub-specific configuration:

- `.github/rulesets/protect-main.json` -- documentation export of the main branch ruleset
- `.github/rulesets/protect-development.json` -- documentation export of the development branch ruleset
- Future: `.github/workflows/` if CI/CD is needed
- Future: `.github/CODEOWNERS`, PR templates, issue templates

### 5. Update references

All references to `scripts/git-hooks/` must be updated to `.githooks/`:

- `CLAUDE.md`: Git Hooks section (path, `core.hooksPath` command, hook table)
- `README.md`: "Secrets Management" section, "Repository Layout" section, bootstrap guide
- `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`: any path references
- `docs/solutions/configuration-fixes/branch-divergence-reconciliation-and-workflow-enforcement.md`: any path references

### 6. Clean up `scripts/` directory

After moving hooks, check if `scripts/` has remaining content:

- If `scripts/sync/` or other subdirectories exist, keep `scripts/`
- If `scripts/` is empty, remove it
- Update README "Repository Layout" accordingly

## Acceptance Criteria

- [x] Git hooks live in `.githooks/` (pre-commit, post-checkout, post-merge, pre-push)
- [x] `core.hooksPath` points to `.githooks` in repo-local config
- [x] Pre-commit blocks commits on `main` (verified)
- [x] Pre-commit passes on `development` and feature branches (verified)
- [x] Post-checkout and post-merge auto-unlock git-crypt (unchanged behavior)
- [x] LFS hooks chain-called from post-checkout, post-merge, and pre-push when `git-lfs` is available
- [x] New `pre-push` hook exists for LFS
- [x] No stale comments or paths referencing `scripts/git-hooks/`
- [x] `.github/` contains only GitHub platform config (rulesets)
- [x] README bootstrap guide includes `core.hooksPath .githooks` setup step
- [x] `.githooks/setup` script exists for automated bootstrap
- [x] CLAUDE.md references updated to `.githooks/`
- [x] Solution docs references updated to `.githooks/` (no references found -- no changes needed)
- [ ] All uncommitted changes on `development` are committed
- [x] No hooks, rulesets, or GitHub config is stowed or symlinked globally

## Files changed

| Action | File | Notes |
|--------|------|-------|
| Move | `scripts/git-hooks/pre-commit` → `.githooks/pre-commit` | Remove stale install comment |
| Move | `scripts/git-hooks/post-checkout` → `.githooks/post-checkout` | Add LFS chain call |
| Move | `scripts/git-hooks/post-merge` → `.githooks/post-merge` | Add LFS chain call |
| Create | `.githooks/pre-push` | LFS-only hook |
| Create | `.githooks/setup` | Bootstrap script for `core.hooksPath` |
| Delete | `scripts/git-hooks/` | Empty after move (and `scripts/` if empty) |
| Edit | `CLAUDE.md` | Update hook paths |
| Edit | `README.md` | Update layout, secrets section, add bootstrap step |
| Edit | `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md` | Update path references |
| Edit | `docs/solutions/configuration-fixes/branch-divergence-reconciliation-and-workflow-enforcement.md` | Update path references |

## References

- Git hooks convention: Atlassian, githooks.com, git docs recommend `.githooks/`
- Hook guard pattern: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Branch workflow: `docs/solutions/configuration-fixes/branch-divergence-reconciliation-and-workflow-enforcement.md`
- LFS hooks documentation: `git lfs install --manual` shows which hooks LFS requires
