---
title: "feat: Add gogcli stow package with shell wrapper"
type: feat
status: completed
date: 2026-04-01
---

# feat: Add gogcli stow package with shell wrapper

## Overview

Integrate gogcli (Google Workspace CLI) into the dotfiles repo as a proper stow package. The tool was installed and
configured manually — config files live unmanaged in `~/.config/gogcli/`, the shell wrapper is misplaced in `.zshrc`,
and the bootstrap script prints manual instructions instead of integrating with the established pattern.

## Problem Frame

New machines cannot reproduce the gogcli setup via `scripts/stow-deploy`. The `gog()` wrapper function lives in `.zshrc`
(interactive-only, zsh-only) instead of `config/shell/gogcli.sh` (all shells, all contexts). This violates the repo's
functions-not-aliases rule and means `gog` is unavailable in bash sessions, non-interactive SSH, and cron.

## Requirements Trace

- R1. gogcli config deployed via stow so `stow-deploy --all` sets up the tool
- R2. Shell wrapper function available in all shell contexts (zsh, bash, interactive, non-interactive)
- R3. Bootstrap script self-contained — pulls credentials from 1Password, no manual steps
- R4. Works on both Linux and macOS

## Scope Boundaries

- Not adding a personal-account setup to the bootstrap script (only Streams account today)
- Not adding systemd timers (gogcli has no background sync need)
- Not stow-managing the keyring directory (tokens are machine-specific, populated by bootstrap)

## Context & Research

### Relevant Code and Patterns

- `stow/caam/` — best precedent: config + shell wrapper + git-crypt encrypted vault data
- `config/shell/caam.sh` — CLI wrapper pattern with `command -v` guard and `command <binary>` delegation
- `stow/rclone/` — encrypted config via `.gitattributes` git-crypt rules
- `scripts/stow-deploy` line 23 — `SHARED_PACKAGES` array, line 99 — git-crypt prerequisite check
- `stow/zsh/dot-zshrc` lines 238-242 — misplaced `gog()` function to remove

### Institutional Learnings

- `docs/solutions/deployment-issues/stow-symlink-breakage-by-atomic-writers.md` — gogcli may rewrite `config.json` at
  runtime (it added `account_clients` after initial setup). Only stow-manage `config.json` if the content is stable;
  otherwise let the bootstrap script handle it
- `docs/solutions/best-practices/caam-claude-account-rotation-shell-integration.md` — shell functions in
  `config/shell/*.sh` beat aliases and PATH wrappers for all-context availability
- `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md` — use `$HOME`, gate platform-specific
  config behind `uname -s`

## Key Technical Decisions

- **No `.zshrc.d/` directory:** The todo's Option A mentioned `.zshrc.d/gogcli.zsh`. This repo does not use that
  pattern. Shell functions go in `config/shell/*.sh`, sourced by `.profile` via a glob loop. This is the established
  convention and provides cross-shell, cross-context availability. The `.zshrc.d/` idea is rejected.

- **Only stow `config.json`:** The `credentials.json`, `client_secret.json`, and `keyring/` files are machine-specific
  (populated by the bootstrap script from 1Password). Stow-managing them would require git-crypt encryption and would be
  fragile since gogcli may rewrite them. Only `config.json` (static backend selection) belongs in the stow package.

- **`config.json` content:** The live file has
  `{"keyring_backend":"file","account_clients":{"davies.brett@gmail.com":"personal"}}`. The `account_clients` key was
  added by gogcli at runtime. Since gogcli writes to this file, consider the atomic-write risk — if gogcli replaces the
  symlink, add an adopt-on-trigger in the shell wrapper (same pattern as caam).

- **1Password item name:** The wrapper currently uses `'Google Workspace CLI OAuth (Streams)'`. The `.zshrc` references
  this with `--fields client_secret`. Keep this as-is.

## Open Questions

### Resolved During Planning

- **Q: Where does the shell wrapper go?** → `config/shell/gogcli.sh`, sourced by `.profile`. Not `.zshrc.d/`, not
  `.zshrc`. This matches `caam.sh`, `github.sh`, and every other CLI wrapper in the repo.
- **Q: Should keyring files be stow-managed?** → No. They are machine-specific encrypted tokens populated by the
  bootstrap script. Stowing them adds git-crypt complexity for no portability gain.
- **Q: Does gogcli atomically write config.json?** → Yes, it added `account_clients` after initial setup. Add an
  adopt-back line in the shell wrapper, matching the caam pattern.

### Deferred to Implementation

- **Q: Does the personal account (`davies.brett@gmail.com`) need bootstrap support?** → Check if `setup_gogcli.sh`
  should handle multiple accounts. Out of scope for this plan but note for future.

## Implementation Units

- [x] **Unit 1: Create stow package and shell wrapper**

  **Goal:** Create the `stow/gogcli/` package with `config.json` and the `config/shell/gogcli.sh` wrapper function.

  **Requirements:** R1, R2

  **Dependencies:** None

  **Files:**
- Create: `stow/gogcli/dot-config/gogcli/config.json`
- Create: `config/shell/gogcli.sh`
- Modify: `stow/zsh/dot-zshrc` (remove `gog()` function, lines 238-242 and comment on 237)

  **Approach:**
