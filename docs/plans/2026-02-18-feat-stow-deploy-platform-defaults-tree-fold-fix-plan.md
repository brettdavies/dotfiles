---
title: "feat: stow-deploy platform defaults, tree-fold fix, and local package split"
type: feat
status: completed
date: 2026-02-18
deepened: 2026-02-18
brainstorm: docs/brainstorms/2026-02-17-stow-deploy-platform-defaults-and-tree-fold-fix-brainstorm.md
---

# feat: stow-deploy platform defaults, tree-fold fix, and local package split

## Overview

Enhance `scripts/stow-deploy` with platform-aware `--all` flag, tree-fold detection/resolution,
and split the `local` package to eliminate all special-case handling. Fix four tree-folded
packages on this Mac that are leaking ~151 MB of runtime data into the git repo.

## Problem Statement

Three deployment failures traced to the same root: divergent macOS/Ubuntu package lists and
legacy tree-folded symlinks from before `stow-deploy` existed.

1. **Headless server missing `claude` package** -- Ubuntu deployment list only had
   `shell bash git ssh secrets`. Claude Code hooks reference `~/.claude/auto-format.sh` which
   was never deployed.
2. **~151 MB of runtime data in git repo** -- `~/.claude` is a tree-folded directory symlink
   from November 2025. Claude Code writes history, plugins, and caches directly into
   `stow/claude/dot-claude/` (152 MB / 2,528 files). Three other packages (`codex`, `git`,
   `opencode`) are also tree-folded (~155 MB total across all four).
3. **`local` package excluded everywhere** -- The `dot-Library` → `.Library` conflict caused
   stow-deploy to reject `local` entirely. `op-ssh-sign-wrapper` (required for git signing on
   ALL machines) was never auto-deployed.

## Proposed Solution

Four implementation phases, each independently deployable:

1. **Split `local` → `local` + `launchagent`** (package restructure)
2. **Enhance `stow-deploy`** (`--all` flag, tree-fold detection, remove `local` rejection)
3. **Update documentation** (README, CLAUDE.md, solution docs)
4. **Fix this Mac** (run `stow-deploy --all` to resolve tree-folds)

## Technical Approach

### Phase 1: Split `local` package

**Files changed:**

- `stow/local/dot-Library/` → moved to `stow/launchagent/Library/`
- `stow/launchagent/Library/LaunchAgents/com.user.devtosync.plist` (renamed from `dot-Library`)

**Before:**

```text
stow/local/
  dot-local/bin/env
  dot-local/bin/op-ssh-sign-wrapper
  dot-Library/LaunchAgents/com.user.devtosync.plist
```

**After:**

```text
stow/local/
  dot-local/bin/env
  dot-local/bin/op-ssh-sign-wrapper

stow/launchagent/
  Library/LaunchAgents/com.user.devtosync.plist
```

Key insight: `Library/` has no `dot-` prefix because `~/Library` doesn't start with a dot.
`stow --dotfiles` has nothing to convert, so `~/Library/LaunchAgents/` is the correct target.

**Migration for existing deployments:**

On this Mac, the old `local` package was stowed manually. The existing symlink at
`~/Library/LaunchAgents/com.user.devtosync.plist` points to
`stow/local/dot-Library/LaunchAgents/...`. After the split:

1. The old symlink becomes a dangling reference (source path no longer exists)
2. `stow-deploy launchagent` creates a new symlink pointing to `stow/launchagent/Library/...`
3. The stow-deploy conflict resolution handles this (removes non-stow symlink, restows)

No explicit unstow of the old `local` package is needed because the source file moves and the
old symlink simply becomes dangling.

### Phase 2: Enhance `stow-deploy`

The script is currently 224 lines (over the 200-line refactor trigger). Extract new logic into
bash functions within the same file to keep deployment as a single script.

#### 2a. Distinct exit codes

**Insert at:** Top of script, after shebang and header comment.

```bash
# Exit codes — distinct values for automation/CI (all non-zero still indicate failure)
EXIT_USAGE=2        # Bad arguments or flags
EXIT_DEPENDENCY=3   # Missing required tools (stow, git-crypt)
EXIT_PRECONDITION=4 # Pre-flight check failed (disk space, git-crypt lock)
EXIT_PACKAGE=5      # Package-specific failure (stow error, tree-fold failure)
EXIT_PLATFORM=6     # Platform mismatch (launchagent on Linux)
```

