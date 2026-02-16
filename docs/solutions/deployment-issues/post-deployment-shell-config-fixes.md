---
title: "Restore missing shell configuration and fix non-interactive zsh environment"
category: deployment-issues
tags: [shell-configuration, bashrc, zshrc, zshenv, interactive-guard, secrets-management, credential-helpers, ssh-config, cross-platform, non-interactive-shell]
module: shell/bash/zsh/git/ssh/secrets
symptom: "Stowed .bashrc critically minimal (23 lines vs 130+); no .zshenv so non-interactive zsh had zero environment; hardcoded secrets in .bashrc; missing git credential helpers; missing SSH pool entries"
root_cause: "Dotfiles repo was developed on macOS where zsh is default, so bash config was minimal. No .zshenv existed, so non-interactive zsh (SSH commands, cron) had no access to secrets or environment. Secrets were in old .bashrc rather than centralized .secrets file."
date: 2026-02-15
---

# Restore missing shell configuration and fix non-interactive zsh environment

## Problem Symptom

After deploying dotfiles via GNU Stow from macOS to Ubuntu 24.04 (bigdaddy), two categories of problems emerged:

**Found via backup comparison (`~/.config-backup-20260215/`):**

- The stowed `.bashrc` was only 23 lines, missing interactive shell guard, history, completion, aliases, prompt, GPG_TTY
- The old `.bashrc` had secrets hardcoded (`OP_SERVICE_ACCOUNT_TOKEN`, `X_API_*` tokens)
- The stowed `.gitconfig` was missing `gh auth git-credential` helpers
- The stowed SSH config was missing `pool.tailscale` and `pool-lan` entries

**Found via post-deployment verification:**

- Non-interactive zsh had **zero environment** — `ssh host 'echo SECRETS=${OP_SERVICE_ACCOUNT_TOKEN:+SET}'` returned empty
- No `.zshenv` existed, so non-interactive zsh sessions (SSH commands, cron jobs) never sourced `.profile`

## Root Cause

### Missing bash features

The dotfiles repo was developed on macOS where zsh is the default shell and oh-my-zsh handles all interactive features. The `.bashrc` was a minimal stub. When deployed to Ubuntu where bash is the fallback shell, the missing interactive features became apparent.

### Non-interactive zsh had no environment (the critical bug)

Zsh has a strict startup file hierarchy that differs fundamentally from bash. Understanding this hierarchy is essential for cross-platform dotfiles:

| File | When sourced | Bash equivalent |
|------|-------------|-----------------|
| `.zshenv` | **ALL zsh invocations** (interactive, non-interactive, login, non-login) | No equivalent (bash has no file sourced for all invocations) |
| `.zprofile` | Login shells only | `.bash_profile` / `.profile` |
| `.zshrc` | Interactive shells only | `.bashrc` |
| `.zlogin` | Login shells only (after `.zshrc`) | No equivalent |
| `.zlogout` | Login shell exit | `.bash_logout` |

**The critical difference:** Bash has a special case where it sources `.bashrc` when invoked by sshd (remote shell daemon), even for non-interactive commands. **Zsh has no such special case.** For non-interactive `zsh -c 'command'` (which is what sshd runs when zsh is the default shell), **only `.zshenv` is sourced.**

Without `.zshenv`, non-interactive zsh gets:

- No `$PATH` modifications
- No environment variables
- No secrets
- No Homebrew
- Nothing

### What SSH commands actually run

When you run `ssh host 'command'`, sshd executes:

```text
$SHELL -c 'command'
```

If the user's default shell is zsh, this becomes `zsh -c 'command'` — a non-interactive, non-login shell. Only `.zshenv` is sourced.

If the user's default shell is bash, this becomes `bash -c 'command'` — normally nothing is sourced, BUT bash has a special case: when it detects it's invoked by sshd (via `$SSH_CLIENT`/`$SSH_CONNECTION`), it sources `.bashrc`.

