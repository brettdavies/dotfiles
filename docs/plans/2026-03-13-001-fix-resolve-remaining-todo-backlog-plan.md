---
title: "fix: Resolve remaining todo backlog (014, 015, 017, 018, 020)"
type: fix
status: completed
date: 2026-03-13
deepened: 2026-03-13
---

# Resolve Remaining Todo Backlog

Batch fix for the 5 remaining todo items. All are small, independent changes
that can be implemented in a single pass.

## Enhancement Summary

**Deepened on:** 2026-03-13
**Research agents used:** learnings-researcher, codebase explorer (2x)

### Key Improvements

1. Task 2 scope expanded — `stow/gh/dot-local/bin/gh` also has inconsistent
   error casing
2. Task 3 refined — plan status already `completed`; exact stale line numbers
   identified
3. Task 4 implementation precise — exact insertion point (line 201), `df -Pk`
   confirmed cross-platform
4. Task 5 nearly done — comment already exists at lines 181-185; only minor
   update needed

## Task 1: Add markdownlint-cli2 to Brewfile (todo 014)

`auto-format.sh` invokes `markdownlint-cli2` directly (line 76) but it's not
in the Brewfile. Fresh machines won't have it.

**Fix:** Add `brew "markdownlint-cli2"` to `stow/brew/Brewfile`.

**Placement:** In the "Code quality & utilities" section (after `yq`, before
the macOS-only comment). Not in `Brewfile.optional` — it's required by the
auto-format hook, not optional.

**Files:** `stow/brew/Brewfile`

### Research Insights

- `markdownlint-cli2` is available via Homebrew on both macOS and Linux — no
  `if OS.mac?` guard needed.
- The Brewfile is organized into sections: oh-my-zsh, development tools, code
  quality & utilities, macOS-only utilities, macOS-only casks, VS Code
  extensions.

## Task 2: Standardize error message convention (todo 015)

`scripts/stow-deploy` uses UPPERCASE prefixes (`ERROR:`, `WARNING:`, `FATAL:`,
`NOTE:`). Other scripts use inconsistent casing.

**Convention:** `ERROR:`, `WARNING:`, `NOTE:`, `FATAL:` — all uppercase,
followed by a space and the message. Output to stderr via `>&2`.

**Files to update:**

| File | Line(s) | Current | Change to |
|------|---------|---------|-----------|
| `.githooks/pre-commit` | 11 | `error:` | `ERROR:` |
| `.githooks/pre-commit` | 20 | `error:` | `ERROR:` |
| `stow/gh/dot-local/bin/gh` | 13 | `Error:` | `ERROR:` |

**Also update:** `CLAUDE.md` — add error message convention under a "Shell
Script Conventions" heading.

**Files verified as clean (no changes needed):**

- `.githooks/post-checkout` — no error messages
- `.githooks/post-merge` — no error messages
- `.githooks/pre-push` — no error messages
- `scripts/sync/sync_dev_to_icloud.sh` — informational echo only
- `stow/local/dot-local/bin/op-ssh-sign-wrapper` — uses descriptive format
  without prefix (`op-ssh-sign-wrapper: ...`), which is acceptable for a binary
  wrapper identifying itself

### Research Insights

- UPPERCASE severity prefixes match the GNU/POSIX convention used by `make`,
  `gcc`, and other standard tools.
- The `op-ssh-sign-wrapper` uses `programname: message` format (common for
  Unix utilities like `ssh`, `gpg`). This is a different convention
  (self-identifying binary) and doesn't need to match the severity prefix
  convention.
- See `docs/solutions/deployment-issues/cross-platform-shell-idiom-and-config-hardening.md`
  for related shell script conventions.

## Task 3: Clean stale acceptance criteria in plan (todo 017)

The plan file
`docs/plans/2026-02-18-feat-stow-deploy-platform-defaults-tree-fold-fix-plan.md`
has stale references to features removed during deepening. The work is already
implemented and the plan status is already `completed`.

**Stale references to remove or update:**

| Line(s) | Content | Action |
|---------|---------|--------|
| 253, 256 | `fuser` process detection discussion | Remove or mark as historical |
| 418-419 | Acceptance criteria rows for fuser and .stow-migrate | Remove rows |
| 431 | `fuser detection removed` in trade-offs | Keep (documents decision) |
| 550 (Q4) | `mktemp -d` recovery infra | Keep (documents decision) |
| 552 (Q6) | Process detection removal | Keep (documents decision) |