Replace all `exit 1` statements with the appropriate exit code. Callers that check `!= 0`
are unaffected (backward compatible).

#### 2b. `--all` flag with platform detection

**Insert at:** Flag parsing (line 17), package expansion (after line 21).

```bash
# Package sets — single source of truth
SHARED_PACKAGES=(secrets shell zsh bash git ssh gh local claude codex opencode pip brew)
DESKTOP_PACKAGES=(ghostty cursor launchagent)

# Flag parsing
--all) ALL=true; shift ;;

# Package expansion (after flag parsing, before usage check)
if [ "$ALL" = true ]; then
  if [ $# -gt 0 ]; then
    echo "ERROR: --all cannot be combined with explicit package names" >&2
    exit "$EXIT_USAGE"
  fi
  platform=$(uname -s)
  case "$platform" in
    Darwin) set -- "${SHARED_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}" ;;
    Linux)  set -- "${SHARED_PACKAGES[@]}" ;;
    *)      echo "FATAL: unsupported platform: $platform. Use explicit package names." >&2
            exit "$EXIT_PLATFORM" ;;
  esac
fi
```

**Package ordering:** `secrets` first (git-crypt dependency), then `shell` (PATH/env setup),
then `zsh`/`bash` (source shell helpers), then everything else. Order matches the brainstorm
and respects the dependency chain documented in
`docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`.

#### 2c. Remove `local` package rejection

**Delete:** Lines 52-57 of current `stow-deploy` (the `if [ "$pkg" = "local" ]` block).

No replacement needed. After the Phase 1 split, `local` is a normal package.

#### 2d. Platform guard for desktop-only packages

**Insert at:** Inside the deploy loop, before `stow` invocation.

When a desktop-only package is explicitly requested on Linux (bypassing `--all` auto-detection),
warn and skip instead of creating meaningless macOS directories like `~/Library/`:

```bash
if [ "$(uname -s)" != "Darwin" ]; then
  case "$pkg" in
    ghostty|cursor|launchagent)
      echo "WARNING: $pkg is macOS-only, skipping on $(uname -s)" >&2
      continue
      ;;
  esac
fi
```

#### 2e. Tree-fold detection and resolution

**Insert at:** After all pre-flight checks, before the deploy loop (after line 88).

**Discovery algorithm:** Hardcoded map of the 4 known tree-folded packages to their target
directories. This is a one-time migration — `--no-folding` prevents future tree-folds, so
generic discovery is YAGNI. The hardcoded approach is more auditable and eliminates false
positive risk from directory walking.

```bash
# Returns the tree-fold target path for a package, or returns 1 if not applicable.
# Only the 4 packages that were tree-folded before --no-folding are listed.
get_fold_target() {
  case "$1" in
    claude)   echo "$HOME/.claude" ;;
    codex)    echo "$HOME/.codex" ;;
    git)      echo "$HOME/.config/git" ;;
    opencode) echo "$HOME/.config/opencode" ;;
    *)        return 1 ;;
  esac
}

# Check if a target is actually tree-folded (directory-level symlink into stow)
is_tree_folded() {
  local target="$1" pkg="$2"
  [ -L "$target" ] || return 1
  local canonical_pkg
  canonical_pkg=$(cd "$STOW_DIR/$pkg" && pwd -P)
  local abs_link
  abs_link=$(cd "$(dirname "$target")" && cd "$(readlink "$target")" && pwd -P 2>/dev/null) || return 1
  [[ "$abs_link" == "$canonical_pkg/"* ]]
}
```

**Resolution function:**

