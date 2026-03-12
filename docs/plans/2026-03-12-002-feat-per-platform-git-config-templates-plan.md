---
title: "feat: per-platform git config templates via stow-deploy"
type: feat
status: completed
date: 2026-03-12
deepened: 2026-03-12
---

# feat: per-platform git config templates via stow-deploy

## Enhancement Summary

**Deepened on:** 2026-03-12
**Sections enhanced:** 4 (solution, technical considerations, risks, implementation)
**Research agents used:** git-cliff best practices, code simplicity, architecture strategy, spec flow analysis

### Key Improvements

1. **Linux-only for now** — macOS template deferred until macOS-specific overrides are needed
2. **Inline heredoc vs file template** — two valid approaches documented with trade-offs; inline is simpler, file is
   more extensible
3. **Bug fixes in code snippet** — `$platform` typo, non-fatal `cp`, tree-fold guard added
4. **`includeIf` alternative researched** — `gitdir:/Users/` vs `gitdir:/home/` works but only inside repos, not
   global context; copy step is still needed
5. **Editor migration IN scope** — `core.editor` moves from shared gitconfig to Linux template (macOS may want a
   different editor)

### New Considerations Discovered

- Git expands `~` in include paths but NOT `$HOME`
- Empty git config files (comments only) are silently ignored
- `includeIf` has no `onOS` condition — only `gitdir`, `onbranch`, `hasconfig:remote.*.url:`
- Copy-if-absent creates template drift on long-lived servers (documented as known limitation)

## Overview

Automate the creation of `~/.config/git/local` on Linux servers during `stow-deploy`. This eliminates a manual step
documented in `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`.

## Problem Statement / Motivation

