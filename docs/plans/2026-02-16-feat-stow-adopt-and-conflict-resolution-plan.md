---
title: "feat: Stow adopt workflow and conflict resolution"
type: feat
status: active
date: 2026-02-16
---

# Stow Adopt Workflow and Conflict Resolution

## Enhancement Summary

**Deepened on:** 2026-02-16
**Sections enhanced:** 6
**Agents used:** security-sentinel, code-simplicity-reviewer, architecture-strategist, pattern-recognition-specialist, deployment-verification-agent, learnings-researcher (x2), web-search (x2)

**SpecFlow analysis on:** 2026-02-16
**Agents used:** repo-research-analyst, learnings-researcher, spec-flow-analyzer
**Gaps found:** 18 (4 critical, 4 important, 10 nice-to-have)

### Key Improvements (deepening round)

1. Replaced `grep -oP` (GNU-only PCRE) with POSIX-portable `sed` -- script was broken on macOS
2. Added `--headless` mode that auto-restores repo versions after adopt (critical for fleet deployment)
3. Added `-R` (restow) for idempotent re-runs on already-stowed packages
4. Removed auto-discovery of packages (deploying ALL packages to Ubuntu would stow macOS-only packages)
5. Added `command -v stow` guard, stow version warning, and bash 3.2 compatibility

### Key Improvements (SpecFlow round)

1. Added pre-flight checks: `local` package rejection, git-crypt lock detection, dirty working tree guard
2. Added error classification -- non-conflict stow errors fail immediately instead of cascading through conflict resolution
3. Headless mode now uses best-effort (continues on failure, summary at end) instead of fail-fast
4. Added `.profile` resilience fix -- `~/.local/bin/env` sourcing guarded to prevent SSH lockout
5. Adopt failures now handled gracefully instead of crashing the script

### Bugs Found in Original Script

- `grep -oP` fails silently on macOS BSD grep -- symlink conflicts never resolved
- Missing `git checkout` after `--adopt` on headless servers -- contradicts own documented solution
- `while read` in pipeline runs in subshell -- `adopted+=()` never propagates to parent
- `readlink` called before `rm` but logged after -- ordering bug in output
- `${#adopted[@]}` under `set -u` errors on macOS bash 3.2 with empty arrays
- No `-R` flag means script fails on already-stowed packages

---

## Overview

GNU Stow has no force flag and limited conflict resolution. When existing files or symlinks conflict with stow, the user must intervene manually. This plan documents the root causes, available flags, and proposes a `scripts/stow-deploy` wrapper script that handles both conflict types automatically while preserving local changes for review.

## Problem Statement

Three distinct conflict scenarios exist:

### 1. Existing non-stow symlinks (the ghostty problem)

**Root cause:** A symlink was created manually (e.g., `ln -sf /abs/path ~/.config/ghostty/config`) instead of via stow. Stow only owns **relative** symlinks it created. Absolute symlinks are immediately rejected by `find_stowed_path()` in Stow.pm (line 1021-1024):

```perl
if (substr($link_dest, 0, 1) eq '/') {
    # Symlink points to an absolute path, therefore it cannot be
    # owned by Stow.
    return ('', '', '');
}
```

**Available flags:** None. `--override` only resolves conflicts between two stow-owned packages. `--adopt` only handles plain files. There is no `--force` flag.

**Fix:** Remove the symlink, then stow.

### Research Insights

**Known behavior confirmed by Stow source code analysis:**

- Stow's two-phase algorithm scans ALL conflicts before making ANY changes. If any conflict is found, stow terminates without modifying the filesystem. This means our try-fail-fix-retry approach is safe -- a failed `stow` call changes nothing.
- `--override=REGEX` is evaluated ONLY after `find_stowed_path()` confirms the existing link is stow-owned (Stow.pm line 531-602). Non-stow symlinks are rejected at step 2, before `--override` is ever checked.
- GNU Stow maintainer Adam Spiers confirmed on the mailing list that stow will not override non-owned symlinks by design.

### 2. Existing plain files (the adopt scenario)