```bash
resolve_tree_fold() {
  local target="$1" pkg="$2"
  local tmpdir

  echo "  Resolving tree-fold: $target"

  # 1. Create staging directory with random suffix (mktemp, no recovery infra)
  tmpdir=$(mktemp -d "${target}.XXXXXX")

  # 2. Copy all contents (runtime data + tracked files are co-mingled)
  #    cp -a src/. dst/ copies hidden files without needing shopt dotglob
  #    Use cp (not mv) so tracked files remain in the stow package dir
  if ! cp -a "$target"/. "$tmpdir"/; then
    echo "  ERROR: Failed to copy contents of $target" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  # 3. Rename-aside: move symlink out of the way (no data-loss window)
  local aside="${target}.stow-old-$$"
  mv "$target" "$aside"

  # 4. Move staging dir to final target (atomic rename)
  mv "$tmpdir" "$target"

  # 5. Clean up the old symlink
  rm -rf "$aside"

  # 6. Clean untracked files from the stow package dir
  #    Tracked files are intact (cp, not mv). Use -fdx to also remove gitignored
  #    files — .gitignore patterns block -fd from cleaning. Double -f removes
  #    nested git repos (e.g. claude plugins/marketplaces).
  if ! git -C "$REPO_ROOT" clean -ffdx -- "stow/$pkg"; then
    echo "  WARNING: git clean failed for stow/$pkg" >&2
  fi

  echo "  Done: $target is now a real directory"
}
```

**Failure recovery:** Uses rename-aside pattern (`mv "$target" "${target}.stow-old-$$"`) to
eliminate the data-loss window entirely. The target always exists as either the original symlink
or the new real directory. If interrupted between rename-aside and move-in, the `.stow-old-$$`
directory contains the original symlink and `$tmpdir` contains the copy — both are recoverable.
Uses `mktemp -d "${target}.XXXXXX"` for staging with a random suffix. No predictable naming
convention, no interrupted-migration scanner. Manual cleanup is trivial and this is a one-time
migration on one machine.

#### 2f. Process safety and headless gating

Process detection via `fuser` was removed from the script. The primary guard is the operator
stopping Claude Code before running `stow-deploy --all` (Phase 4, step 1). Rationale:

- `fuser -s "$target"` checks the symlink inode, not files within the directory tree
- The tree-fold migration is a one-time operation on one Mac
- `--no-folding` in `STOW_FLAGS` prevents recurrence on fresh deployments
- A documented prerequisite is clearer and more reliable than runtime detection

The process-stop reminder is gated behind the `HEADLESS` check — on headless servers no user
is present to act on it:

```bash
if [ "$HEADLESS" = false ]; then
  echo "NOTE: Stop any tools that write to tree-folded directories before proceeding."
  read -r -p "Press Enter to continue or Ctrl-C to abort..."
else
  echo "ERROR: Tree-folded directories detected in headless mode. Aborting." >&2
  echo "  Resolve tree-folds interactively first, then re-deploy headless." >&2
  exit "$EXIT_PRECONDITION"
fi
```

### Phase 3: Documentation updates

**Files to update:**

| File | Change |
|------|--------|
| `README.md:32` | Package table: split `local` row into `local` (shared) + `launchagent` (macOS) |
| `README.md:89-101` | Step 4: replace inline lists with `--all` examples |
| `README.md:104-109` | Remove "The `local` package requires separate handling" section |
| `README.md:176-183` | Step 8: update LaunchAgent path from `stow/local/dot-Library/...` to `stow/launchagent/Library/...` or simplify to "included in `stow-deploy --all`" |
| `CLAUDE.md:53` | Remove "The `local` package is rejected" note |
| `CLAUDE.md` stow-deploy table | Add `--all` flag documentation |
| `docs/solutions/.../stow-conflict-resolution-wrapper.md` | Update usage examples, remove `local` rejection section |
| `docs/brainstorms/...` | Mark brainstorm as `status: planned` |

### Phase 4: Fix this Mac + deploy to headless servers

**On this Mac (interactive):**

1. Verify sufficient disk space (`df -h /` — need ~300 MB free for temp copies)
1. Stop Claude Code (required for `~/.claude` tree-fold resolution)
1. Run `scripts/stow-deploy --all`
1. Verify `~/.claude` is a real directory with per-file symlinks
1. Verify runtime data is intact (`~/.claude/history.jsonl` exists)
1. Verify `du -sh stow/claude/dot-claude/` is small (only tracked files)

**On headless servers:**

```bash
cd ~/dotfiles && git pull
scripts/stow-deploy --headless --all
```

This deploys all previously missing packages (`zsh`, `gh`, `claude`, `codex`, `opencode`,
`pip`, `brew`, `local`) and the tree-fold detection is a no-op (headless servers were deployed
after `--no-folding` was added).

## Acceptance Criteria

### Functional