**Files:**
`docs/plans/2026-02-18-feat-stow-deploy-platform-defaults-tree-fold-fix-plan.md`

### Research Insights

- The Q4 and Q6 spec-flow entries actually document **decisions that were
  made** (removed features and why), not stale requirements. They should stay
  as historical context.
- The acceptance criteria table rows at lines 418-419 are the primary stale
  content — they list features that don't exist in the implementation.
- Plan status is already `completed` in frontmatter — no change needed there.

## Task 4: Add disk space pre-check (todo 018)

`resolve_tree_fold()` copies directory contents during tree-fold resolution. On
a nearly-full disk, this can fail mid-copy and leave a broken state. No `df`
guard exists.

**Fix:** Add a `check_disk_space` function to stow-deploy and call it before
the tree-fold resolution loop.

**Implementation:**

```bash
check_disk_space() {
  local min_mb=512
  local avail_kb
  avail_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
  local avail_mb=$(( avail_kb / 1024 ))
  if [ "$avail_mb" -lt "$min_mb" ]; then
    echo "FATAL: Insufficient disk space for tree-fold resolution." >&2
    echo "  Available: ${avail_mb} MB, required: ${min_mb} MB minimum." >&2
    echo "  Free disk space and retry." >&2
    exit "$EXIT_PRECONDITION"
  fi
}
```

**Insertion point:** Define the function after `resolve_tree_fold()` (after
line 199). Call it at line 201, before `tree_fold_found=false` and the
tree-fold detection loop.

**Files:** `scripts/stow-deploy`

### Research Insights

- `df -Pk` is confirmed cross-platform (macOS + Linux). `-P` forces POSIX
  output format; `-k` outputs in 1024-byte blocks.
- `EXIT_PRECONDITION=4` is already defined at line 16 of stow-deploy —
  matches the "pre-flight check failed" semantics.
- 512 MB minimum = 3.3x buffer over the ~155 MB actual need. Conservative
  but appropriate for a safety check.
- Single upfront check (not per-package) is correct — one `df` call, fast
  failure before any tree-fold work begins.
- See `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md`
  for stow-deploy architecture context.

## Task 5: Document git clean -ffdx decision (todo 020)

The code uses `git clean -ffdx` after tree-fold resolution. A comment already
exists at lines 181-185 explaining the rationale:

```bash
# 6. Clean untracked files from the stow package dir
#    Tracked files are intact (cp, not mv). Use -fdx to also remove gitignored
#    files — .gitignore patterns (e.g. /stow/claude/dot-claude/**/*) were
#    defense-in-depth for the tree-fold scenario and block -fd from cleaning.
#    Double -f removes nested git repos (e.g. claude plugins/marketplaces)
```

**Assessment:** The decision is already documented in code. The `.gitignore`
defense-in-depth pattern referenced in the comment has since been removed,
making the comment slightly stale.

**Fix:** Update the comment to reflect current state — the `.gitignore` pattern
no longer exists, so the `-x` flag explanation should note this is now a
no-op but retained for correctness.

**Files:** `scripts/stow-deploy`

## Acceptance Criteria

- [x] `markdownlint-cli2` listed in Brewfile (Code quality section)
- [x] Error messages in `.githooks/pre-commit` use UPPERCASE convention
- [x] Error message in `stow/gh/dot-local/bin/gh` uses UPPERCASE convention
- [x] Error message convention documented in CLAUDE.md
- [x] Stale acceptance criteria rows removed from plan file (lines 418-419)
- [x] `check_disk_space` function added to stow-deploy (before tree-fold loop)
- [x] `git clean` comment updated to reflect current `.gitignore` state
- [x] All 5 todo files deleted after implementation

## Sources

- `stow/claude/dot-claude/auto-format.sh:76` — markdownlint-cli2 invocation
- `stow/brew/Brewfile:22-32` — Code quality section placement
- `scripts/stow-deploy:16` — EXIT_PRECONDITION definition
- `scripts/stow-deploy:181-191` — git clean invocation and existing comment
- `scripts/stow-deploy:201-223` — tree-fold detection loop
- `.githooks/pre-commit:11,20` — lowercase error messages
- `stow/gh/dot-local/bin/gh:13` — mixed-case error message
- `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md`
- `docs/solutions/deployment-issues/cross-platform-shell-idiom-and-config-hardening.md`
