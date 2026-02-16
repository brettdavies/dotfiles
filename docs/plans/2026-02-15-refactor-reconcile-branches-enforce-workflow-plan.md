---
title: "refactor: Reconcile main/development branches and enforce git workflow"
type: refactor
status: completed
date: 2026-02-15
---

# refactor: Reconcile main/development branches and enforce git workflow

## Overview

`main` and `development` have diverged with 10 and 14 unique commits respectively since merge-base `09f26e6`. Main has all the post-deployment fixes (shell config, secrets, op inject) that development is missing. Development has some earlier work (cross-platform stow solution doc, Antigravity CLI, shell helper refactors) that main is missing. Both need to be reconciled, then a workflow enforced going forward.

## Problem Statement

Work has been committed directly to both `main` and `development` without merging between them. GitHub's default branch is `development`, but recent work (shell config fixes, op inject) went directly to `main`. This creates risk of losing work and confusion about which branch is authoritative.

## Proposed Solution

### Phase 1: Reconcile branches

1. Merge `main` into `development` to bring it up to date
2. Resolve any conflicts (expected in: `dot-bashrc`, `dot-profile`, `dot-secrets`, `dot-zshrc`, `dot-gitconfig`, `dot-ssh/config`)
3. For conflicts, main's versions should win for shell config files since they're the tested/verified versions
4. Verify the merged development branch works (all 9 X_API tokens, shell startup)
5. Fast-forward `main` to match `development`

### Phase 2: Set GitHub default branch

Change GitHub default branch from `development` to `main`. Main should be the stable release branch.

```bash
gh api repos/brettdavies/dotfiles -X PATCH -f default_branch=main
```

### Phase 3: Create GitHub repository ruleset for main

Use GitHub rulesets (available on free plan for public repos) to protect `main`:

```bash
gh api repos/brettdavies/dotfiles/rulesets -X POST --input ruleset.json
```

Rules for `main`:

- Require pull request before merging (no direct pushes)
- Require linear history (squash or rebase merges only)

### Phase 4: Update CLAUDE.md

Update the project CLAUDE.md to document the branch workflow:

- `main` = stable, protected, merge via PR only
- `development` = integration branch for feature work
- Feature branches = created from `development`, merged back via PR

## Files Modified

| File | Change |
|------|--------|
| Multiple stow files | Conflict resolution during merge |
| `CLAUDE.md` | Add branch workflow documentation |

## Implementation Tasks

- [x] Merge `main` into `development`, resolve conflicts
- [x] Verify merged `development` works on macOS and bigdaddy
- [x] Fast-forward `main` to `development`
- [x] Change GitHub default branch to `main`
- [x] Create repository ruleset protecting `main`
- [x] Update CLAUDE.md with branch workflow
- [ ] Update bigdaddy to final state

## Acceptance Criteria

- [x] `main` and `development` point to the same commit
- [x] GitHub default branch is `main`
- [x] Direct push to `main` is blocked by ruleset
- [x] All 9 X_API tokens work on macOS (3 shells) and bigdaddy (2 shells)
- [x] CLAUDE.md documents the branch workflow