## Solution

### Architecture

```text
.profile (environment for all shells, all modes)
├── config/shell/*.sh  (env vars, caches, telemetry, paths)
├── Homebrew shellenv   ← MUST come before ~/.secrets (op CLI needs PATH)
├── ~/.secrets          (tokens, API keys — uses `op read` from Homebrew)
├── ~/.local/bin/env
├── ~/.cargo/env
└── GPG_TTY

.zshenv (ALL zsh invocations — the non-interactive entry point)
└── source .profile (if not already loaded, via DOTFILES_SHELL_DIR sentinel)

.bashrc (bash — interactive + sshd special case)
├── source .profile (if not already loaded)
├── INTERACTIVE GUARD (case $- in *i*) ;; *) return;; esac)
├── shell-functions, history, lesspipe, dircolors
├── prompt, aliases, bash completion
└── OSC 7

.zshrc (zsh — interactive only)
├── source .profile (redundant with .zshenv, but sentinel guard makes it safe)
├── INTERACTIVE GUARD ([[ $- == *i* ]] || return)
├── shell-functions, oh-my-zsh, history, modules
└── completions, p10k
```

### Changes Made

#### 1. Non-interactive zsh fix (`stow/zsh/dot-zshenv`) — NEW FILE

```bash
# ~/.zshenv - sourced by ALL zsh invocations (interactive + non-interactive)
# Ensures secrets and environment are available to SSH commands, cron, etc.
if [ -z "${DOTFILES_SHELL_DIR:-}" ] && [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
```

The `DOTFILES_SHELL_DIR` sentinel prevents double-sourcing when `.zshrc` also sources `.profile` for interactive sessions.

#### 2. PATH ordering fix (`stow/shell/dot-profile`)

Moved Homebrew/Linuxbrew `shellenv` setup **before** `~/.secrets` sourcing. The `~/.secrets` file uses `op read` (1Password CLI) which is installed via Homebrew. With the original ordering, `op` wasn't on PATH when `.secrets` was sourced, so all `$(op read ... 2>/dev/null)` commands failed silently and X_API_* tokens were empty.

**Rule:** Any tool used inside `.secrets` (or any file sourced by `.profile`) must have its PATH set up earlier in `.profile`.

#### 3. Secrets migration (`stow/secrets/dot-secrets`)

Moved `OP_SERVICE_ACCOUNT_TOKEN` (hardcoded) and `X_API_*` tokens (via `op read`) from backup `.bashrc` to `~/.secrets`. This file is git-crypt encrypted and sourced by `.profile` before any interactive guard.

#### 4. Bash rewrite (`stow/bash/dot-bashrc`)

Rewrote from 23 to 82 lines:

```bash
# Source .profile if not already loaded
if [ -z "${DOTFILES_SHELL_DIR:-}" ] && [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# Interactive guard — secrets/env already loaded via .profile above
case $- in
    *i*) ;;
      *) return;;
esac

# Below: shell-functions, history, lesspipe, dircolors, prompt, aliases,
# bash completion, OSC 7
```

#### 5. Zsh interactive guard (`stow/zsh/dot-zshrc`)

Added after `.profile` source:

```zsh
[[ $- == *i* ]] || return
```

Defense-in-depth: zsh only sources `.zshrc` for interactive shells by design, but the guard provides an explicit contract.

#### 6. Shared GPG_TTY (`stow/shell/dot-profile`)

```bash
export GPG_TTY=$(tty)
```

Placed in `.profile` so both bash and zsh get it without duplication.

#### 7. Git credential helpers (`stow/git/dot-gitconfig`)

```gitconfig
[credential "https://github.com"]
    helper =
    helper = !gh auth git-credential
[credential "https://gist.github.com"]
    helper =
    helper = !gh auth git-credential
```