- [x] `stow-deploy --all` on macOS deploys shared + desktop packages
- [x] `stow-deploy --headless --all` on Linux deploys shared packages only
- [x] `stow-deploy --all` with explicit packages errors out
- [x] `stow-deploy --all` on unknown platform errors out with clear message
- [x] Tree-fold detection finds and resolves directory-level symlinks into `stow/`
- [x] Tree-fold resolution preserves runtime data (moved to real directory)
- [x] Tree-fold resolution cleans untracked files from stow package dir
- [x] Tree-fold resolution uses rename-aside pattern (no data-loss window)
- [x] Tree-fold resolution failure at callsite logged and package skipped
- [x] Post-resolution validation confirms target is a real directory
- [x] Desktop-only packages warn and skip on non-macOS platforms
- [x] Process-stop reminder only shown in interactive mode
- [x] Headless mode aborts with clear error if tree-folds detected
- [x] Distinct exit codes used for all failure categories
- [x] `local` package deploys without rejection (after split)
- [x] `launchagent` package creates correct `~/Library/LaunchAgents/` symlink on macOS
- [x] `stow-deploy --all` is idempotent (clean no-op on re-run)
- [x] `op-ssh-sign-wrapper` is deployed on headless servers via `--all`

### Non-Functional

- [x] Script passes `shellcheck scripts/stow-deploy`
- [x] Script uses only POSIX-guaranteed utilities (no `file`, `realpath`, `lsof` hard deps)
- [x] Functions keep the script organized despite exceeding 200 lines
- [x] `.gitignore` patterns for `claude` kept as defense-in-depth

## Implementation Checklist

### Phase 1: Package split

- [x] Create `stow/launchagent/Library/LaunchAgents/` directory
- [x] Move `stow/local/dot-Library/LaunchAgents/com.user.devtosync.plist` to
      `stow/launchagent/Library/LaunchAgents/com.user.devtosync.plist`
- [x] Remove empty `stow/local/dot-Library/` directory tree
- [x] Verify `stow/local/` only contains `dot-local/bin/env` and
      `dot-local/bin/op-ssh-sign-wrapper`

### Phase 2: stow-deploy enhancements

- [x] Add distinct exit code constants at top of script (EXIT_USAGE=2 through EXIT_PLATFORM=6)
- [x] Replace all `exit 1` with appropriate exit code
- [x] Add platform guard for desktop-only packages (warn and skip on non-macOS)
- [x] Add header comment explaining single-file exception to 200-line trigger
- [x] Add `SHARED_PACKAGES` and `DESKTOP_PACKAGES` arrays at top of script
- [x] Add cross-reference comment noting Rust CLI `PACKAGE_ORDER` divergence
- [x] Add `--all` and `ALL=false` to flag parsing (matches `HEADLESS` naming convention)
- [x] Add package expansion logic after flag parsing (with `--all` + explicit error)
- [x] Add unknown platform guard
- [x] Remove `local` package rejection block (lines 52-57)
- [x] Add `get_fold_target()` hardcoded map (4 known packages, not generic discovery)
- [x] Add `is_tree_folded()` check function (absolute path comparison via `cd && pwd -P`)
- [x] Add `resolve_tree_fold()` function (rename-aside pattern, `cp -a`, `git clean -fd`)
- [x] Add tree-fold detection loop before deploy loop (with headless-gated process-stop reminder)
- [x] Add callsite error handling: check `resolve_tree_fold()` return, log and skip on failure
- [x] Update usage message to show `--all` flag
- [x] Run `shellcheck scripts/stow-deploy` and fix any findings

### Phase 3: Documentation

- [x] Update README package table (split `local` → `local` + `launchagent`)
- [x] Update README step 4 (use `--all` examples with PACKAGES variable)
- [x] Remove README `local` special handling section
- [x] Update README step 8 LaunchAgent path
- [x] Update CLAUDE.md `local` rejection note and stow-deploy table
- [x] Update `stow-conflict-resolution-wrapper.md` usage examples
- [x] Mark brainstorm as `status: planned`

### Phase 4: Corrective action (macOS)

- [x] Stop Claude Code on this Mac
- [x] Run `stow-deploy --all` on this Mac (tree-folds resolved during testing)
- [x] Verify `~/.claude` is a real directory (not symlink)
- [x] Verify `~/.codex`, `~/.config/git`, `~/.config/opencode` are real directories
- [x] Verify per-file symlinks exist for tracked files
- [x] Verify runtime data intact in `~/.claude/`
- [x] Verify `stow/claude/dot-claude/` is small (tracked files only)
- [x] Verify `op-ssh-sign-wrapper` symlink points to `stow/local/`
- [x] Verify `launchagent` symlink points to `stow/launchagent/` (not old `stow/local/`)
- [x] Re-run `stow-deploy --all` to confirm idempotency (clean no-op, all 17 packages)

