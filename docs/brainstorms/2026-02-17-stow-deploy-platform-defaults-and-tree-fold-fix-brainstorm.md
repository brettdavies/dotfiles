# Stow Deploy: Platform Defaults, Tree-Fold Fix, and Local Package Split

**Date:** 2026-02-17 **Status:** closed (shipped) **Trigger:** Claude Code `PostToolUse:Edit hook error` on headless
Ubuntu server -- `~/.claude/auto-format.sh` missing because `claude` package was never in the Ubuntu deployment list.

## What We're Building

Four changes to `scripts/stow-deploy`, one package restructure, and one corrective action on macOS:

1. **`--all` flag** -- Auto-detects platform (`uname -s`) and expands to the correct package set. Shared packages deploy
   everywhere; desktop-only packages (`ghostty`, `cursor`, `launchagent`) only on macOS.

2. **Tree-fold detection** -- Pre-flight check that identifies directory-level symlinks pointing into `stow/`. Resolves
   them by moving runtime data to a real directory, removing the symlink, then re-stowing with `--no-folding`. Includes
   Claude Code process detection (abort if running, since it writes to `~/.claude/` constantly).

3. **Split `local` package** -- The current `local` package is rejected by stow-deploy because `dot-Library` conflicts
   with `--dotfiles` (converts to `.Library` instead of `Library`). Split into:

