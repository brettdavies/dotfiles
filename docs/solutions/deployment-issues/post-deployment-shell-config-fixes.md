---
title: "Restore missing interactive shell configuration and migrate hardcoded secrets"
category: deployment-issues
tags: [shell-configuration, bashrc, zshrc, interactive-guard, secrets-management, credential-helpers, ssh-config, cross-platform]
module: shell/bash/zsh/git/ssh/secrets
symptom: "Stowed .bashrc critically minimal (23 lines vs 130+ in backup) missing interactive guards, history, completion, aliases, prompt, GPG_TTY; hardcoded secrets in .bashrc; missing git credential helpers; missing SSH pool entries"
root_cause: "Dotfiles repo .bashrc was developed on macOS where zsh is default, so bash config was minimal. When deployed to Ubuntu where bash is the fallback shell, the missing features became apparent. Secrets were in the old .bashrc rather than the centralized .secrets file."
date: 2026-02-15
---

# Restore missing interactive shell configuration and migrate hardcoded secrets

## Problem Symptom

After deploying dotfiles via GNU Stow from macOS to Ubuntu 24.04 (bigdaddy), a backup comparison (`~/.config-backup-20260215/`) revealed:

- The stowed `.bashrc` was only 23 lines, missing:
  - Interactive shell guard
  - History configuration (HISTCONTROL, histappend, HISTSIZE)
  - Bash completion
  - Colored prompt with debian_chroot support
  - lesspipe and dircolors (Linux-only)
  - Standard aliases (ll, la, l, color ls/grep)
  - GPG_TTY for commit signing
- The old `.bashrc` had secrets hardcoded (`OP_SERVICE_ACCOUNT_TOKEN`, `X_API_*` tokens)
- The stowed `.gitconfig` was missing `gh auth git-credential` helpers
- The stowed SSH config was missing `pool.tailscale` and `pool-lan` entries

## Root Cause

The dotfiles repo was developed on macOS where zsh is the default shell and oh-my-zsh handles all interactive features. The `.bashrc` was a minimal stub (source `.profile`, source shell-functions, OSC 7). When deployed to Ubuntu where bash is the fallback shell, the missing interactive features became apparent.

Additionally:

- Secrets were hardcoded in the old `.bashrc` instead of the centralized `~/.secrets` file
- The git credential helper used a hardcoded Linuxbrew path (`!/home/linuxbrew/.linuxbrew/bin/gh`) instead of bare `!gh`
- SSH pool entries for Tailscale and LAN access weren't in the repo

## Solution

### Architecture Decision

The key principle: `.profile` handles environment (all shells, all modes). RC files handle interactive features only.

```text
.profile (all shells, login + non-interactive)
├── config/shell/*.sh  (env vars, caches, telemetry, paths)
├── ~/.secrets          (tokens, API keys) -- BEFORE interactive guard
├── Homebrew shellenv
├── ~/.local/bin/env
├── ~/.cargo/env
└── GPG_TTY            (shared -- needed by both bash and zsh)

.bashrc (bash only)
├── source .profile (if not already loaded, via DOTFILES_SHELL_DIR sentinel)
├── INTERACTIVE GUARD (case $- in *i*) ;; *) return;; esac)
├── shell-functions, history, lesspipe, dircolors
├── prompt, aliases, bash completion
└── OSC 7

.zshrc (zsh only)
├── source .profile
├── INTERACTIVE GUARD ([[ $- == *i* ]] || return)  -- defense-in-depth
├── shell-functions, oh-my-zsh, history, modules
└── completions, p10k
```

### Changes Made

#### 1. Secrets migration (`stow/secrets/dot-secrets`)

Moved `OP_SERVICE_ACCOUNT_TOKEN` (hardcoded) and `X_API_*` tokens (via `op read`) from backup `.bashrc` to `~/.secrets`. This file is git-crypt encrypted and sourced by `.profile` before any interactive guard.

#### 2. Bash rewrite (`stow/bash/dot-bashrc`)

Rewrote from 23 to 82 lines:

```bash
# Source .profile if not already loaded
if [ -z "${DOTFILES_SHELL_DIR:-}" ] && [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# Interactive guard -- secrets/env already loaded via .profile above
case $- in
    *i*) ;;
      *) return;;
esac

# Below: shell-functions, history, lesspipe, dircolors, prompt, aliases,
# bash completion, OSC 7
```

The `DOTFILES_SHELL_DIR` sentinel prevents double-sourcing `.profile`. The `case $- in` pattern is POSIX-compatible (Ubuntu's default `/etc/skel/.bashrc` uses it).

#### 3. Zsh guard (`stow/zsh/dot-zshrc`)

Added 4 lines after `.profile` source:

```zsh
[[ $- == *i* ]] || return
```

This is defense-in-depth: zsh only sources `.zshrc` for interactive shells by design, but the guard provides an explicit contract and consistency with bash.

#### 4. Shared GPG_TTY (`stow/shell/dot-profile`)

Added at end of `.profile`:

```bash
export GPG_TTY=$(tty)
```

Previously missing from both shells. Placed in `.profile` so both bash and zsh get it without duplication.

#### 5. Git credential helpers (`stow/git/dot-gitconfig`)

```gitconfig
[credential "https://github.com"]
    helper =
    helper = !gh auth git-credential
[credential "https://gist.github.com"]
    helper =
    helper = !gh auth git-credential
```

The bare `!gh` (no absolute path) is the correct cross-platform pattern, confirmed by GitHub CLI maintainers (cli/cli#9438). The empty `helper =` resets the credential chain.

#### 6. SSH pool entries (`stow/ssh/dot-ssh/config`)

```ssh-config
Host pool.tailscale
    HostName pool
    User root
    Port 5922

Host pool-lan
    HostName 192.168.1.5
    User root
    Port 5922
```

`pool.tailscale` uses Tailscale MagicDNS. `pool-lan` provides explicit LAN fallback.

## Prevention Strategies

### 1. Post-deployment backup comparison

Always compare stowed files against the backup immediately after deployment:

```bash
diff ~/.config-backup-*/.bashrc ~/.bashrc
diff ~/.config-backup-*/.gitconfig ~/.gitconfig
diff ~/.config-backup-*/.ssh/config ~/.ssh/config
```

### 2. Secrets never in RC files

Secrets belong in `~/.secrets` (sourced by `.profile`), never in `.bashrc` or `.zshrc`. The git-crypt encryption on `stow/secrets/dot-secrets` ensures they're safe in the repo.

### 3. Test both shells before deployment

Before deploying to a new machine, verify both RC files work:

```bash
bash -n stow/bash/dot-bashrc    # Syntax check
zsh -n stow/zsh/dot-zshrc       # Syntax check
```

### 4. Verification commands after deployment

```bash
# Non-interactive secrets available
ssh host 'echo SECRETS=${OP_SERVICE_ACCOUNT_TOKEN:+SET}'

# Interactive bash features
ssh host 'bash -l -c "echo HIST=$HISTSIZE GPG=$GPG_TTY"'

# Git credential helper configured
ssh host 'git config --get-all credential.https://github.com.helper'

# SSH config resolves
ssh host 'ssh -G pool.tailscale | head -3'
```

## Cross-References

- Initial deployment solution: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Deployment plan: `docs/plans/2026-02-13-feat-deploy-dotfiles-to-bigdaddy-plan.md`
- Post-deployment fix plan: `docs/plans/2026-02-15-fix-shell-config-gaps-post-deployment-plan.md`
- Shell config chain: documented in project `CLAUDE.md` under "Shell Config Chain"