Bare `!gh` (no absolute path) is the correct cross-platform pattern (cli/cli#9438). The empty `helper =` resets the credential chain.

#### 8. SSH pool entries (`stow/ssh/dot-ssh/config`)

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

## Prevention Strategies

### 1. Always test non-interactive shells for BOTH bash and zsh

The most important verification after any shell config change:

```bash
# Non-interactive zsh (what SSH commands actually run)
ssh host 'echo SECRETS=${OP_SERVICE_ACCOUNT_TOKEN:+SET}'

# Non-interactive bash
ssh host 'bash -c "echo SECRETS=\${OP_SERVICE_ACCOUNT_TOKEN:+SET}"'

# Interactive bash
ssh host 'bash -i -l -c "echo HIST=\$HISTSIZE"'

# Interactive zsh
ssh -t host 'zsh -i -c "echo SECRETS=\${OP_SERVICE_ACCOUNT_TOKEN:+SET}"'
```

These tests are **binary pass/fail**. If `SECRETS=` is empty, the test failed. Do not rationalize the failure.

### 2. AC tests are binary — never rationalize a failure

When an acceptance test fails, the only valid responses are:

| Scenario | Action |
|----------|--------|
| Implementation is wrong | Fix the implementation, re-run the test |
| Test is wrong | Fix the test, document why, re-run |
| Unexpected limitation | Document as a constraint, do not mark AC complete |

**Never:** "The test failed, but this is expected behavior, so AC is complete." A failed test that gets rationalized away is more dangerous than having no test at all — it creates a false sense of safety.

### 3. Post-deployment backup comparison

```bash
diff ~/.config-backup-*/.bashrc ~/.bashrc
diff ~/.config-backup-*/.gitconfig ~/.gitconfig
diff ~/.config-backup-*/.ssh/config ~/.ssh/config
```

### 4. Secrets never in RC files

Secrets belong in `~/.secrets` (sourced by `.profile`), never in `.bashrc` or `.zshrc`.

### 5. PATH before secrets — sourcing order in `.profile` matters

`.profile` is sourced top-to-bottom. If `~/.secrets` uses CLI tools (like `op read`), those tools must be on PATH before `.secrets` is sourced. The correct order:

1. `config/shell/*.sh` (env vars, constants)
2. Homebrew/Linuxbrew `shellenv` (adds `op`, `gh`, etc. to PATH)
3. `~/.secrets` (can now use `op read`)
4. `~/.local/bin/env`, `~/.cargo/env`

Symptom of getting this wrong: variables set via `$(command 2>/dev/null)` are silently empty. The `2>/dev/null` hides the "command not found" error.

### 6. Syntax check before deployment

```bash
bash -n stow/bash/dot-bashrc
zsh -n stow/zsh/dot-zshrc
zsh -n stow/zsh/dot-zshenv
```

## Zsh vs Bash Startup File Reference

This table should be consulted whenever modifying shell configuration:

| Need | Bash location | Zsh location | Why |
|------|--------------|-------------|-----|
| Environment for ALL invocations | `.bashrc` (sshd special case) + `.bash_profile` (login) | **`.zshenv`** | Only file zsh sources for non-interactive |
| Secrets, PATH, Homebrew | `.profile` (sourced by `.bashrc` and `.bash_profile`) | `.profile` (sourced by `.zshenv`) | Single source of truth |
| Interactive features (prompt, aliases, completion) | `.bashrc` (after interactive guard) | `.zshrc` | Only needed for interactive use |
| Login-only setup | `.bash_profile` | `.zprofile` | Rarely needed |

**Rule:** If it must work in `ssh host 'command'` with zsh as default shell, it **must** be reachable from `.zshenv`.

## Cross-References

- Initial deployment solution: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Deployment plan: `docs/plans/2026-02-13-feat-deploy-dotfiles-to-bigdaddy-plan.md`
- Post-deployment fix plan: `docs/plans/2026-02-15-fix-shell-config-gaps-post-deployment-plan.md`
- Shell config chain: documented in project `CLAUDE.md` under "Shell Config Chain"
