---
title: Stow conflict resolution wrapper (stow-deploy)
category: deployment-issues
tags:
  - gnu-stow
  - conflict-resolution
  - adopt
  - symlinks
  - deployment
  - headless
module: dotfiles deployment
symptom: GNU Stow refuses to deploy packages when existing symlinks, plain files, or directory-level symlinks conflict with the target
root_cause: GNU Stow has no --force flag. Three distinct conflict types require different resolution strategies that stow cannot handle alone.
date: 2026-02-17
severity: high
---

# Stow Conflict Resolution Wrapper (stow-deploy)

## Problem

GNU Stow terminates without modifying the filesystem when any conflict is detected. There is no `--force` flag. Three conflict types prevent clean deployment:

| Conflict type | Cause | Stow behavior |
|---|---|---|
| Non-stow symlink | Manually created absolute symlink (e.g., `ln -sf /abs/path ~/.config/foo`) | Rejected by `find_stowed_path()` -- stow only owns relative symlinks it created |
| Existing plain file | Config created by an installer or default OS setup | Stow refuses to overwrite |
| Tree folding | Stow creates a directory-level symlink instead of per-file symlinks | Other tools write into the git repo through the directory symlink |

None of stow's built-in flags (`--override`, `--defer`, `--adopt`) solve all three. `--override` only handles inter-package conflicts between stow-owned symlinks. `--adopt` only handles plain files. Nothing handles non-stow symlinks.

## Solution

`scripts/stow-deploy` is a wrapper that resolves all three conflict types through a three-phase pipeline:

```text
Phase 1: Fast path     -- stow -R (no conflicts? done)
Phase 2: Symlink cleanup -- remove non-stow symlinks, retry stow -R
Phase 3: Adopt          -- stow -R --adopt for plain file conflicts
```

The script always passes `--no-folding` to prevent tree folding entirely (phase 0, effectively).

### Usage

```bash
# Interactive: shows git diff for adopted files, user decides to keep or discard
scripts/stow-deploy shell zsh bash git ssh

# Headless: auto-restores repo versions after adopt, best-effort per package
scripts/stow-deploy --headless shell bash git ssh secrets
```

### Three-phase conflict resolution

**Phase 1 -- Fast path.** Try `stow -R` directly. Stow's two-phase algorithm scans all conflicts before making any changes, so a failed call is safe -- nothing was modified. If it succeeds, the package is done.

```bash
if stow "${STOW_FLAGS[@]}" -R "$pkg" 2>&1; then
  continue
fi
```

The key design decision: capture stderr on this first call rather than discarding it. The captured error output drives the subsequent phases without re-running stow.

**Phase 2 -- Symlink cleanup.** Parse stderr for `existing target is not owned by stow:` lines. Extract the target paths and remove any that are symlinks. Retry `stow -R`.

```bash
sed -n 's/.*existing target is not owned by stow: //p' <<< "$err" | while read -r target; do
  full="$TARGET/$target"
  if [ -L "$full" ]; then
    rm -f "$full"  # symlinks are just pointers -- no data loss
  fi
done
```

**Phase 3 -- Adopt.** If conflicts remain after symlink cleanup, they are plain files. Run `stow -R --adopt` which moves existing files into the stow package directory and creates symlinks in their place. Then either show the diff (interactive) or auto-restore the repo version (headless).

```bash
stow "${STOW_FLAGS[@]}" -R --adopt "$pkg"

if [ "$HEADLESS" = true ]; then
  git checkout -- "stow/$pkg/"   # restore repo version
else
  # show git diff for user review
fi
```

### Error classification

Before entering the conflict resolution pipeline, the script checks whether stderr actually contains conflict indicators (`existing target`). Non-conflict errors (permissions, stow bugs, the 2.3.1 nested `dot-` bug) fail immediately with the original error message. This prevents confusing cascades where a permission error triggers adopt.

### Pre-flight checks

The script validates five conditions before processing any packages:

1. **Stow installed** -- `command -v stow` (fatal if missing)
2. **Stow version** -- warns if < 2.4.0 (nested `dot-` directory bug; install via `brew install stow`)
3. **Package validation** -- rejects path traversal (`../`), nonexistent packages, and the `local` package
4. **git-crypt unlocked** -- checks `grep -qI` on `stow/secrets/dot-secrets` to detect binary (encrypted) content for packages `secrets`, `ssh`, `git`
5. **Clean working tree** -- `git status --porcelain stow/` (fatal in headless mode, warning in interactive)

### Failure modes

| Mode | On package failure | Rationale |
|---|---|---|
| Interactive | Fail-fast (exit 1) | User is present to investigate |
| Headless | Best-effort (continue loop, summary at end) | Deploy as many packages as possible on unattended servers |

## Key Patterns

### Capture stderr on first stow call

Do not discard stderr on the fast path and re-run stow to capture it. The captured output from the first failure drives all subsequent resolution phases:

```bash
# Correct: capture stderr from the initial attempt
if err=$(stow ... -R "$pkg" 2>&1); then
  continue
fi
# $err now contains conflict details for phases 2 and 3

# Wrong: discard stderr then re-run
stow ... -R "$pkg" 2>/dev/null || true
err=$(stow ... -R "$pkg" 2>&1 || true)  # runs stow twice
```

### --no-folding always enabled

Without `--no-folding`, stow may create `~/.config/git -> ../../dotfiles/stow/git/dot-config/git`. Any tool that writes to `~/.config/git/` then writes directly into the git repo. This also triggers a [known bug](https://lists.gnu.org/archive/html/bug-stow/2019-09/msg00000.html) where `--dotfiles` and tree folding produce `stow_contents() called with non-directory path` errors.

Trade-off: more symlinks (one per file instead of one per directory). For dotfiles repos this is always the correct choice.

### --adopt + git checkout for plain file conflicts

`--adopt` moves the target file into the stow package (overwriting the repo version), then creates the symlink. The symlink now points to the file that used to live at the target. To restore the repo version, `git checkout` overwrites the adopted file, and the symlink automatically reflects the change.

This is safe because stow's two-phase algorithm ensures `--adopt` only runs after the initial attempt confirmed the conflict. The pre-flight check ensures the working tree is clean before headless runs.

### --headless mode for fleet deployment

On unattended servers, nobody reads `git diff` output. Headless mode auto-restores repo versions immediately after adopt, preventing config contamination from unknown local files. A compromised file at the target would otherwise silently replace the known-good repo version.

### Sentinel file check for git-crypt detection

Checking whether encrypted packages are unlocked uses `grep -qI '' "$file"` on a known encrypted file. The `-I` flag treats binary files as non-matching, returning exit code 1 for locked (binary) files and 0 for unlocked (text) files. This completes in under 1ms and is POSIX-portable (no `file` command dependency). The alternative, `git-crypt status`, takes 200-500ms per invocation because it scans the entire repo.

### local package rejection

The `local` package contains `dot-Library` which `--dotfiles` converts to `.Library` instead of the intended `Library`. This is a fundamental limitation of the `dot-` prefix convention. The script rejects `local` with a message pointing to manual sub-package stowing instructions.

## Gotchas and Lessons Learned

### Do not run git-crypt status in pre-flight checks

`git-crypt status` scans every file in the repo against `.gitattributes` patterns. On this repo it takes 200-500ms. Use `grep -qI '' "$file"` on a single known-encrypted file instead — it returns exit code 1 for binary (locked) files and 0 for text (unlocked) files in under 1ms, with no dependency on the `file` command.

### Use `grep -qI` instead of `file` for binary detection

The `file` command is not installed on minimal Ubuntu server images and its output varies across platforms. The portable replacement is `grep -qI '' "$file"` — the `-I` flag treats binary files as non-matching, works on GNU grep (Linux) and BSD grep (macOS), and requires no output parsing. See `docs/solutions/deployment-issues/portable-binary-detection-sentinel-fix-and-auto-hooks.md` for full details.

### Temp files instead of arrays to avoid subshell variable loss

`cmd | while read` runs the loop body in a subshell. Any `array+=()` modifications inside the subshell are lost when the pipe finishes. This is a well-known bash pitfall. Using temp files (`mktemp`) to track state across loop iterations works on all bash versions and avoids the subshell boundary entirely.

```bash
# Wrong: adopted array is empty after the pipeline finishes
echo "$err" | while read -r line; do
  adopted+=("$pkg")  # lost -- subshell
done

# Correct: temp file persists across subshell boundaries
echo "$pkg" >> "$adopted_file"
```

### Use sed instead of grep -oP for POSIX portability

`grep -oP` (PCRE lookbehind) is a GNU grep extension. macOS ships BSD grep which does not support `-P`. The original script silently failed to detect symlink conflicts on macOS. Use `sed -n 's/pattern/replacement/p'` for portable extraction.

### Use -R (restow) for idempotency

`stow -S` fails on already-stowed packages because it sees its own symlinks as conflicts. `stow -R` unstows then re-stows, making the script safe for both first deployment and repeated re-runs.

### Interactive mode leaves adopted files for review

In interactive mode, adopted files remain in the working tree as uncommitted changes. The user sees a `git diff` and decides whether to keep local changes (`git add`) or discard them (`git checkout --`). This is intentional -- the user may want to incorporate machine-specific config into the repo.

## References

- Plan document: `docs/plans/2026-02-16-feat-stow-adopt-and-conflict-resolution-plan.md`
- Implementation: `scripts/stow-deploy`
- Related solution (cross-platform deployment): `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Related solution (headless git signing): `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- GNU Stow manual: <https://www.gnu.org/software/stow/manual/stow.html>
- Tree folding + dotfiles bug: <https://lists.gnu.org/archive/html/bug-stow/2019-09/msg00000.html>
