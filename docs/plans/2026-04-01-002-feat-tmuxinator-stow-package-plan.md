---
title: "feat: Add tmuxinator stow package for declarative tmux session management"
type: feat
status: completed
date: 2026-04-01
completed: 2026-04-01
pr: brettdavies/dotfiles#28
release: 2026.04.01
---

## Post-ship notes (2026-04-01)

Shipped in [PR #28](https://github.com/brettdavies/dotfiles/pull/28) as part of release
[`2026.04.01`](https://github.com/brettdavies/dotfiles/releases/tag/2026.04.01). All three implementation units landed:
`stow/tmuxinator/` package with 13 session YAML configs, `config/shell/tmuxinator.sh` (`mux` / `mux-all` functions),
`scripts/stow-deploy` `SHARED_PACKAGES` registration, and BOOTSTRAP.md / README.md updates including the TPM bootstrap
section.

# feat: Add tmuxinator stow package for declarative tmux session management

## Overview

Add tmuxinator to the dotfiles so tmux sessions are declaratively defined in YAML configs, stowed via GNU Stow, and
reproducible on any machine. Includes shell convenience functions (`mux`, `mux-all`) and TPM bootstrap documentation.

## Problem Frame

A reboot wiped all tmux sessions. Resurrect/continuum handle session persistence between reboots, but they don't help
when bootstrapping a new machine or recovering from a clean slate. Tmuxinator provides a declarative layer on top: YAML
files define the session shape, and the same configs work on any machine.

## Requirements Trace

- R1. Install tmuxinator via Homebrew
- R2. Create a tmuxinator YAML config for each of the 13 sessions with correct working directories
- R3. Stow the configs at `~/.config/tmuxinator/` following dot-prefix conventions
- R4. Add `tmuxinator` to `SHARED_PACKAGES` in `scripts/stow-deploy`
- R5. Provide `mux` and `mux-all` shell functions for tmuxinator
- R6. Document TPM bootstrap (git clone + install_plugins) in BOOTSTRAP.md
- R7. Update BOOTSTRAP.md manual stow examples to include tmuxinator

## Scope Boundaries

- No complex multi-window/multi-pane layouts — each session is one window, one pane
- No tmuxinator completion setup (tmuxinator ships its own)
- No changes to tmux.conf or plugin configuration
- No automation script for TPM — just manual instructions in BOOTSTRAP.md

## Context & Research

### Relevant Code and Patterns

- **Stow package pattern:** `stow/<name>/dot-config/<name>/` — see `stow/tmux/dot-config/tmux/tmux.conf`,
  `stow/lazygit/dot-config/lazygit/`, `stow/rclone/dot-config/rclone/`
- **Shell functions location:** `config/shell/*.sh` — sourced by `.profile` under POSIX sh, must use functions not
  aliases (per CLAUDE.md)
- **Aliases location:** `stow/zsh/dot-zshrc` — after interactive guard, zsh-only aliases live here
- **`SHARED_PACKAGES` array:** `scripts/stow-deploy` line 23 — ordered list, tmuxinator logically follows tmux
- **BOOTSTRAP.md:** Manual stow examples at lines 77-85 list all packages — must be updated when adding a new shared
  package

### Session Directory Mapping

| Session      | Root Directory                                                            |
| ------------ | ------------------------------------------------------------------------- |
| agentnative  | `~/dev/agentnative`                                                       |
| bird         | `~/dev/bird`                                                              |
| dot-github   | `~/dev/dot-github`                                                        |
| dotfiles     | `~/dotfiles`                                                              |
| homebrewcore | `/home/linuxbrew/.linuxbrew/Homebrew/Library/Taps/homebrew/homebrew-core` |
| homebrewtap  | `~/dev/homebrew-tap`                                                      |
| openclaw     | `~/dev/openclaw`                                                          |
| payg         | `~/dev/payg`                                                              |
| skills       | `~/.claude/skills`                                                        |
| solutions    | `~/dev/solutions-docs`                                                    |
| streams      | `~/box/TX-AI/streams-control`                                             |
| vault        | `~/obsidian-vault`                                                        |
| xurl-rs      | `~/dev/xurl-rs`                                                           |

Note: `homebrewcore` path is Linux-specific (Linuxbrew tap location). On macOS this would be
`/opt/homebrew/Library/Taps/homebrew/homebrew-core`. The Linuxbrew path is hardcoded (see Key Technical Decisions).
Tmuxinator handles missing roots gracefully — it falls back to `$HOME` with a warning.

## Key Technical Decisions

- **Functions in `config/shell/`, not aliases in `.zshrc`:** `config/shell/*.sh` is sourced by `.profile` (shared by
  bash and zsh). Functions are more portable than aliases and can accept arguments. This follows the established
  convention used by `caam.sh`, `gogcli.sh`, and other shell helpers.
- **One config file per session:** Each YAML is a separate file in `stow/tmuxinator/dot-config/tmuxinator/`. This
  matches tmuxinator's default project layout and keeps configs independently manageable.
- **Minimal YAML:** Each config has only `name`, `root`, and one window with a single pane. No startup commands, no
  complex layouts — tmuxinator is just the session bootstrapper, not a workflow orchestrator.
- **`homebrewcore` uses platform conditional root:** The Linuxbrew path is hardcoded since this is a Linux-focused
  dotfiles deployment. If cross-platform support is needed later, tmuxinator supports ERB in YAML for conditional paths.
- **TPM bootstrap in BOOTSTRAP.md only:** No new script. The existing pattern is documentation-driven bootstrap
  (BOOTSTRAP.md), and TPM is a one-time clone + run.

## Open Questions

### Resolved During Planning

- **Where do `mux`/`mux-all` go?** → `config/shell/tmuxinator.sh`, sourced by `.profile` (POSIX functions).
- **Does tmuxinator handle missing root dirs?** → Yes, it falls back to `$HOME` with a warning. No guard needed.
- **XDG config path for tmuxinator?** → `~/.config/tmuxinator/` (default when `XDG_CONFIG_HOME` is unset).

### Deferred to Implementation

- **Tmuxinator completions:** Tmuxinator ships zsh completions. Whether to wire them up can be decided after testing.

## Implementation Units

- [ ] **Unit 1: Install tmuxinator and create stow package with YAML configs**

**Goal:** Install tmuxinator, create all 13 session YAML configs in a new stow package, deploy via stow, and verify.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**

- Create: `stow/tmuxinator/dot-config/tmuxinator/agentnative.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/bird.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/dot-github.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/dotfiles.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/homebrewcore.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/homebrewtap.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/openclaw.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/payg.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/skills.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/solutions.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/streams.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/vault.yml`
- Create: `stow/tmuxinator/dot-config/tmuxinator/xurl-rs.yml`
- Modify: `scripts/stow-deploy` (add `tmuxinator` to `SHARED_PACKAGES`)
- Modify: `stow/brew/Brewfile` (add `brew "tmux"` and `brew "tmuxinator"`)

**Approach:**

- `brew install tmuxinator` and add both `brew "tmux"` and `brew "tmuxinator"` to `stow/brew/Brewfile` so new machines
  get the full tmux stack via `brew bundle`
- Create `stow/tmuxinator/dot-config/tmuxinator/` directory
- Each YAML follows the minimal pattern: `name`, `root`, one `windows` entry with a single pane
- Add `tmuxinator` to `SHARED_PACKAGES` after `tmux` (logical ordering)
- Run `scripts/stow-deploy tmuxinator` to deploy
- Test with `tmuxinator start dotfiles`, verify session exists, then `tmux kill-server`

**Patterns to follow:**

- `stow/lazygit/dot-config/lazygit/` for XDG stow structure
- Existing `SHARED_PACKAGES` ordering in `scripts/stow-deploy`

**Test scenarios:**

- Happy path: `tmuxinator start dotfiles` creates a tmux session named "dotfiles" rooted at `~/dotfiles`
- Happy path: `tmuxinator list` shows all 13 projects
- Edge case: `tmuxinator start homebrewcore` works even if the Linuxbrew path doesn't exist (falls back to `$HOME`)
- Happy path: After `scripts/stow-deploy tmuxinator`, all YAML files are symlinked in `~/.config/tmuxinator/`

**Verification:**

- `ls -la ~/.config/tmuxinator/*.yml` shows 13 symlinks pointing into the stow package
- `tmuxinator start dotfiles` and `tmux ls` shows the session
- `tmuxinator list` shows all 13 project names

- [ ] **Unit 2: Add `mux` and `mux-all` shell functions**

**Goal:** Provide short convenience functions for tmuxinator usage.

**Requirements:** R5

**Dependencies:** Unit 1

**Files:**

- Create: `config/shell/tmuxinator.sh`

**Approach:**

- `mux()` wraps `tmuxinator` — passes all arguments through
- `mux-all()` loops through YAML files in `~/.config/tmuxinator/`, extracts project names, starts each one
- Both are POSIX-compatible functions (sourced by `.profile`)
- `mux-all` should start sessions detached to avoid blocking, then attach to the last one or print a summary
- Wrap both functions in a `command -v tmuxinator` guard, matching the pattern in `caam.sh` and `gogcli.sh`

**Patterns to follow:**

- `config/shell/caam.sh` — function-based shell helpers sourced by `.profile`
- `config/shell/gogcli.sh` — simple wrapper functions

**Test scenarios:**

- Happy path: `mux start dotfiles` starts the dotfiles session (passthrough to tmuxinator)
- Happy path: `mux-all` starts all 13 sessions detached, prints summary of started sessions
- Edge case: `mux-all` when some sessions already exist — tmuxinator should skip or warn, not fail

**Verification:**

- After sourcing `.profile`, `type mux` shows a function definition
- `mux list` output matches `tmuxinator list`
- `mux-all` starts multiple sessions visible in `tmux ls`

- [ ] **Unit 3: Update BOOTSTRAP.md with tmux/tmuxinator bootstrap steps**

**Goal:** Document TPM installation and include tmuxinator in the stow package lists.

**Requirements:** R6, R7

**Dependencies:** Unit 1

**Files:**

- Modify: `BOOTSTRAP.md`
- Modify: `README.md` (add tmuxinator to stow package table and config/shell table)

**Approach:**

- Add a "Tmux Plugins" section after "oh-my-zsh" with: `git clone` TPM, `~/.tmux/plugins/tpm/scripts/install_plugins.sh`
- Update the manual stow examples (macOS shared + desktop, headless shared) to include `tmuxinator` after `tmux`
- Add `tmuxinator` row to README.md stow package table and `tmuxinator.sh` to the config/shell table

**Patterns to follow:**

- Existing BOOTSTRAP.md section structure (heading, code block, optional note)

**Test scenarios:**

- Test expectation: none — documentation-only change

**Verification:**

- BOOTSTRAP.md contains TPM clone command and install_plugins reference
- Both manual stow command examples include `tmuxinator`

## Risks & Dependencies

| Risk                                                                                    | Mitigation                                                                                                                                                                            |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `homebrewcore` path is Linux-specific                                                   | tmuxinator handles missing roots gracefully (falls back to $HOME with warning). Cross-platform ERB can be added later if needed.                                                      |
| tmuxinator Ruby gem may conflict with system Ruby                                       | Installed via Homebrew which manages its own Ruby — no conflict expected.                                                                                                             |
| tmuxinator in SHARED_PACKAGES deploys Ruby dependency (~100MB+) to all headless servers | Acceptable: headless servers already have Homebrew and the YAML configs are tiny. The Ruby dependency is only pulled if `brew bundle` is run. Revisit if footprint becomes a concern. |

## Sources & References

- Related code: `stow/tmux/dot-config/tmux/tmux.conf` (existing tmux config with TPM)
- Related code: `scripts/stow-deploy` (package deployment)
- Related code: `config/shell/caam.sh` (shell function pattern)
- Related code: `BOOTSTRAP.md` (bootstrap documentation)