- Seed `config.json` with base config only (`{"keyring_backend":"file"}`). The `account_clients` key is added by gogcli
  at runtime and will be captured by the adopt-back on next shell init. This keeps the repo state clean and diffs
  meaningful.
- Write `config/shell/gogcli.sh` following the `caam.sh` pattern: `command -v gog` guard, `gog()` function that exports
  `GOG_KEYRING_PASSWORD` then delegates via `command gog "$@"`
- Add adopt-back line after the function (same as caam pattern) since gogcli writes to `config.json`
- Remove the `gog()` block from `.zshrc`

  **Patterns to follow:**
- `config/shell/caam.sh` — wrapper function structure, `command -v` guard, adopt-back
- `stow/rclone/dot-config/rclone/rclone.conf` — config file in stow package

  **Test scenarios:**
- Happy path: `source config/shell/gogcli.sh` defines `gog` function when `gog` binary is on PATH
- Happy path: `gog` function calls through to real binary (`command gog`)
- Edge case: on a machine without `gog` installed, sourcing the file defines no function and produces no error
- Edge case: `GOG_KEYRING_PASSWORD` already set — function should not re-fetch from 1Password (the `${:-}` pattern)
- Integration: non-interactive SSH (`ssh localhost "type gog"`) shows `gog` as a function — verifies `.zshenv` →
  `.profile` → `config/shell/gogcli.sh` sourcing chain works for R2
- Integration: bash context (`bash -c 'source ~/.profile && type gog'`) confirms cross-shell availability

  **Verification:**
- `type gog` in a new shell shows it as a function
- `gog auth list` works (keyring password auto-injected)
- `.zshrc` no longer contains any `gog` reference

- [x] **Unit 2: Register package in stow-deploy**

  **Goal:** Add `gogcli` to `SHARED_PACKAGES` so `stow-deploy --all` deploys it.

  **Requirements:** R1, R4

  **Dependencies:** Unit 1

  **Files:**
- Modify: `scripts/stow-deploy` (add to `SHARED_PACKAGES` array)

  **Approach:**
- Add `gogcli` to the `SHARED_PACKAGES` array after `caam` (alphabetical is not enforced; group with other CLI tools)
- No git-crypt prerequisite needed since `config.json` is not encrypted
- No platform guard needed since gogcli works on both macOS and Linux

  **Patterns to follow:**
- Existing entries in `SHARED_PACKAGES` array at `scripts/stow-deploy` line 23

  **Test scenarios:**
- Happy path: `scripts/stow-deploy --all` includes gogcli in the deploy list
- Happy path: after deploy, `~/.config/gogcli/config.json` is a symlink to the stow source

  **Verification:**
- `ls -la ~/.config/gogcli/config.json` shows symlink to `dotfiles/stow/gogcli/dot-config/gogcli/config.json`
- `scripts/stow-deploy --all` completes without error

- [x] **Unit 3: Update bootstrap script**

  **Goal:** Remove the manual "add this to your shell profile" instruction from `setup_gogcli.sh` since the shell
  wrapper is now stow-managed.

  **Requirements:** R3

  **Dependencies:** Unit 1

  **Files:**
- Modify: `scripts/setup_gogcli.sh` (remove lines 55-60, the manual shell instruction)

  **Approach:**
- Remove the trailing echo block that tells the user to manually add the `gog()` function
- The script still handles credential population from 1Password — that stays
- Note: the script writes `config.json` with `{"keyring_backend":"file"}` but the live file has `account_clients` too.
  The stow-managed config.json is the source of truth for the base config; gogcli adds `account_clients` at runtime and
  the adopt-back captures it

  **Patterns to follow:**
- Other setup scripts in `scripts/` that are self-contained without manual follow-up steps

  **Test scenarios:**
- Happy path: running `setup_gogcli.sh` on a fresh machine populates credentials and completes without printing manual
  shell instructions

  **Verification:**
- Script output does not mention "Add this to your shell profile"

## System-Wide Impact

- **Interaction graph:** `.profile` sources `config/shell/gogcli.sh` via the glob loop — no new sourcing mechanism
  needed. The adopt-back runs on every shell init (lightweight, ~10ms).
- **State lifecycle risks:** gogcli may rewrite `config.json`, breaking the stow symlink. The adopt-back in the shell
  wrapper captures drift, matching the caam pattern.
- **Unchanged invariants:** No changes to stow-deploy's conflict resolution logic, git-crypt setup, or the
  `config/shell/*.sh` sourcing mechanism.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| gogcli rewrites config.json, breaking symlink | Adopt-back in shell wrapper (proven pattern from caam) |
| 1Password unavailable on some machines | `gog()` wrapper uses `${:-}` fallback — if op fails, password is empty and gog prompts or fails gracefully |
| config.json content drift between stow source and live | Adopt-back captures drift; periodic commits sync it |

## Sources & References

- Related todo: `.context/compound-engineering/todos/001-ready-p2-incorporate-gogcli.md`
- Pattern precedent: `config/shell/caam.sh`, `stow/caam/`
- Symlink breakage: `docs/solutions/deployment-issues/stow-symlink-breakage-by-atomic-writers.md`
- Shell wrapper best practices: `docs/solutions/best-practices/caam-claude-account-rotation-shell-integration.md`