**Root cause:** A real file exists at the target (e.g., a default config created by an installer). Stow refuses to overwrite it.

**Available flag:** `--adopt` moves the existing file INTO the stow package directory (overwriting the repo version), then creates the symlink.

**Workflow:**

```bash
# Step 1: Adopt — moves target file into package, creates symlink
stow --dotfiles --adopt -t "$HOME" <package>

# Step 2: Review what changed
cd ~/dotfiles && git diff stow/<package>/

# Step 3: Either keep local changes or restore repo version
git checkout -- stow/<package>/   # discard local changes
# OR
git add stow/<package>/           # keep local changes
```

### Research Insights: Adopt Safety

**Best practices from community and existing solutions:**

- Always commit before using `--adopt` to protect against unwanted overwrites. If something goes wrong, `git checkout` restores the repo version instantly because the symlink still points to the same file.
- The pattern `--adopt` then `git checkout` is already documented in our own `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md` (lines 159-169) and was battle-tested during the bigdaddy Ubuntu deployment.
- On headless servers, `--adopt` followed by interactive review is not feasible. The script must auto-restore repo versions in non-interactive contexts.

**Edge case -- `--adopt` security risk:**

- If a compromised or corrupted file exists at the target, `--adopt` silently replaces the known-good repo version. On headless servers running non-interactively, nobody reads the `git diff` output. A single compromised server can inject malicious config into the working tree if the operator blindly runs `git add`.
- Mitigation: headless mode must auto-run `git checkout -- stow/<pkg>/` immediately after adopt.

### 3. Stow tree folding (directory-level symlinks)

**Root cause:** Without `--no-folding`, stow may create a single symlink for an entire directory (e.g., `~/.config/git -> ../../dotfiles/stow/git/dot-config/git`). If another tool later writes into that directory, it writes into the stow package source, polluting the repo.

**Available flag:** `--no-folding` prevents this by creating individual file symlinks instead of directory symlinks.

### Research Insights: Tree Folding

**Known bug:** `--dotfiles` and tree folding [don't cooperate](https://lists.gnu.org/archive/html/bug-stow/2019-09/msg00000.html) -- stow errors with `stow_contents() called with non-directory path` when it tries to follow a folded symlink with `--dotfiles` enabled. Using `--no-folding` avoids this entirely.

**When NOT to use `--no-folding`:** If a package has many files in deeply nested directories, `--no-folding` creates many symlinks. For dotfiles repos this is always preferred because the alternative (directory-level symlinks) causes tools to write directly into the git repo.

## Proposed Solution

Create a `scripts/stow-deploy` wrapper script that:

1. Runs pre-flight checks (stow installed, clean working tree, git-crypt unlocked)
2. Rejects the `local` package with an informative message (requires manual sub-package stowing)
3. Tries `stow -R` directly (fast path for no conflicts)
4. On conflict failure, removes non-stow symlinks and retries
5. On further conflict failure, uses `--adopt` then auto-restores or shows diff
6. On non-conflict failure, fails immediately with the original error (no cascade)
7. Always uses `--no-folding` to prevent tree folding
8. Supports `--headless` mode for automated fleet deployment (best-effort per package)

### Pre-flight checks

Before processing any packages, the script validates:

1. **Stow installed:** `command -v stow` guard (fatal if missing)
2. **Stow version:** Warn about 2.3.1 nested `dot-` bug (non-fatal)
3. **`local` package rejected:** If `local` is in the package list, print error pointing to README manual steps and exit
4. **git-crypt unlocked:** If any of `secrets`, `ssh`, `git` are in the package list, check that `stow/secrets/dot-secrets` is a valid text file (not encrypted binary). Fatal if locked -- deploying encrypted blobs breaks shell login and SSH.
5. **Clean stow directory:** In `--headless` mode, check `git -C "$REPO_ROOT" status --porcelain stow/` and refuse if dirty (prevents `git checkout` from destroying uncommitted changes). In interactive mode, warn but continue.

### Error classification

The current script swallows all stderr on the fast path (`2>/dev/null`). When stow fails for a non-conflict reason (permission denied, stow internal error, 2.3.1 nested `dot-` bug), the error cascades through the conflict resolution pipeline with confusing results.

**Fix:** After the fast-path failure, capture stderr and check if it contains conflict indicators (`existing target is not owned by stow` or `existing target is neither a link nor a directory`). If stderr does NOT contain conflict indicators, fail immediately with the full error output -- don't enter the resolution pipeline.

### Failure mode by operating mode

| Mode | On package failure | Summary |
|------|-------------------|---------|
| Interactive | Fail-fast (`set -e`) | Abort on first error, user investigates |
| Headless | Best-effort (continue loop) | Track failures, report summary, exit non-zero if any failed |

### `scripts/stow-deploy`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Stow deployment wrapper with automatic conflict resolution
# Handles: non-stow symlinks, existing plain files, tree folding
#
# Usage: scripts/stow-deploy [--headless] <package> [package ...]
# Requires explicit package names. No auto-discovery.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOW_DIR="$REPO_ROOT/stow"
TARGET="$HOME"
HEADLESS=false

# Parse flags
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --headless) HEADLESS=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "Usage: scripts/stow-deploy [--headless] <package> [package ...]" >&2
  echo "Example: scripts/stow-deploy shell zsh bash git ssh" >&2
  exit 1