- `local` -- `dot-local/bin/env` and `dot-local/bin/op-ssh-sign-wrapper` (shared, all platforms)
- `launchagent` -- `Library/LaunchAgents/com.user.devtosync.plist` (macOS desktop-only, no `dot-` prefix needed since
     `~/Library` doesn't start with a dot)

1. **Repo cleanup** -- After un-tree-folding, `git clean` untracked runtime files from the repo's
   `stow/claude/dot-claude/` directory.

2. **Fix this Mac** -- Re-stow the four tree-folded packages (`claude`, `codex`, `git`, `opencode`) to eliminate 311 MB
   of runtime data living inside the git repo.

## Why This Approach

### Root cause chain

1. Original stow (2025-11-18) ran without `--no-folding` -> four packages tree-folded
2. `stow-deploy` (2026-02-17) added `--no-folding` but never re-stowed existing packages
3. `stow-deploy` deployment plan used a minimal Ubuntu list (only `shell bash git ssh secrets`)
4. Claude Code writes runtime data into `~/.claude/` -> physically lands in git repo via tree-fold
5. `.gitignore` masks the problem but doesn't solve it (311 MB, 9,083 files in working tree)
6. Headless server deployed with minimal list -> `claude` package missing -> hook references nonexistent script -> error
7. `local` package excluded from deployment entirely due to `dot-Library` conflict -> `op-ssh-sign-wrapper` missing on
   headless servers -> git signing broken

### Why `--all` instead of keeping stow-deploy "dumb"

- The package list is deployment knowledge that belongs with the deployment tool, not scattered across docs
- Prevents the macOS/Ubuntu list divergence from recurring
- Explicit packages still work for targeted restows (`stow-deploy git ssh`)
- Platform detection is trivial (`uname -s` -> `Darwin` vs `Linux`)

### Why tree-fold detection in stow-deploy

- Tree-folding is a stow-specific foot-gun that `stow-deploy` already mitigates with `--no-folding`
- Detection + resolution in pre-flight means future runs self-heal existing broken state
- No separate fixup script to maintain

### Why split `local` instead of special-casing it

- The `dot-Library` conflict is a stow `--dotfiles` limitation, not a package design issue
- `Library/` (no `dot-` prefix) works with `stow --dotfiles` since there's nothing to convert
- Eliminates all special-case rejection logic and README instructions for `local`
- `op-ssh-sign-wrapper` is critical on ALL machines (git signing) -- it must be in `--all`

## Key Decisions

| Decision              | Choice                                 | Rationale                                                    |
| --------------------- | -------------------------------------- | ------------------------------------------------------------ |
| Package list location | In `stow-deploy` script                | Single source of truth; docs reference the flag, not a list  |
| Platform detection    | `uname -s` auto-detect                 | Simpler than `--platform` flag; no user input needed         |
| Tree-fold resolution  | Move data, remove symlink, re-stow     | Preserves runtime data (session history, caches)             |
| Desktop-only packages | `ghostty`, `cursor`, `launchagent`     | GUI apps + macOS LaunchAgent; everything else works headless |
| Fix scope on this Mac | All four tree-folded packages          | `claude` (311 MB), `codex`, `git`, `opencode`                |
| Runtime data handling | Move to real `~/.claude/` (not delete) | Preserves session history and plugin state                   |
| `local` package       | Split into `local` + `launchagent`     | Eliminates `dot-Library` conflict; `local` joins `--all`     |
| Repo cleanup          | `git clean` after un-tree-folding      | Script cleans untracked files from stow package dirs         |
| Claude Code safety    | Detect running process, abort          | Prevents data corruption during `~/.claude` migration        |

## Package Sets

**Shared (all platforms):**

```text
secrets shell zsh bash git ssh gh local claude codex opencode pip brew
```

**Desktop-only (macOS):**

```text
ghostty cursor launchagent
```

No packages are excluded from `--all`. The old `local` rejection is eliminated by the package split.

## Tree-Fold Detection Logic

Pre-flight, before any stowing:

```text
For each package to be stowed:
  Compute expected target dir (e.g., ~/.claude for claude, ~/.config/git for git)
  If target is a symlink AND points into stow/:
    1. Check for running processes that write to that dir (e.g., Claude Code for ~/.claude)
    2. Create real target directory (temp name to avoid conflict)
    3. Move ALL contents from symlink target to real directory
    4. Remove the directory-level symlink
    5. Rename temp dir to final target name
    6. git clean untracked files from the stow package dir
    7. Continue to normal stow (which creates per-file symlinks)
```

### Current tree-folded state on macOS

| Symlink              | Points to                                       | Runtime data              |
| -------------------- | ----------------------------------------------- | ------------------------- |
| `~/.claude`          | `dotfiles/stow/claude/dot-claude`               | 9,083 files, 311 MB       |
| `~/.codex`           | `dotfiles/stow/codex/dot-codex`                 | 20 files, 132 KB          |
| `~/.config/git`      | `../dotfiles/stow/git/dot-config/git`           | 2 tracked files, low risk |
| `~/.config/opencode` | `../dotfiles/stow/opencode/dot-config/opencode` | 1 tracked file, low risk  |

## Package Split: `local` -> `local` + `launchagent`

### Before

```text
stow/local/
  dot-local/bin/env
  dot-local/bin/op-ssh-sign-wrapper
  dot-Library/LaunchAgents/com.user.devtosync.plist
```

Problem: `stow --dotfiles` converts `dot-Library` to `.Library` (wrong). Package rejected by stow-deploy entirely.
`op-ssh-sign-wrapper` never deployed to headless servers.

### After

```text
stow/local/
  dot-local/bin/env
  dot-local/bin/op-ssh-sign-wrapper

stow/launchagent/
  Library/LaunchAgents/com.user.devtosync.plist
```

`local` works with `--dotfiles` (only `dot-local` needs conversion). `launchagent` works with `--dotfiles` (no `dot-`
prefix on `Library`, so nothing to convert). Both are normal packages with no special handling.

## Open Questions

*None -- all questions resolved during brainstorming.*

## Resolved Questions

- **Scope:** Fix both tree-folding and deployment lists (not one or the other)
- **Runtime data:** Move to real directories, don't delete
- **stow-deploy design:** Add `--all` flag with auto-detection (not `--platform`, not no-args default)
- **Other packages:** Fix all four tree-folded packages, not just claude
- **Tree-fold guard:** Add detection to stow-deploy pre-flight (not a separate script)
- **Repo cleanup:** Script runs `git clean` on package dirs after un-tree-folding
- **Platform list storage:** Hardcoded arrays in stow-deploy (not marker files)
- **Claude Code safety:** Script detects running Claude Code process and aborts
- **`local` package:** Split into `local` (shared) + `launchagent` (macOS desktop-only)
- **`local` in tree-fold detection:** Not needed -- `local` was never tree-folded, and fresh VMs with `--no-folding`
  won't tree-fold it

## Next Steps

1. `/workflows:plan` to design the implementation
2. Split `local` package into `local` + `launchagent`
3. Implement `--all` flag, tree-fold detection, and `local` rejection removal in `stow-deploy`
4. Run `stow-deploy --all` on this Mac to fix tree-folded packages
5. Update README, CLAUDE.md, and solution docs
6. Deploy to headless servers with `stow-deploy --headless --all`
