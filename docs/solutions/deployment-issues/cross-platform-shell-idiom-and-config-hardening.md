---
title: "Cross-platform shell idiom and config hardening (second-wave portability fixes)"
category: deployment-issues
tags:
  - cross-platform
  - shell
  - linux
  - macos
  - stat
  - sed
  - ssh
  - homebrew
  - git-signing
  - stow-deploy
module: scripts/stow-deploy, stow/shell, stow/git, stow/ssh, stow/brew, stow/claude
symptom: >
  Shell scripts and configs used macOS-only tool flags (stat -f, bc -l, bare tty) and
  single-platform assumptions (Brewfile formulae, 1Password socket, shared gitconfig)
  that silently failed or errored on headless Ubuntu servers
root_cause: >
  BSD vs GNU tool incompatibilities (stat, sed, bc), missing non-interactive guards (tty),
  and shared configs lacking per-platform overrides (git signing key, Brewfile,
  SSH agent socket existence check)
date: 2026-03-12
severity: high
---

# Cross-Platform Shell Idiom and Config Hardening

## Problem

After the initial cross-platform deployment of this dotfiles repository (macOS development
machine plus headless Ubuntu servers), a "second wave" of portability failures emerged.
These were not outright missing files or broken symlinks -- they were subtle tool
incompatibilities where commands that work perfectly on macOS silently fail, produce wrong
output, or crash on Linux.

The failures manifested as: `stat` errors when checking cache file ages, `bc` not found
when computing context window percentages, `tty` crashing in non-interactive SSH sessions,
`sed` behaving differently between BSD and GNU implementations, Brewfile warnings about
macOS-only formulae, and the 1Password SSH agent being activated on Linux even when the
socket does not exist.

Because these scripts run automatically on login, in status lines, and during deployment,
failures were often silent (swallowed by stderr redirects) or intermittent (only triggered
in non-interactive contexts like `ssh host 'command'` or cron).

## Root Cause

macOS and Linux ship different implementations of core utilities that share the same
command name but accept incompatible flags:

- **`stat`**: macOS (BSD) uses `-f %m` for modification time; GNU/Linux uses `-c %Y`.
  There is no shared flag syntax.
- **`bc`**: Available on macOS by default, but not always installed on minimal Ubuntu
  server images. Shell arithmetic (`$(( ))`) handles integer comparisons without an
  external dependency.
- **`sed`**: BSD sed (macOS) and GNU sed (Linux) differ in `-i` flag syntax and some regex
  extensions. Parameter expansion can replace simple `sed` substitutions entirely.
- **`tty`**: Returns error exit code when there is no controlling terminal (non-interactive
  SSH, cron). On macOS this rarely matters because sessions are interactive; on headless
  servers, `.profile` is sourced by non-interactive zsh via `.zshenv`.
- **Brewfile**: Homebrew's `brew bundle` on Linux silently skips casks but emits confusing
  warnings for formulae that don't exist in the Linux tap.
- **SSH agent sockets**: The 1Password agent path exists on macOS unconditionally (installed
  with the desktop app) but on Linux the socket only exists if the CLI agent is running.
- **Git config**: Signing on Linux requires the private key *file path* (for
  `ssh-keygen -Y sign`), while macOS uses the 1Password literal public key (for
  `op-ssh-sign`). A single `.gitconfig` cannot serve both without a per-platform override.

## Solution

### 1. Per-platform git config templates

The deploy script (`scripts/stow-deploy`) now has a post-stow step that copies
platform-specific git config templates. On Linux, `config/git/local.linux` is deployed
to `~/.config/git/local` (copy-if-absent), providing the signing key file path override:

```ini
# config/git/local.linux
[user]
    signingkey = ~/.ssh/brett_ed25519
```

Editor configuration is handled separately via `$EDITOR` env var set platform-aware in
`.profile` and referenced by `core.editor = $EDITOR` in `.gitconfig`. See
[cross-platform editor configuration](../configuration-fixes/cross-platform-editor-configuration-via-editor-env-var.md).

The stow-deploy logic includes a tree-fold guard (skips if `~/.config/git` is a symlink
rather than a directory) and respects existing configs:

```bash
if [ -L "$TARGET/.config/git" ]; then
    echo "  WARNING: ~/.config/git is tree-folded (symlink), skipping template" >&2
elif [ -f "$_local_cfg" ]; then
    echo "  Git local config exists, skipping template deploy"
elif [ -f "$_template" ]; then
    cp "$_template" "$_local_cfg"
fi
```

### 2. Cross-platform `stat` with fallback chain

The macOS-only `stat -f %m` was replaced with a try-macOS-then-Linux-then-zero pattern:

```bash
# Before
mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)

# After
mtime=$(stat -f %m "$cache_file" 2>/dev/null \
     || stat -c %Y "$cache_file" 2>/dev/null \
     || echo 0)
```

### 3. Eliminating `bc` dependency with shell arithmetic

Floating-point percentage comparisons that depended on `bc -l` were replaced by truncating
to integer and using shell `[ -ge ]`:

```bash
# Before
if [ "$(echo "$context_remaining_pct >= 70" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then

# After
pct_int=${context_remaining_pct%.*}
pct_int=${pct_int:-0}
if [ "$pct_int" -ge 70 ]; then
```

### 4. Replacing `sed` with parameter expansion

A `sed` call to replace `$HOME` with `~` was replaced with a POSIX parameter expansion
that avoids the BSD/GNU `sed` divergence entirely:

```bash
# Before
current_dir=$(echo "$cwd" | sed "s|^${HOME}|~|")

# After
current_dir="${cwd/#"$HOME"/\~}"
```

### 5. Guarding `tty` in non-interactive shells

The `tty` command fails when there is no controlling terminal. In `.profile` (sourced by
`.zshenv` for non-interactive SSH), this caused errors:

```bash
# Before
GPG_TTY=$(tty)

# After
GPG_TTY=$(tty 2>/dev/null) || true
```

### 6. Brewfile `OS.mac?` guards

Homebrew's Brewfile supports Ruby conditionals. macOS-only formulae now use `if OS.mac?`
instead of relying on silent skip behavior:

```ruby
# Before
brew "terminal-notifier"
brew "gromgit/brewtils/taproom"

# After
brew "terminal-notifier" if OS.mac?
brew "gromgit/brewtils/taproom" if OS.mac?
```

### 7. SSH config socket existence check

The Linux 1Password agent `Match` directive now also verifies the socket exists before
activating, preventing SSH failures on servers without the agent:

```ssh-config
# Before
Match host * exec "test $(uname -s) = Linux"
  IdentityAgent ~/.1password/agent.sock

# After
Match host * exec "test $(uname -s) = Linux && test -S $HOME/.1password/agent.sock"
  IdentityAgent ~/.1password/agent.sock
```

### 8. macOS path guards in shell config

Unconditional macOS-only PATH entries were wrapped with platform checks:

```bash
# Before (zprofile)
export PATH="$PATH:/Applications/Obsidian.app/Contents/MacOS"

# After
if [ "$(uname -s)" = "Darwin" ]; then
    export PATH="$PATH:/Applications/Obsidian.app/Contents/MacOS"
fi
```

The `hbash` alias now has a Linuxbrew fallback:

```bash
if [ -f /opt/homebrew/bin/bash ]; then
    alias hbash='/opt/homebrew/bin/bash'
elif [ -f /home/linuxbrew/.linuxbrew/bin/bash ]; then
    alias hbash='/home/linuxbrew/.linuxbrew/bin/bash'
fi
```

### 9. `tmux` added to shared packages

The `tmux` stow package was added to `SHARED_PACKAGES` in `stow-deploy`, ensuring tmux
configuration is deployed to all machines (macOS and headless Linux).

## Portable Shell Patterns Quick Reference