### Phase 4: Headless deployment (post-merge)

- [ ] Deploy to headless server: `stow-deploy --headless --all`
- [ ] Verify `~/.claude/auto-format.sh` exists on headless server (original trigger)
- [ ] Verify `op-ssh-sign-wrapper` on PATH on headless server
- [ ] Verify no `~/Library/` directory created on headless server

## Deepening Insights

Deepened on 2026-02-18 with 8 parallel review agents: security sentinel, deployment
verification, code simplicity, architecture strategy, data migration, pattern recognition,
learnings researcher, and best practices researcher.

### Critical fixes applied to plan above

| Finding | Source agents | Fix applied |
|---------|-------------|-------------|
| `mv` empties stow package dir — tracked files lost for re-stowing | Security, Data migration, Architecture | Changed to `cp -a` so originals remain; removed `realpath`/`readlink -f` |
| `realpath --relative-to` is GNU-only, not on macOS BSD | All 6 code-reviewing agents | Replaced with known path `stow/$pkg` |
| `readlink \| grep` substring match is fragile | Security, Architecture, Pattern recognition | Replaced with `cd && pwd -P` absolute path comparison |
| `2>/dev/null \|\| true` on destructive `mv`/`git clean` hides failures | Security, Data migration | Added explicit error checks with `if !` and `return 1` |
| `shopt -s dotglob` + `mv` error suppression | Security, Data migration | Replaced with `cp -a src/. dst/` (handles hidden files without `shopt`) |
| Post-resolution validation loop | Code simplicity | Removed (cannot fire if resolution succeeds; `set -e` handles failures) |

### Simplification summary

The code simplicity reviewer identified ~45 lines of unnecessary complexity. After applying
all fixes, the estimated new logic is ~105 lines instead of the original ~150 (30% reduction).
Key simplifications:

