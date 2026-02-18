---
title: "Reconcile diverged main/development branches and enforce PR workflow"
category: configuration-fixes
tags: [git-workflow, branch-management, github-ruleset, merge-conflict-resolution, branch-protection]
module: git/github
symptom: "main and development branches diverged with 10 and 14 unique commits respectively; work committed directly to both without merging; GitHub default branch pointed to development while deployments used main"
root_cause: "No branch protection rules, no enforced workflow, and direct pushes to both branches without PR discipline"
date: 2026-02-15
---

# Reconcile diverged main/development branches and enforce PR workflow

## Problem Symptom

After deploying dotfiles to a second machine, post-deployment fixes went directly to `main` while earlier feature work had gone to `development`. The branches diverged with 24 combined unique commits (10 on main, 14 on development) since merge-base `09f26e6`. Critical shell config files had incompatible versions on each branch.

## Root Cause

No branch protection existed. GitHub's default branch was `development`, but actual deployment work went directly to `main`. Without rulesets or PR requirements, direct pushes to both branches were unimpeded, causing parallel divergence.

## Solution

### Phase 1: Reconcile branches

```bash
# Merge main into development
git checkout development
git merge main --no-edit
# 5 conflicts: dot-bashrc, dot-profile, dot-secrets, dot-ssh/config, dot-zshrc

# Resolve all conflicts by taking main's tested versions
git checkout main -- stow/bash/dot-bashrc stow/secrets/dot-secrets \
  stow/shell/dot-profile stow/ssh/dot-ssh/config stow/zsh/dot-zshrc
git add <files>
git commit

# Fast-forward main to development
git checkout main
git merge development --ff-only
git push origin main development
```

Main's versions won because they were the deployment-tested versions with critical fixes (Homebrew PATH before secrets, interactive guards, op inject, zshenv for non-interactive zsh).

### Phase 2: GitHub configuration

```bash
# Change default branch to main
gh api repos/OWNER/REPO -X PATCH -f default_branch=main

# Create ruleset requiring PRs for main (no direct pushes)
gh api repos/OWNER/REPO/rulesets -X POST --input - <<'EOF'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [{"type": "pull_request", "parameters": {"required_approving_review_count": 0}}]
}
EOF
```

### Phase 3: Documentation

Updated CLAUDE.md with branch workflow:

- `main` = stable, protected, merge via PR only
- `development` = integration branch
- Feature branches = created from development, merged back via PR

## Key Insights

### 1. GitHub rulesets are free for public repos

Repository rulesets (not legacy branch protection) are available on the free plan for public repos. They support PR requirements, linear history enforcement, and bypass controls via the API.

### 2. Conflict resolution strategy: take the deployed version

When branches diverge and one has been deployed and tested, always take the deployed version for conflicts. The other branch's changes are likely stale or untested.

### 3. Fast-forward after merge eliminates divergence

After merging main into development (creating a merge commit on development), fast-forwarding main to development makes both branches point to the same commit. This is cleaner than merging in both directions.

### 4. Default branch should match the stable branch

GitHub's default branch determines what contributors see first and what PRs target. It should be the stable branch (main), not the integration branch (development).

## Prevention Strategies

### 1. Never commit directly to main

The GitHub ruleset now enforces this. All changes must go through PRs.

### 2. Feature branch workflow

```text
feature/my-change → PR → development → PR → main
```

### 3. Merge back after deployment

After deploying from main, immediately check if development needs to be updated. Catch divergence early before it compounds.

### 4. Document the workflow

The CLAUDE.md branch workflow section is the canonical reference. New contributors (human or AI) read this before making changes.

## Cross-References

- Plan: `docs/plans/2026-02-15-refactor-reconcile-branches-enforce-workflow-plan.md`
- Related: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Related: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- GitHub ruleset: `https://github.com/brettdavies/dotfiles/rules/12849367`
