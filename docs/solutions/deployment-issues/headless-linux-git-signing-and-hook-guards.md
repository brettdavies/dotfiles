---
title: Headless Linux git signing and Claude Code hook guards
category: deployment-issues
tags:
  - git-signing
  - ssh-keygen
  - 1password
  - cross-platform
  - claude-code
  - hooks
module: dotfiles deployment
symptom: "op-ssh-sign not found" on git commit, "terminal-notifier not found" and "bd prime not found" hook errors on headless Linux
root_cause: Stowed configs assumed macOS-only tools (1Password desktop, terminal-notifier, bd) without cross-platform guards
date: 2026-02-16
severity: high
---

# Headless Linux Git Signing and Claude Code Hook Guards

## Problem

After deploying dotfiles to a headless Ubuntu server (bigdaddy), Claude Code could not commit because:

1. `op-ssh-sign-wrapper` only checked for the 1Password desktop app binary (`/opt/1Password/op-ssh-sign`), which isn't installed on headless Linux
2. Claude Code hooks called `terminal-notifier` (macOS-only) and `bd` without checking if they exist
3. Even after adding `ssh-keygen` as a fallback, signing failed with "Couldn't get agent socket?" because git passes `-U` when `user.signingkey` is a literal public key string

## Root Cause

Three separate cross-platform assumptions in stowed configs:

- **op-ssh-sign-wrapper:** Only knew about 1Password desktop paths, no fallback for systems with just the `op` CLI or a local SSH key
- **settings.json hooks:** `terminal-notifier` and `bd prime` called unconditionally — no `command -v` guard
- **user.signingkey config:** The literal public key string in gitconfig causes git to pass `-U` to the signing program, which forces ssh-agent-based signing. On bigdaddy, there is no ssh-agent, so `ssh-keygen -U` fails even though the private key exists on disk

## Solution

### 1. op-ssh-sign-wrapper: Add ssh-keygen fallback with platform guard

```sh
#!/bin/sh
if [ -x /Applications/1Password.app/Contents/MacOS/op-ssh-sign ]; then
    exec /Applications/1Password.app/Contents/MacOS/op-ssh-sign "$@"
elif [ -x /opt/1Password/op-ssh-sign ]; then
    exec /opt/1Password/op-ssh-sign "$@"
elif [ "$(uname -s)" = "Linux" ] && command -v ssh-keygen >/dev/null 2>&1; then
    exec ssh-keygen "$@"
else
    echo "op-ssh-sign-wrapper: no signing method available" >&2
    exit 1
fi
```

**Critical:** The `uname -s = Linux` guard prevents macOS from silently falling back to `ssh-keygen` if 1Password is temporarily unavailable (e.g., during an update). This would downgrade from vault-protected signing (biometric required) to unprotected local-file signing.

### 2. Hook guards: `command -v` pattern

```json
"command": "command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier ... || true"
"command": "command -v bd >/dev/null 2>&1 && bd prime || true"
```

Use POSIX `>/dev/null 2>&1` (not bash-ism `&>/dev/null`) since hooks may execute under `/bin/sh`. The `|| true` ensures hook failures never block Claude Code.

### 3. Per-host git config include for signing key override

Add to stowed gitconfig:

```gitconfig
[include]
    path = ~/.config/git/local
```

On bigdaddy, create `~/.config/git/local` (NOT stowed):

```gitconfig
[user]
    signingkey = ~/.ssh/id_ed25519
```

This overrides the literal public key with the private key file path. Git then calls `ssh-keygen -Y sign -f ~/.ssh/id_ed25519` without `-U`, and `ssh-keygen` reads the key directly from disk without needing an agent.

## Key Insights

### Git signing key types and their behavior

| `user.signingkey` value | Git passes `-U`? | Agent required? | Use case |
|---|---|---|---|
| Literal public key (`ssh-ed25519 AAAA...`) | Yes | Yes | macOS with 1Password agent |
| Private key file path (`~/.ssh/id_ed25519`) | No | No | Headless Linux with local key |
| Public key file path (`~/.ssh/id_ed25519.pub`) | Yes | Yes | When key is only in agent |

### ssh-keygen as signing program requirements

- OpenSSH 8.2+ required (for `-Y sign` support)
- If key has a passphrase and no agent: `ssh-keygen` prompts on `/dev/tty`, which fails in non-interactive contexts (Claude Code, IDE terminals, CI)
- Passphrase-free keys work without an agent when `user.signingkey` points to the private key file

### Cross-platform trust model

On bigdaddy, SSH authentication and git signing use different trust paths:

- **SSH auth:** 1Password agent socket (`~/.1password/agent.sock`) when available
- **Git signing:** Local key file via `ssh-keygen` (no 1Password involvement)

This is documented and intentional — the 1Password desktop app is not available on headless servers.

## Prevention

- Always guard tool-specific commands with `command -v tool >/dev/null 2>&1 &&` in stowed configs that deploy to multiple platforms
- Use `[include] path = ~/.config/git/local` for per-host git config overrides instead of modifying stowed files
- When using `ssh-keygen` as a signing fallback, ensure `user.signingkey` points to the private key file (not a literal key) on systems without ssh-agent
- Add `uname -s` platform guards to prevent security-sensitive fallbacks from activating on the wrong OS

## Related

- `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md` — original deployment issues
- `stow/local/dot-local/bin/op-ssh-sign-wrapper` — the signing wrapper
- `stow/claude/dot-claude/settings.json` — Claude Code hooks
- `stow/git/dot-gitconfig` — git signing config with include