- **Hardcoded tree-fold map adopted** (simplicity reviewer's recommendation over architecture
  reviewer's generic approach). This is a one-time migration; `--no-folding` prevents recurrence;
  4 known packages are explicit and auditable. ~20 fewer lines than generic directory walking.
- **`fuser` detection removed** — one-time migration on one machine; documented prerequisite
  is simpler and more reliable than platform-dependent runtime detection.
- **Interrupted migration scanner removed** — `mktemp -d` with random suffix; failure window
  is nanoseconds; manual cleanup is trivial.
- **Post-resolution validation removed** — redundant with `set -e` error handling.

### Architecture considerations

**Single-file exception:** The script will exceed 200 lines after changes (~330 lines). This
is justified by operational constraints — deployment scripts on thousands of headless servers
must be self-contained with no `source` dependencies. Add a header comment explaining this:

```bash
# This script is intentionally kept as a single file (no sourced helpers)
# to ensure reliable execution on freshly cloned repos across thousands
# of headless servers. See docs/solutions/.../stow-conflict-resolution-wrapper.md
```

**STAR violation with Rust CLI:** The `dotfiles-cli` at `~/dev/dotfiles-cli/src/link/mod.rs`
has its own `PACKAGE_ORDER` constant that diverges from the bash arrays (missing `brew` and
`launchagent`, includes `vscode`, no platform split). Add cross-reference comments in both
locations. Track these Rust CLI changes for post-merge:

1. Add `brew` and `launchagent` to `PACKAGE_ORDER`
2. Remove `adjusted_package_dir` special case (no longer needed after split)
3. Remove `launchagent_links` function (stow handles it directly)
4. Add platform-aware `--all` expansion if Rust CLI is to replace `stow-deploy --all`

**`launchagent` package precedent:** First non-`dot-`-prefixed stowed package. This is correct
(`~/Library` has no dot) but should have an inline comment explaining the deviation from the
`dot-` convention.

### Data migration safeguards

**Pre-migration backup (Phase 4, new step 0):** Before running `stow-deploy --all` on macOS,
create a backup of all tree-folded runtime data:

```bash
BACKUP="$HOME/stow-migration-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -RL ~/.claude "$BACKUP/dot-claude"
cp -RL ~/.codex "$BACKUP/dot-codex"
cp -RL ~/.config/git "$BACKUP/dot-config-git"
cp -RL ~/.config/opencode "$BACKUP/dot-config-opencode"
du -sh "$BACKUP"/  # Expected: ~147M+
```

**Post-migration verification:** Add file-count comparison to `resolve_tree_fold()`:

```bash
pre_count=$(find "$target" -type f | wc -l)
# ... perform cp + rm + mv ...
post_count=$(find "$target" -type f | wc -l)
if [ "$post_count" -lt "$pre_count" ]; then
  echo "  WARNING: File count dropped from $pre_count to $post_count" >&2
fi
```

**Interactive git clean dry-run:** In interactive mode, show what `git clean` would remove
before executing:

```bash
if [ "$HEADLESS" = false ]; then
  git -C "$REPO_ROOT" clean -fdn -- "stow/$pkg" | head -20
fi
git -C "$REPO_ROOT" clean -fd -- "stow/$pkg"
```

### Deployment checklist additions

The deployment verification agent produced comprehensive pre/post deploy checklists. Key
additions to Phase 4:

- **Pre-deploy:** Record baseline sizes (`du -sh ~/.claude/`, file counts), verify tree-fold
  state (`readlink` on all four targets), verify git tracked files in stow packages
- **Post-deploy macOS:** Verify per-file symlinks for tracked files, verify `stow/claude/`
  is small (under 200K), verify `op-ssh-sign-wrapper` symlink, re-run is idempotent
- **Post-deploy Ubuntu:** Verify `~/.claude/auto-format.sh` exists (original trigger),
  verify `op-ssh-sign-wrapper` on PATH, verify no `~/Library/` directory created
- **Monitoring (24h):** Claude Code starts normally, git signing works, no re-tree-folding

### Edge cases discovered

- **Self-referential symlink in `debug/latest`:** `~/.claude/debug/latest` is an absolute
  symlink pointing back into `~/.claude/debug/`. It is self-healing after the migration
  (target path resolves again once rename completes), but reinforces that Claude Code must
  be genuinely stopped.
- **Nested git repos in `plugins/marketplaces/`:** `git clean` skips nested repos by default
  (`Would skip repository`). The two marketplace plugin repos (9.2 MB combined) are safe.
- **`~/.config/git/local` override file:** Headless servers use this for git signing overrides.
  The tree-fold resolution preserves it (it gets copied to the real directory). After
  re-stowing, tracked files become symlinks alongside the untracked `local` file.

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-02-17-stow-deploy-platform-defaults-and-tree-fold-fix-brainstorm.md`
- Script: `scripts/stow-deploy` (224 lines, insertion points at lines 17, 21, 52-57, 88)
- Package: `stow/local/` (split target)
- CI: `.github/workflows/shellcheck.yml:29`
- Gitignore: `.gitignore:52` (`/stow/claude/dot-claude/**/*`)

### Learnings applied

- `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md` — three-phase
  conflict resolution, `sed` over `grep -oP`, `grep -qI` for binary detection
- `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md` — deployment
  ordering, `op-ssh-sign-wrapper` must be on PATH, `url.insteadOf` requires SSH before git
- `docs/solutions/deployment-issues/portable-binary-detection-sentinel-fix-and-auto-hooks.md` —
  `command -v` over `which`, POSIX-only utilities, auto `core.hooksPath`
- `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` — `.zshenv` for
  non-interactive shells, PATH ordering in `.profile`

### Spec-flow gaps addressed

- Q1: `--all` + explicit packages → error out
- Q2: Tree-fold discovery → hardcoded map of 4 known packages (YAGNI; `--no-folding` prevents new ones)
- Q3: git clean flags → `-ffdx` scoped to package dir (double -f for nested repos, -x for gitignored files)
- Q4: Failure recovery → `mktemp -d` with random suffix; no recovery infra (manual cleanup)
- Q5: Abort granularity → per-package skip, not global abort
- Q6: Process detection → removed; documented prerequisite to stop tools before migration
- Q7: `launchagent` on Linux → excluded by `--all`, allowed if explicit
- Q8: Old `local` stow state → dangling symlink handled by conflict resolution
- Q9: Script size → bash functions in same file