fi

# --- Pre-flight checks ---

# Verify stow is installed
if ! command -v stow >/dev/null 2>&1; then
  echo "FATAL: GNU Stow is not installed" >&2
  exit 1
fi

# Warn about known stow 2.3.1 nested dot- bug
stow_version=$(stow --version 2>&1 | sed -n 's/.*version //p')
case "$stow_version" in
  2.3.*|2.2.*|2.1.*|2.0.*)
    echo "WARNING: Stow $stow_version has known --dotfiles bug with nested directories" >&2
    echo "         Packages with nested dot- dirs (git, ssh, gh, pip, claude) may fail" >&2
    ;;
esac

# Validate package names (no path traversal) and reject special-case packages
for pkg in "$@"; do
  if [[ "$pkg" =~ [./] ]] || [[ ! -d "$STOW_DIR/$pkg" ]]; then
    echo "ERROR: Invalid package name: $pkg" >&2
    exit 1
  fi
  if [ "$pkg" = "local" ]; then
    echo "ERROR: The 'local' package requires manual sub-package stowing." >&2
    echo "       dot-Library conflicts with --dotfiles (creates .Library instead of Library)." >&2
    echo "       See README step 4 for manual instructions." >&2
    exit 1
  fi
done

# Check git-crypt unlock status for encrypted packages
for pkg in "$@"; do
  case "$pkg" in
    secrets|ssh|git)
      if [ -f "$STOW_DIR/secrets/dot-secrets" ]; then
        if file "$STOW_DIR/secrets/dot-secrets" | grep -q "data\|encrypted"; then
          echo "FATAL: git-crypt is locked. Encrypted files would be deployed as binary blobs." >&2
          echo "       Run: git-crypt unlock ~/.config/git-crypt/key" >&2
          exit 1
        fi
      fi
      break  # only need to check once
      ;;
  esac
done

