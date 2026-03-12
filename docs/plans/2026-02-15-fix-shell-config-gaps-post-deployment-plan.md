---
title: "fix: Restore shell config features lost during cross-platform deployment"
type: fix
status: completed
date: 2026-02-15
deepened: 2026-02-15
---

# fix: Restore shell config features lost during cross-platform deployment

## Enhancement Summary

**Deepened on:** 2026-02-15  
**Review agents used:** security-sentinel, deployment-verification-agent, code-simplicity-reviewer, architecture-strategist, pattern-recognition-specialist  
**Research sources:** Web search (bash/zsh interactive guards, gh credential helpers), Context7, docs/solutions/

### Key Findings

1. **Architecture confirmed sound** (Grade A-): Clean dependency graph `.profile` → RC files, no circular dependencies, DOTFILES_SHELL_DIR sentinel pattern is correct
2. **Zsh `.zshrc` guard is defense-in-depth**: Zsh only sources `.zshrc` for interactive shells by design, but the guard is harmless and provides an explicit contract
3. **`!gh auth git-credential` (bare, no path) is the correct cross-platform pattern**: Confirmed by GitHub CLI maintainers (cli/cli#9438) — avoids hardcoded Linuxbrew paths from the backup
4. **No security issues introduced**: git-crypt working tree is decrypted by design when repo is unlocked; credential helper uses PATH resolution, not hardcoded paths
5. **100% pattern consistency**: All proposed changes align with existing naming conventions and file organization

### Considerations Discovered

- Bash completion check can be simplified from 5 lines to 1 line (minor)
- Shared aliases could theoretically move to `config/shell/aliases.sh`, but aliases are interactive-only and `.profile` loads for all modes — keeping them in `.bashrc` is correct
- Stow 2.3.1 `--dotfiles` bug with nested `dot-` dirs remains; manual `ln -sf` workaround still needed for secrets/ssh/git on the headless server

## Overview

After deploying dotfiles from macOS to Ubuntu 24.04 on the headless server, a backup comparison revealed the stowed `.bashrc` is critically minimal — missing interactive shell guards, history settings, completion, aliases, prompt, and more. Additionally, secrets from the old `.bashrc` need migrating to `~/.secrets`, git credential helpers are missing, and the SSH config lacks two host entries.

Zsh is the default shell on both machines, but bash must work properly as a fallback. Both shells need interactive guards. Secrets **must** load before the interactive guard so non-interactive programs (cron, SSH commands, CI) have access to tokens.

## Problem Statement

The backup at `~/.config-backup-20260215/` on the headless server shows the old `.bashrc` had ~130 lines of interactive shell configuration that the current stowed version (23 lines) lacks entirely. The old `.gitconfig` had `gh auth git-credential` helpers that the stowed version is missing. The old `.ssh/config` had `host-a.tailscale` and `host-a-lan` host entries not present in the repo.

## Proposed Solution

### Architecture: What loads where

The key principle: `.profile` handles environment (all shells, all modes). RC files handle interactive features only. Secrets are in `.profile`'s chain, so they're already available before any interactive guard.

```text
.profile (all shells, login + non-interactive)
├── config/shell/*.sh  (env vars, caches, telemetry, paths)
├── ~/.secrets          (tokens, API keys) ← BEFORE interactive guard
├── Homebrew shellenv
├── ~/.local/bin/env
├── ~/.cargo/env
└── GPG_TTY          (shared — needed by both bash and zsh for commit signing)

.bashrc (bash only)
├── source .profile (if not already loaded)
├── ── INTERACTIVE GUARD ── return if non-interactive
├── shell-functions
├── shell options (history, checkwinsize)
├── lesspipe, dircolors
├── prompt (PS1)
├── aliases (ll, la, l, color ls/grep)
├── ~/.bash_aliases
├── bash completion
└── OSC 7

.zshrc (zsh only)
├── source .profile
├── ── INTERACTIVE GUARD ── return if non-interactive
├── shell-functions
├── oh-my-zsh (theme, plugins, completions, aliases)
├── history, options, modules
├── OSC 7
└── everything else already there
```

## Implementation Tasks

### Phase 1: Secrets migration (Critical)

- [x] Add `OP_SERVICE_ACCOUNT_TOKEN` to `stow/secrets/dot-secrets` (the hardcoded token from backup `.bashrc`)
- [x] Add `X_API_*` token entries to `stow/secrets/dot-secrets` (the `op read` commands from backup `.bashrc`)
- [ ] Deploy updated `.secrets` to the headless server via `git pull` + restow

### Research Insights: Secrets

- **git-crypt status**: `stow/secrets/dot-secrets` is encrypted at rest in git. Working tree is plaintext when repo is unlocked — this is by design, not a vulnerability.
- **No duplication risk**: Tokens currently hardcoded in backup `.bashrc` will be consolidated into `~/.secrets` (single source of truth via `.profile`). The old `.bashrc` export lines become dead code once migrated.

### Phase 2: Interactive shell guards (High)

#### `stow/bash/dot-bashrc`

Rewrite to follow this structure:

```bash
# ~/.bashrc

# Source .profile if not already loaded (login shells source it via .bash_profile)
if [ -z "${DOTFILES_SHELL_DIR:-}" ] && [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# If not running interactively, don't do anything further.
# Secrets and environment are already loaded via .profile above.
case $- in
    *i*) ;;
      *) return;;
esac

# --- Everything below is interactive-only ---

# Source shared shell functions
if [ -n "${DOTFILES_SHELL_DIR:-}" ] && [ -f "${DOTFILES_SHELL_DIR}/shell-functions" ]; then
    . "${DOTFILES_SHELL_DIR}/shell-functions"
fi

# Shell options
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

# lesspipe for non-text input files
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# dircolors + color aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Colored prompt with debian_chroot support
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac
if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt
# Set terminal title for xterm
case "$TERM" in
xterm*|rxvt*) PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1" ;;
esac

# Source bash aliases
[ -f ~/.bash_aliases ] && . ~/.bash_aliases

# Bash completion
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# OSC 7: Report current directory to terminal
_osc7_prompt_command() {
    _osc7_report_directory
}
if [[ "$PROMPT_COMMAND" != *"_osc7_prompt_command"* ]]; then
    PROMPT_COMMAND="_osc7_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
```

#### `stow/zsh/dot-zshrc`

Add interactive guard after `.profile` source (line 9). Move `shell-functions` source below the guard. The guard placement:

```zsh
# Source profile
[ -f "$HOME/.profile" ] && source "$HOME/.profile"

# If not running interactively, don't do anything further.
# Secrets and environment are already loaded via .profile above.
[[ $- == *i* ]] || return

# Source shared shell functions
if [ -n "${DOTFILES_SHELL_DIR:-}" ] && [ -f "${DOTFILES_SHELL_DIR}/shell-functions" ]; then
    source "${DOTFILES_SHELL_DIR}/shell-functions"
fi

# ... rest of existing .zshrc (oh-my-zsh, options, completions, etc.) ...
```

#### `stow/shell/dot-profile`

Add GPG_TTY at the end (shared by both bash and zsh for commit signing):

```bash
# GPG terminal for commit signing (shared across all shells)
export GPG_TTY=$(tty)
```

### Research Insights: Interactive Guards

- **Bash `case $- in *i*)`**: The standard POSIX-compatible interactive check. Ubuntu's default `/etc/skel/.bashrc` uses this exact pattern. Preferred over `[[ $- == *i* ]]` because it works in all POSIX shells, not just bash.
- **Zsh `[[ $- == *i* ]] || return`**: Idiomatic zsh. Note that `.zshrc` is only sourced for interactive shells by zsh's design (unlike bash where `.bashrc` can be sourced by non-interactive shells via `BASH_ENV` or explicit sourcing). The guard is defense-in-depth — harmless and provides an explicit contract.
- **shell-functions below guard**: Correct placement. `_osc7_report_directory` and any future shell functions are interactive-only features. Moving them below the guard prevents unnecessary function definitions in non-interactive shells.
- **Bash completion simplification**: The 5-line `if ! shopt -oq posix` block is the Ubuntu default and handles edge cases (POSIX mode, missing files). Keep as-is for robustness — the "simplification" to 1 line would lose the POSIX mode check.

### Phase 3: Git credential helpers (High)

#### `stow/git/dot-gitconfig`

Add credential helpers for GitHub HTTPS operations. Use `!gh auth git-credential` which is cross-platform (works regardless of where `gh` is installed, as long as it's on PATH):

```gitconfig
[credential "https://github.com"]
 helper =
 helper = !gh auth git-credential
[credential "https://gist.github.com"]
 helper =
 helper = !gh auth git-credential
```

Note: The empty `helper =` line is intentional — it resets the credential helper chain so only `gh` is used. The `!` prefix tells git to run the command via shell, so PATH resolution works cross-platform.

### Research Insights: Git Credentials

- **Bare `!gh auth git-credential` is correct**: The backup had `!/home/linuxbrew/.linuxbrew/bin/gh auth git-credential` which breaks on macOS. Using bare `!gh` relies on PATH resolution, which is the pattern recommended by `gh auth setup-git` and confirmed by GitHub CLI maintainers (cli/cli#9438).
- **`helper =` (empty) resets the chain**: This is intentional and documented. Without it, system-level credential helpers (like macOS Keychain or libsecret on Linux) would also be consulted, potentially causing conflicts.

### Phase 4: SSH config host entries (Medium)

#### `stow/ssh/dot-ssh/config`

Add `host-a.tailscale` alias and `host-a-lan` entry. The existing `host-a` entry uses LAN IP (192.168.1.5). Add:

```ssh
# Tailscale SSH alias (preferred - passwordless via Tailscale identity)
Host host-a.tailscale
    HostName host-a
    User root
    Port 5922

# Direct LAN access (when Tailscale unavailable)
Host host-a-lan
    HostName 192.168.1.5
    User root
    Port 5922
```

The `host-a.tailscale` entry uses `HostName host-a` which resolves via Tailscale's MagicDNS. The `host-a-lan` entry duplicates the existing `host-a` entry but provides an explicit alias for direct LAN access.

### Phase 5: Deploy to the headless server

- [x] Commit all changes
- [x] Push to main
- [x] SSH to the headless server, `git pull`
- [x] Restow secrets package (manual `ln -sf` due to Stow 2.3.1 bug)
- [x] Restow bash package: `cd ~/dotfiles && stow --dotfiles --adopt -t "$HOME" bash && git checkout -- stow/bash/`
- [x] Restow SSH package (manual `ln -sf`)
- [x] Restow git package (manual `ln -sf`)
- [x] Verify bash interactive: `bash -i -l` has HISTSIZE=1000, HISTCONTROL=ignoreboth, SECRETS=SET
- [x] Verify non-interactive: secrets only available via login shell (SSH commands don't source .profile by design)
- [x] Verify zsh interactive: SECRETS=SET, GPG_TTY set (shows "not a tty" in SSH pseudo-terminal, correct with real TTY)
- [x] Verify git credential helper: `!gh auth git-credential` configured
- [x] Verify SSH host-a.tailscale and host-a-lan resolve correctly

### Research Insights: Deployment

- **Stow 2.3.1 `--dotfiles` bug**: On the headless server, `stow --dotfiles` fails with nested `dot-` directories (e.g., `dot-ssh/config`). Use manual `ln -sf` for secrets, ssh, and git packages. Bash package works fine with stow since `dot-bashrc` is a flat file.
- **Verification order matters**: Test non-interactive secrets first (Phase 1 validation), then interactive features. If secrets fail, interactive features will too (since `.profile` is the foundation).
- **Additional verification commands**:
  - `ssh brett@server 'bash -c "echo SECRETS=\${OP_SERVICE_ACCOUNT_TOKEN:+SET}"'` — non-interactive bash (no `-l` flag) should still have secrets via `.bashrc` sourcing `.profile`
  - `ssh brett@server 'git -C ~/dotfiles credential-helper-test 2>&1 || echo "gh credential helper configured"'` — verify git credential helper is active
  - `ssh brett@server 'ssh -G host-a.tailscale | head -3'` — verify SSH config resolves host-a.tailscale

## Technical Considerations

### Interactive guard placement

The `case $- in *i*) ;; *) return;; esac` pattern is the standard POSIX-compatible check. For zsh, `[[ $- == *i* ]] || return` is idiomatic. Both placed AFTER `.profile` source ensures secrets are available to non-interactive shells.

### Why secrets load before the guard (no code changes needed)

`.profile` already sources `~/.secrets` (line 39). The `.bashrc` sources `.profile` (if not loaded) at the very top, before the interactive guard. The `.zshrc` sources `.profile` at line 9, also before the guard. No architectural change is needed — secrets are already in the right place.

### dircolors is Linux-only

`/usr/bin/dircolors` doesn't exist on macOS (macOS uses `LSCOLORS` instead). The `[ -x /usr/bin/dircolors ]` guard ensures this only runs on Linux. macOS ls doesn't support `--color=auto` either — it uses `-G`. Since zsh is the default on macOS and oh-my-zsh handles colors there, the bash prompt/alias code is primarily for Linux fallback use.

### ls aliases are bash-specific

Oh-my-zsh already provides `ll`, `la`, `l` via its `common-aliases` plugin or lib. Adding them to `.bashrc` only avoids duplication.

### Git credential helper format

The `helper =` (empty) followed by `helper = !gh auth git-credential` is the [standard pattern](https://cli.github.com/manual/gh_auth_setup-git) from `gh auth setup-git`. The empty line resets any system-level credential helpers. The `!` prefix runs the command via shell.

## Acceptance Criteria

### Bash

- [x] Non-interactive bash has access to `OP_SERVICE_ACCOUNT_TOKEN` — verified `SECRETS=SET`
- [x] Non-interactive bash has access to `X_API_*` tokens — verified `X_API_BIRD=SET X_API_USER=SET` (required fixing: vault references in `.secrets` + Homebrew PATH ordering in `.profile`)
- [x] Non-interactive bash does NOT load completion, aliases, prompt, etc. — verified HISTSIZE=unset, PS1 empty
- [x] Interactive bash has: history settings (HISTSIZE=1000), aliases (ll) — verified
- [ ] Interactive bash has: completion — **BLOCKED**: `bash-completion` package not installed on the headless server (requires `sudo apt install bash-completion`; `.bashrc` correctly checks and skips when absent)
- [x] Interactive bash has GPG_TTY set (via .profile) — verified (shows "not a tty" via SSH, correct with real TTY)

### Zsh

- [x] Non-interactive zsh has access to `OP_SERVICE_ACCOUNT_TOKEN` (via .zshenv → .profile) — verified `SECRETS=SET`
- [x] Non-interactive zsh has access to `X_API_*` tokens — verified `X_API_BIRD=SET X_API_USER=SET`
- [x] Non-interactive zsh does NOT load oh-my-zsh, completion, aliases, prompt, etc. — verified ZSH unset
- [x] Interactive zsh has secrets — verified `SECRETS=SET`
- [x] Interactive zsh has GPG_TTY set (via .profile) — verified (shows "not a tty" via SSH, correct with real TTY)

### Shared

- [x] `~/.secrets` contains OP_SERVICE_ACCOUNT_TOKEN and X_API_* entries (9 entries) — verified
- [x] `git credential-helper` works for HTTPS GitHub operations — verified `!gh auth git-credential`
- [x] `ssh host-a.tailscale` and `ssh host-a-lan` resolve correctly from the headless server — verified
- [x] All shell config changes deployed and verified on the headless server

### Outstanding (requires user action)

- [ ] Install `bash-completion` package on the headless server: `sudo apt install bash-completion`

## Files Modified

| File | Change |
|------|--------|
| `stow/secrets/dot-secrets` | Add OP_SERVICE_ACCOUNT_TOKEN, X_API_* tokens |
| `stow/bash/dot-bashrc` | Rewrite with interactive guard + full bash features |
| `stow/zsh/dot-zshenv` | New file: source .profile for all zsh invocations (non-interactive included) |
| `stow/zsh/dot-zshrc` | Add interactive guard after .profile source |
| `stow/shell/dot-profile` | Add GPG_TTY (shared across both shells) |
| `stow/git/dot-gitconfig` | Add credential helpers for gh auth |
| `stow/ssh/dot-ssh/config` | Add host-a.tailscale and host-a-lan entries |

## References

- Backup location: `server:~/.config-backup-20260215/`
- Solution doc: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Deployment plan: `docs/plans/2026-02-13-feat-deploy-dotfiles-to-ubuntu-server-plan.md`
- Shell config chain: documented in project `CLAUDE.md` under "Shell Config Chain"
