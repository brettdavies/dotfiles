---
title: Todo backlog resolution and convention enforcement
category: configuration-fixes
date: 2026-03-13
tags: [brewfile, error-convention, shell-scripts, disk-space, stow-deploy, git-clean, todo-hygiene]
module: scripts, hooks, brew
symptom: 18 accumulated todo items, inconsistent error message casing, missing Brewfile dependency, no disk space guard
root_cause: Organic growth without periodic review; conventions not documented
---

# Todo Backlog Resolution and Convention Enforcement

## Problem

Over several months of development, 18 todo items accumulated in `todos/`.
Many referenced work that had already been implemented. The remaining 5
contained real gaps: a missing Brewfile dependency, inconsistent error message
casing, stale plan documentation, no disk space safety check, and an
undocumented security decision.

## Root Cause

- No periodic todo review cadence — items were created during code reviews but
  never revisited
- Shell script conventions (error message format) were never documented,
  allowing drift between scripts written at different times
- Bootstrap dependencies added via `brew install` on the dev machine were never
  added to the Brewfile

## Solution

### 1. Bulk triage (18 → 5 todos)

Reviewed each todo against the current codebase. 13 were already implemented
(exit codes, platform guards, naming conventions, error handling, tree-fold
patterns). Deleted all 13.

### 2. Brewfile gap (`markdownlint-cli2`)

`auto-format.sh` invokes `markdownlint-cli2` directly but it wasn't in the
Brewfile. Added to the "Code quality & utilities" section.

### 3. Error message convention

Standardized on UPPERCASE severity prefixes (`ERROR:`, `WARNING:`, `FATAL:`,
`NOTE:`) matching GNU/POSIX conventions. Updated `.githooks/pre-commit` and
`stow/gh/dot-local/bin/gh`. Documented the convention in CLAUDE.md under
"Shell Script Conventions".

Binary wrappers (e.g., `op-ssh-sign-wrapper`) use `programname: message`
format instead — the standard Unix self-identifying convention.

### 4. Disk space pre-check

Added `check_disk_space()` to `scripts/stow-deploy` before the tree-fold
resolution loop. Requires 512 MB free (3.3x buffer over ~155 MB actual need).
Uses `df -Pk` for cross-platform compatibility (macOS + Linux).

### 5. Git clean flag documentation

Updated the existing comment at the `git clean -ffdx` call site to reflect
that the `.gitignore` defense-in-depth pattern was removed. The `-x` flag is
retained because stow dirs should only contain tracked files after
un-tree-folding.

## Prevention

- **Review todos when touching related code.** If a todo references a file
  you're editing, check if it's already resolved.
- **Document conventions when establishing them.** The error message convention
  existed implicitly in `stow-deploy` but wasn't written down, causing drift
  in hooks written later.
- **Add CLI tool dependencies to Brewfile immediately.** Don't rely on
  `brew install` on the dev machine — if a script calls it, it belongs in
  the Brewfile.
- **Periodic todo triage.** Batch-review accumulated todos quarterly or when
  the count exceeds 10.

## Related

- [stow-conflict-resolution-wrapper.md](../deployment-issues/stow-conflict-resolution-wrapper.md) —
  stow-deploy architecture context
- [cross-platform-shell-idiom-and-config-hardening.md][idiom-hardening] —
  shell script conventions

[idiom-hardening]: ../deployment-issues/cross-platform-shell-idiom-and-config-hardening.md

- Plan: `docs/plans/2026-03-13-001-fix-resolve-remaining-todo-backlog-plan.md`