The shared `.gitconfig` includes `[include] path = ~/.config/git/local` for per-host overrides, but `local` is created
manually on each machine. On headless Linux servers, forgetting to create this file means git signing fails (the shared
gitconfig uses a literal public key that requires an SSH agent, which headless servers don't have).

Currently:

- macOS: works without `local` (1Password SSH agent handles signing) — no overrides needed
- Headless Linux: requires manually creating `local` with `user.signingkey = ~/.ssh/brett_ed25519` for direct-file
  signing

This manual step violates the "fully automated, no manual steps" deployment requirement from CLAUDE.md.

## Alternative Approaches Considered

### `includeIf` with `gitdir:` path prefixes (rejected)

Git's `includeIf` supports `gitdir:` conditions that could detect platform by home directory path:

```gitconfig
[includeIf "gitdir:/Users/"]
    path = ~/.config/git/macos
[includeIf "gitdir:/home/"]
    path = ~/.config/git/linux
```

**Why rejected:** `gitdir:` only evaluates inside a git repository context. Global git operations (like
`git config --global --list`) don't have a `.git` directory, so the conditions are never evaluated. Also, repos in
`/tmp/`, `/opt/`, or `/srv/` would not match. The signing key must be available everywhere, not just in repos under
`$HOME`.

**References:**
[git-scm.com/docs/git-config#_includes](https://git-scm.com/docs/git-config#_includes),
[Platform-Specific .gitconfig's and the Wonderful includeIf][medium-includeif]

[medium-includeif]: https://medium.com/doing-things-right/platform-specific-gitconfigs-and-the-wonderful-includeif-7376cd44994d

### Inline heredoc in stow-deploy (viable alternative)

The Linux template is only 3 lines of content. It could be inlined as a heredoc directly in `stow-deploy`:

```bash
if [ ! -f "$_local_cfg" ] && [ "$(uname -s)" = "Linux" ]; then
    cat > "$_local_cfg" <<'GITLOCAL'
# Linux git overrides — deployed by stow-deploy
# To update: delete this file and re-run stow-deploy
[user]
    signingkey = ~/.ssh/brett_ed25519
GITLOCAL
fi
```

**Trade-offs:** Eliminates the `config/git/` directory and template files entirely (~8 lines total, one file changed).
But the template content is buried in deployment logic rather than being a separately reviewable config file. If more
platforms or more overrides are added later, inline heredocs scale poorly.

**Recommendation:** Start with the file-based approach. The `config/git/` directory establishes a pattern for future
per-platform configs (not just git). If it proves to be over-engineering, collapsing to inline is trivial.

## Proposed Solution

### 1. `config/git/local.linux`

A single template file in `config/git/` (peer to existing `config/shell/`). Named to match `uname -s` output
(lowercased) for direct platform-to-filename mapping.

```gitconfig
# Linux git overrides — deployed by stow-deploy
# To update: delete this file and re-run stow-deploy
#
# Signing key: private key file path enables ssh-keygen direct
# signing without an SSH agent (required for headless servers).
[user]
    signingkey = ~/.ssh/brett_ed25519
[core]
    editor = micro
```

No macOS template is created yet — macOS works without overrides (1Password SSH agent handles signing with the literal
public key in the shared `.gitconfig`). Git silently ignores a missing `[include]` target, so no file = no overrides =
correct behavior. A `config/git/local.darwin` can be added when macOS-specific overrides are needed (e.g., a different
default editor).

### 1b. Remove `[core] editor` from shared `.gitconfig`

Since the editor preference differs per platform, it belongs in the per-platform template, not the shared config. Remove
the `[core] editor = micro` line added earlier in this session from `stow/git/dot-gitconfig`. macOS will use git's
default editor (or whatever is set in `$EDITOR` from `.profile`) until a `local.darwin` template is created.

### 2. `stow-deploy` post-stow step

Add a git config template deployment step in the post-stow validation section (after SSH validation, around line 358).
Only runs if the `git` package was successfully deployed.

```bash
# Git local config: deploy platform-specific template if absent
if grep -qx "git" "$deployed_file" 2>/dev/null; then
  echo ""
  echo "==> Checking git local config"
  _local_cfg="$TARGET/.config/git/local"
  _platform=$(uname -s | tr '[:upper:]' '[:lower:]')
  _template="$REPO_ROOT/config/git/local.$_platform"

  if [ -L "$TARGET/.config/git" ]; then
    echo "  WARNING: ~/.config/git is tree-folded (symlink), skipping template" >&2
  elif [ -f "$_local_cfg" ]; then
    echo "  Git local config exists, skipping template deploy"
  elif [ -f "$_template" ]; then
    if cp "$_template" "$_local_cfg"; then
      echo "  Deployed git local config from local.$_platform"
    else
      echo "  WARNING: Failed to deploy git config template" >&2
    fi
  else
    echo "  No git config template for $_platform (not needed)"
  fi
fi
```

#### Research Insights: stow-deploy code

**Bug fixes from spec flow analysis:**

- `$platform` → `$_platform` (typo in original snippet)
- `cp` wrapped in conditional (non-fatal, matches SSH validation pattern at `stow-deploy:346-357`)
- Tree-fold guard added (`[ -L ... ]` check prevents writing into a symlinked directory, which would pollute the repo)
- "No template" is informational, not a warning (macOS intentionally has no template)

**Error handling:** The script uses `set -euo pipefail`. A bare `cp` failure would abort the entire script after all
packages are already deployed. The conditional wrapper ensures template failure is non-fatal, matching the precedent set
by SSH validation (`if ! ssh -G ... ; then echo WARNING`).

**Ordering dependency:** The template copy MUST follow the stow deploy phase because `~/.config/git/` is created by
stowing the `git` package. The tree-fold resolution (pre-deploy) ensures it is a real directory, not a symlink.

**`grep` usage:** The plan uses `grep -qx` (not `rg`) because `stow-deploy` runs on headless servers where `rg` may
not be installed. This is consistent with existing `grep` usage in the script (lines 102, 260, 273, 343).

### 3. Documentation update

Update `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md` prevention section to note that
`stow-deploy` now automates the `local` file creation. This is the one doc that directly tells users to "manually create
`~/.config/git/local`" — that instruction becomes incorrect after this change.

README and CLAUDE.md updates are disproportionate to the change size. The README's Repository Layout can be updated
if/when `config/git/` grows beyond one file.

## Technical Considerations

- **`~/.config/git/` exists after stowing `git` package**: the directory contains stow-managed symlinks (`ignore`,
  `allowed_signers`). Since `--no-folding` is always used, it's a real directory — a plain `local` file coexists
  safely.
- **git `[include]` is position-sensitive**: `local` is included LAST in `.gitconfig`, so its values override everything
  above. This is already the case and requires no changes.
- **`~` expands in git include paths, `$HOME` does not**: the existing `path = ~/.config/git/local` is correct. Never
  use `$HOME` in git config include paths.
- **Empty/missing config files are safe**: git silently ignores a missing include target and correctly parses files with
  only comments. No macOS template needed.
- **`--adopt` does not affect `local`**: `local` is not part of the stow package (`stow/git/` has no
  `dot-config/git/local`), so stow never conflicts with it. The plain file coexists with stow-managed symlinks.

### Template drift (known limitation)

Copy-if-absent means template updates do NOT propagate to machines that already have a `local` file. This is acceptable
because:

1. The Linux template content (`user.signingkey` path) is unlikely to change
2. All Linux servers currently need identical overrides
3. If a template update is needed, the deployed file includes instructions: "To update: delete this file and re-run
   stow-deploy"

A `--refresh-config` flag could be added later if template evolution becomes frequent. For now, this is documented as a
known limitation, not an unsolved problem.

## Acceptance Criteria

- [x] `config/git/local.linux` exists with `user.signingkey` and `core.editor` overrides for headless Linux
- [x] `[core] editor = micro` removed from shared `stow/git/dot-gitconfig`
- [x] `stow-deploy` copies the template to `~/.config/git/local` on Linux when deploying `git`
- [x] Existing `~/.config/git/local` is NOT overwritten
- [x] Tree-folded `~/.config/git` is detected and skipped with a warning
- [x] `cp` failure is non-fatal (warning, not script abort)
- [x] On macOS (no template), informational message printed (not a warning)
- [x] Solution doc updated to reference automated deployment
- [x] One assertion added to existing integration test: `~/.config/git/local` exists after `--all` on Linux

## Dependencies & Risks

**Dependencies:**

- `git` package must be stowed before template copy (directory must exist) — guaranteed by execution order in
  `stow-deploy`
- Template must be committed to the repo before first deploy

**Risks:**

- **Low**: copy-if-absent means existing manual `local` files on bigdaddy are preserved. First deploy on a fresh
  machine gets the template automatically.
- **Low**: template drift on long-lived servers (see known limitation above). Mitigated by stable template content and
  in-file update instructions.
- **Low**: if someone adds settings to `local.linux` template that conflict with the shared gitconfig, the template wins
  (last-include-wins). This is the intended behavior.

## Implementation Order

1. Create `config/git/local.linux` (signingkey + editor)
2. Remove `[core] editor = micro` from shared `.gitconfig`
3. Add post-stow template deployment to `stow-deploy`
4. Add one assertion to existing integration test
5. Update solution doc

## Sources & References

- **Signing architecture**:
  `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- **Cross-platform deployment**:
  `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- **stow-deploy patterns**:
  `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md`
- **Existing `[include]`**: `stow/git/dot-gitconfig:24-28`
- **Post-stow validation**: `scripts/stow-deploy:330-358`
- **Platform detection**: `scripts/stow-deploy:47-53`
- **Git include docs**:
  [git-scm.com/docs/git-config#_includes](https://git-scm.com/docs/git-config#_includes)
- **Git config precedence**:
  [git-scm.com/docs/git-config](https://git-scm.com/docs/git-config) (last-value-wins within a file, `[include]`
  inserted at declaration point)