# In headless mode, refuse to run with dirty stow directory
if [ "$HEADLESS" = true ]; then
  dirty=$(git -C "$REPO_ROOT" status --porcelain stow/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FATAL: stow/ has uncommitted changes. In --headless mode, --adopt followed" >&2
    echo "       by git checkout would destroy these changes. Commit first." >&2
    exit 1
  fi
else
  dirty=$(git -C "$REPO_ROOT" status --porcelain stow/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "WARNING: stow/ has uncommitted changes. If --adopt runs, git diff will" >&2
    echo "         mix your edits with adopted files. Consider committing first." >&2
  fi
fi

# --- Deploy ---

STOW_FLAGS=(--dotfiles --no-folding --target="$TARGET")

cd "$STOW_DIR"

# Track adopted packages and failures (temp files avoid subshell variable loss)
adopted_file=$(mktemp)
failed_file=$(mktemp)
trap 'rm -f "$adopted_file" "$failed_file"' EXIT

for pkg in "$@"; do
  echo "==> Stowing $pkg"

  # Fast path: try restow directly. If no conflicts, done.
  if stow "${STOW_FLAGS[@]}" -R "$pkg" 2>/dev/null; then
    echo "  Done: $pkg"
    continue
  fi

  # Stow failed. Collect conflict details from stderr.
  err=$(stow "${STOW_FLAGS[@]}" -R "$pkg" 2>&1 || true)

  # Error classification: only enter conflict resolution if stderr
  # contains conflict indicators. Other errors (permissions, stow bugs)
  # should fail immediately with the original error message.
  if ! echo "$err" | grep -q "existing target"; then
    echo "  ERROR: $pkg failed (not a conflict):" >&2
    echo "$err" | sed 's/^/    /' >&2
    if [ "$HEADLESS" = true ]; then
      echo "$pkg" >> "$failed_file"
      continue  # best-effort: try remaining packages
    else
      exit 1  # fail-fast in interactive mode
    fi
  fi

  # Remove non-stow symlinks (absolute symlinks stow cannot own)
  echo "$err" | sed -n 's/.*existing target is not owned by stow: //p' | while read -r target; do
    full="$TARGET/$target"
    if [ -L "$full" ]; then
      dest=$(readlink "$full")
      echo "  Removing non-stow symlink: $target -> $dest"
      rm -f "$full"
    fi
  done

  # Retry after symlink cleanup
  if stow "${STOW_FLAGS[@]}" -R "$pkg" 2>/dev/null; then
    echo "  Done: $pkg (after symlink cleanup)"
    continue
  fi

  # Still failing: adopt existing plain files
  echo "  Adopting existing files for $pkg..."
  if ! stow "${STOW_FLAGS[@]}" -R --adopt "$pkg" 2>/dev/null; then
    adopt_err=$(stow "${STOW_FLAGS[@]}" -R --adopt "$pkg" 2>&1 || true)
    echo "  ERROR: $pkg adopt failed:" >&2
    echo "$adopt_err" | sed 's/^/    /' >&2
    if [ "$HEADLESS" = true ]; then
      echo "$pkg" >> "$failed_file"
      continue
    else
      exit 1
    fi
  fi
  echo "$pkg" >> "$adopted_file"

  if [ "$HEADLESS" = true ]; then
    # Headless: auto-restore repo versions (proven pattern from bigdaddy deployment)
    git -C "$REPO_ROOT" checkout -- "stow/$pkg/"
    echo "  Done: $pkg (adopted + auto-restored repo version)"
  else
    echo "  Done: $pkg (adopted — review diff below)"
  fi
done

# Show diffs for adopted files (interactive mode only)
if [ "$HEADLESS" = false ] && [ -s "$adopted_file" ]; then
  echo ""
  echo "=== Files adopted from target into repo ==="
  echo "Review changes below. Local file content now overwrites repo versions."
  echo ""
  cd "$REPO_ROOT"
  while read -r pkg; do
    echo "--- $pkg ---"
    git diff "stow/$pkg/" 2>/dev/null || echo "  (no changes or untracked)"
  done < "$adopted_file"
  echo ""
  echo "To keep local changes:   git add stow/<package>/"
  echo "To discard and use repo: git checkout -- stow/<package>/"
fi

# Headless summary
if [ "$HEADLESS" = true ] && [ -s "$failed_file" ]; then
  echo ""
  echo "=== FAILURES ==="
  while read -r pkg; do
    echo "  FAILED: $pkg"
  done < "$failed_file"
  exit 1
fi
```

### Research Insights: Script Design Decisions

**Why no auto-discovery (requires explicit packages):**

- The `local` package requires special handling -- README documents manual steps for it
- macOS-only packages (ghostty, cursor, brew) should not be stowed on Ubuntu servers
- The bigdaddy deployment plan explicitly lists which packages to deploy per platform
- Auto-discovery would silently stow everything, which is dangerous for cross-platform repos

**Why `-R` (restow) instead of `-S` (stow):**

- Makes the script idempotent -- safe to run on first deployment AND day-to-day re-stowing
- `-R` unstows then re-stows, so it prunes obsolete symlinks after package restructuring
- Without `-R`, running on already-stowed packages fails because stow sees its own symlinks

**Why temp file instead of bash array for `adopted`:**

- `cmd | while read` runs the loop in a subshell. Any `adopted+=()` inside the subshell is lost when the subshell exits. This is a bash pitfall that every review agent flagged.
- A temp file persists across subshell boundaries and works reliably on all bash versions.

**Why `sed -n 's/...//p'` instead of `grep -oP`:**

- `grep -oP` (PCRE lookbehind) is a GNU grep extension. macOS ships BSD grep which does not support `-P`.
- `sed` is POSIX-compliant and works identically on macOS and Ubuntu.
- The original script would have silently failed to detect any symlink conflicts on macOS.

**Why `--headless` flag:**

- macOS (interactive): User wants to review diffs and decide to keep or discard local changes
- Ubuntu servers (headless): No human is watching. Auto-restore repo versions to prevent config contamination. This matches the proven bigdaddy deployment pattern: `stow --adopt` then `git checkout`.

## Acceptance Criteria

### Script behavior

- [x] `scripts/stow-deploy` handles all three conflict types automatically
- [x] Non-stow symlinks are removed and logged before restowing
- [x] Existing plain files are adopted via `--adopt`, with `git diff` output for review (interactive) or auto-restored (headless)
- [x] `--no-folding` is always used to prevent directory-level symlinks
- [x] `-R` (restow) used for idempotent first-deploy and re-deploy
- [x] Script requires explicit package names (no auto-discovery)
- [x] `--headless` flag auto-restores repo versions after adopt
- [x] `command -v stow` guard and stow version warning included
- [x] Package names validated (no path traversal via `../`)
- [x] POSIX-portable parsing (no `grep -P`, no bash 3.2 incompatibilities)

### Pre-flight checks

- [x] `local` package rejected with informative message pointing to README
- [x] git-crypt lock status checked before stowing `secrets`, `ssh`, or `git` packages
- [x] Dirty `stow/` directory: fatal in `--headless` mode, warning in interactive mode

### Error handling

- [x] Non-conflict stow errors (permissions, stow bugs) fail immediately with original error -- no cascade through conflict resolution
- [x] Interactive mode: fail-fast on first error
- [x] Headless mode: best-effort (continue loop), failure summary at end, exit non-zero

### Companion changes

- [x] `stow/shell/dot-profile`: make `~/.local/bin/env` sourcing resilient (`[ -f ... ] && .` instead of unconditional `.`)
- [x] README bootstrap section updated to reference `scripts/stow-deploy`
- [x] CLAUDE.md Stow Packages section updated with conflict resolution docs

## Technical Considerations

- **`--no-folding` trade-off:** Creates more symlinks (one per file instead of one per directory). This is preferred for dotfiles because other tools won't accidentally write into the repo. Also avoids a [known bug](https://lists.gnu.org/archive/html/bug-stow/2019-09/msg00000.html) where `--dotfiles` and tree folding don't cooperate.
- **`--adopt` safety:** Interactive mode shows `git diff` for review. Headless mode auto-restores. This matches the user's stated preference: "capture local changes and roll them into the default image, a machine specific branch, or delete them."
- **No `trash` for symlink removal:** Symlinks are just pointers -- removing them doesn't lose data. The target file still exists in the stow package. Using `rm -f` here is safe and intentional.
- **GNU Stow 2.3.1 bug on Ubuntu:** Nested `dot-` directories don't convert correctly. The deployment plan for Ubuntu already accounts for this with manual `ln -sf` fallbacks. The script warns but does not attempt to work around this bug -- that responsibility belongs to `dotfiles-cli` or platform-specific deploy scripts.
- **Not self-stowable:** The script lives in `scripts/` (repo infrastructure), not `stow/` (config payloads). It cannot be stowed because it is needed before stowing begins. If a user-facing CLI command is needed, that belongs in `dotfiles-cli` (Rust).
- **Bash 3.2 compatibility:** macOS ships bash 3.2. The script avoids empty array expansion under `set -u` by using a temp file for `adopted` tracking instead of a bash array.
- **`.profile` resilience:** Line 61 of `stow/shell/dot-profile` unconditionally sources `~/.local/bin/env` (provided by the `local` package). If this file is missing, every shell login fails -- potentially causing SSH lockout on headless servers. Fix: change `. "$HOME/.local/bin/env"` to `[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"`. This 1-line change eliminates the deployment ordering dependency between `local` and `shell` packages.

## Stow Flag Reference

| Flag | Handles non-stow symlinks? | Handles plain files? | Handles inter-package conflicts? |
|------|---------------------------|---------------------|----------------------------------|
| `--override=REGEX` | No | No | Yes (replaces other package's link) |
| `--defer=REGEX` | No | No | Yes (yields to other package's link) |
| `--adopt` | No | Yes (moves file into package) | No |
| `-R` (restow) | No | No | No (just prunes stale links) |
| `--no-folding` | N/A | N/A | N/A (prevents directory symlinks) |
| `--force` | **Does not exist** | -- | -- |

## Deployment Checklist

### Pre-deploy

- [ ] Verify stow is installed on all targets: `command -v stow`
- [ ] Check stow version: `stow --version` (2.3.1 on Ubuntu has nested `dot-` bug)
- [ ] Commit any uncommitted changes in the repo before running (safety net for `--adopt`)
- [ ] Back up symlink state on first run: `find "$HOME" -maxdepth 3 -type l -ls > ~/symlink-baseline.txt`

### Deploy sequence

1. Deploy to macOS first (stow 2.4.1, no nested `dot-` bug)
2. Run single non-critical package first: `scripts/stow-deploy pip`
3. If successful, run all: `scripts/stow-deploy shell zsh bash git ssh ghostty gh claude codex cursor opencode pip brew secrets`
4. Review `git diff` for adopted files
5. For Ubuntu: `scripts/stow-deploy --headless shell bash git ssh secrets`

### Post-deploy verification

```bash
# Verify critical symlinks
for f in ~/.profile ~/.zshrc ~/.bashrc ~/.gitconfig; do
  [ -L "$f" ] && echo "OK: $f -> $(readlink "$f")" || echo "FAIL: $f"
done

# Verify no repo pollution
cd ~/dotfiles && git status --porcelain stow/

# Verify --no-folding (directories should be real, not symlinks)
[ -d ~/.config/git ] && [ ! -L ~/.config/git ] && echo "OK: no tree folding"
```

### Rollback

| Scenario | Recovery |
|----------|----------|
| `--adopt` overwrote repo file | `git checkout -- stow/<package>/` |
| Wrong symlinks created | `stow -D --dotfiles --no-folding -t "$HOME" <package>` |
| Shell config broken, can't login | `ssh -t host '/bin/bash --norc --noprofile'` then fix |
| Full rollback | `git checkout -- stow/` then re-run stow per package |

## References

- Existing solution: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Ubuntu deployment plan: `docs/plans/2026-02-13-feat-deploy-dotfiles-to-bigdaddy-plan.md`
- GNU Stow source: `Stow.pm` lines 531-648 (`stow_node`), 1017-1053 (`find_stowed_path`)
- GNU Stow manual: <https://www.gnu.org/software/stow/manual/stow.html>
- Tree folding + dotfiles bug: <https://lists.gnu.org/archive/html/bug-stow/2019-09/msg00000.html>
- `stoww` wrapper (reference): <https://github.com/jpasquier/stoww>
- Stow dotfiles best practices: <https://venthur.de/2021-12-19-managing-dotfiles-with-stow.html>
- Cross-platform stow patterns: <https://rickcogley.github.io/dotfiles/explanations/gnu-stow.html>