| macOS (BSD) Idiom | Problem on Linux | Portable Replacement |
|---|---|---|
| `stat -f %m file` | GNU stat uses `-c`, not `-f` | `stat -f %m file 2>/dev/null \|\| stat -c %Y file 2>/dev/null \|\| echo 0` |
| `echo "expr" \| bc -l` | `bc` not installed on minimal servers | `pct=${val%.*}; [ "$pct" -ge N ]` (integer truncation + shell arithmetic) |
| `sed "s\|pat\|rep\|"` | Works, but `-i` flag diverges between BSD/GNU | `${var/#"pattern"/replacement}` (parameter expansion, no external tool) |
| `GPG_TTY=$(tty)` | Exit code 1 in non-interactive shells | `GPG_TTY=$(tty 2>/dev/null) \|\| true` |
| `/Applications/Foo.app/...` in PATH | Path does not exist on Linux | `if [ "$(uname -s)" = "Darwin" ]; then ... fi` |
| `/opt/homebrew/bin/tool` | Path does not exist on Linux | Add `elif [ -f /home/linuxbrew/.linuxbrew/bin/tool ]` fallback |
| `brew "macos-formula"` | Warning: formula not found on Linux | `brew "formula" if OS.mac?` (Ruby conditional) |
| SSH `IdentityAgent /path/to/sock` | Agent socket may not exist | `Match ... exec "test -S $HOME/.1password/agent.sock"` |
| Shared `.gitconfig` values | Wrong signing key format on Linux | `config/git/local.<platform>` template via stow-deploy (signing key); `$EDITOR` env var via `.profile` (editor) |

## Prevention Strategies

### Pre-commit checklist for shell scripts

- Search for BSD-only flags: `rg 'stat -f|sed -i ""' stow/ scripts/`
- Never assume a command exists on minimal Linux -- guard with `command -v` or provide
  a fallback
- Gate 1Password references on socket existence, not just platform
- Prefer shell arithmetic and parameter expansion over external tools (`bc`, `sed`)
- Avoid `tty` in any code path reachable from non-interactive contexts -- guard with
  `2>/dev/null || true` or `[[ -t 0 ]]`
- Audit Brewfile changes for Linux compatibility -- use `if OS.mac?` for macOS-only
  formulae

### Testing recommendations

- **bats-core tests** (existing in `tests/`): Add assertions that grep for unguarded
  BSD-only patterns (`stat -f`, bare `tty`, `bc -l`) and fail if found outside platform
  guards
- **shellcheck in CI**: `shellcheck -x -s bash scripts/* stow/shell/config/shell/*.sh`
  catches many BSD/GNU portability issues
- **Docker smoke test**: A minimal Ubuntu 24.04 container (no `bc`, no `tty`, no coreutils
  extras) running `stow-deploy --headless --all` followed by
  `zsh -c 'source ~/.zshenv && env'` would catch missing-tool assumptions before they
  reach production

## Cross-References

### Related solutions

- [`cross-platform-stow-dotfiles-deployment.md`](cross-platform-stow-dotfiles-deployment.md)
  -- First-wave deployment issues (SSH config, git signing, hardcoded paths, Stow 2.3.x
  bug). This document is the direct sequel.
- [`headless-linux-git-signing-and-hook-guards.md`](headless-linux-git-signing-and-hook-guards.md)
  -- `op-ssh-sign-wrapper` fallback, `command -v` hook guards, cross-platform trust model
- [`post-deployment-shell-config-fixes.md`](post-deployment-shell-config-fixes.md)
  -- `.zshenv` for non-interactive zsh, `GPG_TTY=$(tty)` in `.profile`, shell config chain
- [`portable-binary-detection-sentinel-fix-and-auto-hooks.md`](portable-binary-detection-sentinel-fix-and-auto-hooks.md)
  -- `grep -qI` replacing non-portable `file` command in hooks
- [`stow-conflict-resolution-wrapper.md`](stow-conflict-resolution-wrapper.md)
  -- `sed` over `grep -oP` portability fix (BSD grep lacks `-P`)

### Related plans

- `docs/plans/2026-03-12-002-feat-per-platform-git-config-templates-plan.md` -- Per-platform
  `~/.config/git/local` generation (direct input to this work)
- `docs/plans/2026-02-16-fix-bigdaddy-cross-platform-signing-and-hooks-plan.md` -- Flagged
  `session-context.sh` `stat -f %m` as follow-up (resolved here)

### GitHub references

| Reference | Context |
|-----------|---------|
| PR #21 | `feat(deploy): per-platform git config templates and cross-platform hardening` |
| PRs #7-#9 | Portable binary detection, sentinel fix, auto hooks (first-wave) |
| PR #12 | `stow-deploy` platform defaults and tree-fold resolution |
