---
title: "Fix cross-platform git signing and hook errors on headless Linux"
type: fix
status: completed
date: 2026-02-16
deepened: 2026-02-16
---

# Fix Cross-Platform Git Signing and Hook Errors on Headless Linux

## Enhancement Summary

**Deepened on:** 2026-02-16  
**Agents used:** security-sentinel, architecture-strategist, code-simplicity-reviewer, pattern-recognition-specialist, deployment-verification-agent, best-practices-researcher, spec-flow-analyzer, 2x learnings-researchers

### Key Improvements

1. Added Linux-only platform guard to prevent silent signing downgrade on macOS
2. Added `command -v ssh-keygen` check with diagnostic error message for the no-tools-available case
3. Documented passphrase / ssh-agent interaction (git passes `-U` flag for literal keys)
4. Expanded scope to include `bd prime` hooks (same class of bug)
5. Added deployment verification checklist and rollback procedure

### New Considerations Discovered

- Git writes literal signing keys to a temp file before passing `-f` to the signing program — `ssh-keygen` receives a file path either way
- The `-U` flag forces agent-based signing when `user.signingkey` is a literal key string — requires ssh-agent if key has a passphrase
- `session-context.sh` uses macOS-only `stat -f %m` syntax (separate follow-up)
- Split trust model: SSH authentication uses 1Password agent, git signing uses local key

## Overview

Two issues prevent Claude Code from committing on the headless server (Ubuntu):

1. **`op-ssh-sign not found`** — Git commit signing fails because the wrapper only checks for the 1Password desktop app binary, which isn't installed
2. **`terminal-notifier: not found`** — Claude Code hooks call a macOS-only tool unconditionally

Additionally discovered during deepening:

1. **`bd prime: not found`** — PreCompact and SessionStart hooks call `bd` without a guard (same class of bug as terminal-notifier)

## Problem Statement

The dotfiles are stowed identically to all machines, but several configs assume macOS-only tools:

- `stow/local/dot-local/bin/op-ssh-sign-wrapper` hardcodes two paths for the 1Password desktop app binary. On the headless server, only the `op` CLI (2.32.1 via linuxbrew) is installed — no desktop app.
- `stow/claude/dot-claude/settings.json` hooks call `terminal-notifier` (lines 157, 231) and `bd prime` (lines 180, 220) without checking if they exist, causing errors on every Stop, Notification, PreCompact, and SessionStart event.

## Proposed Solution

### Fix 1: Update `op-ssh-sign-wrapper` to fall back to `ssh-keygen`

**Root cause:** The signing key (`ssh-ed25519 AAAAC3...`) exists as a local file at `~/.ssh/id_ed25519` on the headless server — the same key configured in `user.signingkey`. The wrapper doesn't need the 1Password desktop app; `ssh-keygen` can sign directly with the local key file.

**Verified:** `ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n git` produces valid signatures on the headless server.

**Updated wrapper logic:**

```sh
#!/bin/sh
# Cross-platform wrapper for SSH commit signing
# Priority:
#   1. 1Password desktop app binary (macOS/Linux)
#   2. ssh-keygen on Linux (when signing key exists as local file)
#
# On macOS, 1Password is always required — no silent fallback to ssh-keygen.
# This prevents accidental downgrade from vault-protected to local-file signing.
#
# ssh-keygen fallback requires:
#   - OpenSSH 8.2+ (for -Y sign support)
#   - Passphrase-free key OR key loaded in ssh-agent (non-interactive contexts
#     like Claude Code cannot prompt for a passphrase via /dev/tty)
#
# Note: Git writes the literal signing key (from user.signingkey) to a temp
# file before passing -f to this program, so ssh-keygen always receives a
# file path — not a key literal.

if [ -x /Applications/1Password.app/Contents/MacOS/op-ssh-sign ]; then
    exec /Applications/1Password.app/Contents/MacOS/op-ssh-sign "$@"
elif [ -x /opt/1Password/op-ssh-sign ]; then
    exec /opt/1Password/op-ssh-sign "$@"
elif [ "$(uname -s)" = "Linux" ] && command -v ssh-keygen >/dev/null 2>&1; then
    # Headless Linux fallback: sign with local key file via ssh-keygen
    exec ssh-keygen "$@"
else
    echo "op-ssh-sign-wrapper: no signing method available" >&2
    echo "  Tried: 1Password desktop app (op-ssh-sign), ssh-keygen" >&2
    echo "  On macOS: install 1Password desktop app" >&2
    echo "  On Linux: ensure ssh-keygen is installed (openssh-client)" >&2
    exit 1
fi
```

#### Research Insights

**Security (HIGH):** The original plan had an unrestricted `ssh-keygen` fallback that could silently activate on macOS if 1Password was temporarily unavailable (e.g., during an update). This would downgrade from vault-protected signing (biometric auth required) to local-file signing with no warning. The `uname -s = Linux` guard ensures macOS always requires 1Password.

**Passphrase handling:** When `user.signingkey` is a literal key string (current config), git passes the `-U` flag to the signing program, which forces agent-based signing. If the key has a passphrase, `ssh-agent` must have the key loaded. The manual verification succeeded, implying the key on the headless server has no passphrase — but this should be documented as a prerequisite.

**OpenSSH version:** `ssh-keygen -Y sign` requires OpenSSH 8.2+. Ubuntu 22.04+ ships 8.9+, so this is safe on the headless server. The prior solution doc documents version requirements for `Match exec` (OpenSSH 7.3+) — this follows the same convention.

**Pattern consistency:** The wrapper is a standalone `#!/bin/sh` POSIX script in `~/.local/bin/`. It must be self-contained with no sourced dependencies (invoked by git in arbitrary contexts). Using `core/detect-shell.sh` would be wrong — those functions detect shell type/version, not OS or tool availability.

**File:** `stow/local/dot-local/bin/op-ssh-sign-wrapper`

### Fix 2: Guard `terminal-notifier` hooks with `command -v`

Wrap both `terminal-notifier` invocations so they silently no-op when the command isn't available.

**Before:**

```json
"command": "terminal-notifier -sound Funky -title \"🔔 Claude Code\" -message \"Claude needs your input\""
```

**After:**

```json
"command": "command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -sound Funky -title \"🔔 Claude Code\" -message \"Claude needs your input\" || true"
```

Apply to both hooks:

- **Line 157** (Notification hook)
- **Line 231** (Stop hook)

#### Research Insights

**Pattern consistency:** `command -v tool >/dev/null 2>&1` is the dominant pattern for conditional tool availability in this codebase — used in at least 6 files (`dot-zshrc`, `dot-secrets`, `statusline.sh`, `auto-format.sh`, `caches.sh`). The POSIX `>/dev/null 2>&1` form (not bash-ism `&>/dev/null`) is correct since settings.json hooks may execute under `/bin/sh`.

**Subtlety:** `A && B || C` is not identical to `if A; then B; else C; fi`. If `terminal-notifier` is found but fails, `|| true` swallows that error too. This is desirable — notification failures should never block work.

**File:** `stow/claude/dot-claude/settings.json`

### Fix 3: Guard `bd prime` hooks with `command -v`

Same class of bug as terminal-notifier. The `bd` tool may not be installed on all machines.

**Before:**

```json
"command": "bd prime"
```

**After:**

```json
"command": "command -v bd >/dev/null 2>&1 && bd prime || true"
```

Apply to both hooks:

- **Line 180** (PreCompact hook)
- **Line 220** (SessionStart hook)

**File:** `stow/claude/dot-claude/settings.json`

### Fix 4: Add per-host git config include for signing key override

**Discovered during testing:** The wrapper fallback to `ssh-keygen` alone is insufficient. When `user.signingkey` is a literal public key string (as in the stowed gitconfig), git passes the `-U` flag to the signing program, forcing agent-based signing via `ssh-agent`. On the headless server there is no ssh-agent running, causing "Couldn't get agent socket?" errors.

**Solution:** Add `[include] path = ~/.config/git/local` to the stowed gitconfig, enabling per-host overrides. On the headless server, `~/.config/git/local` overrides `user.signingkey` to point to the private key file (`~/.ssh/id_ed25519`). This makes git pass the file path directly to `ssh-keygen` instead of the `-U` flag, and `ssh-keygen` reads the key from disk without needing an agent.

**Stowed gitconfig addition:**

```gitconfig
[include]
 # Per-host overrides (e.g., user.signingkey on headless Linux)
 path = ~/.config/git/local
```

**File:** `stow/git/dot-gitconfig`

**Per-host file on the headless server** (`~/.config/git/local`, NOT stowed):

```gitconfig
[user]
 signingkey = ~/.ssh/id_ed25519
```

**Why this works:** When git sees a file path as `user.signingkey` (instead of a literal key), it calls `ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n git <buffer>` without `-U`. Since the key is passphrase-free, `ssh-keygen` reads it directly from disk.

## Prerequisites / Verification

Already verified on the headless server:

- `~/.ssh/id_ed25519` exists with the same key as `user.signingkey`
- `ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n git` produces valid signatures
- No 1Password agent socket or desktop app needed
- Key appears to be passphrase-free (non-interactive signing succeeded)

**Before deploying, also verify:**

- OpenSSH version on the headless server: `ssh -V` (must be 8.2+)
- `allowed_signers` file is deployed: `cat ~/.config/git/allowed_signers`
- Git stow package is fully deployed (Stow 2.3.1 has a known bug with nested `dot-` dirs — see `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`)

## Acceptance Criteria

- [x] `git commit` succeeds on the headless server without `op-ssh-sign` binary installed
- [x] Commits are properly signed (verify with `git log --show-signature`)
- [ ] GitHub shows "Verified" badge on commits from the headless server
- [x] `terminal-notifier` hooks produce no errors on Linux
- [x] `bd prime` hooks produce no errors on Linux
- [x] macOS behavior is unchanged (1Password desktop app path still preferred)
- [x] macOS produces a hard failure if 1Password is unavailable (no silent downgrade)
- [x] Wrapper error message is helpful when neither signing method is available

## Deployment Checklist

### Pre-deploy (macOS)

```bash
# Baseline: confirm current signing works
git log --show-signature -1

# Confirm 1Password app binary exists
ls -la /Applications/1Password.app/Contents/MacOS/op-ssh-sign
```

### Deploy steps

1. Edit `stow/local/dot-local/bin/op-ssh-sign-wrapper` (add ssh-keygen fallback)
2. Edit `stow/claude/dot-claude/settings.json` (guard terminal-notifier + bd hooks)
3. Test signing still works on macOS (1Password path tried first, no change)
4. Commit, push to development
5. On the headless server: `git pull && stow -v -d stow -t ~ local && stow -v -d stow -t ~ claude`

### Post-deploy verification (headless server)

```bash
# Verify wrapper was updated
cat ~/.local/bin/op-ssh-sign-wrapper

# Test signing end-to-end
git commit --allow-empty -m "test: verify SSH signing on headless server"
git log --show-signature -1
# Clean up: git reset HEAD~1

# Verify hooks are guarded
grep terminal-notifier ~/.claude/settings.json
grep "bd prime" ~/.claude/settings.json

# Test guarded hooks produce no errors
bash -c 'command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -sound Funky -title "test" -message "test" || true'
echo "Exit code: $?"  # Expected: 0, no output
```

### Post-deploy verification (macOS)

```bash
# Confirm signing still uses 1Password (may prompt biometric)
git commit --allow-empty -m "test: verify 1Password signing"
git log --show-signature -1
# Clean up: git reset HEAD~1

# Confirm terminal-notifier still fires
bash -c 'command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -sound Funky -title "test" -message "test"'
# Expected: macOS notification appears
```

## Rollback Plan

Both changes are config/script only — `git revert` restores previous behavior completely.

**Quick rollback on the headless server:**

```bash
# Temporarily disable signing if wrapper breaks worse
git config --global commit.gpgsign false
git config --global tag.gpgsign false
```

**Full rollback:**

```bash
cd ~/dotfiles
git revert <commit-sha>
stow -v -d stow -t ~ local
stow -v -d stow -t ~ claude
```

## Risk Analysis

- **Low risk:** The wrapper change only adds a new fallback — existing macOS/Linux desktop paths are checked first
- **`ssh-keygen` compatibility:** `ssh-keygen` accepts the same `-Y sign` arguments that git passes, so no argument translation needed
- **macOS safety:** Platform guard (`uname -s = Linux`) ensures macOS never silently falls back to `ssh-keygen` — 1Password is always required
- **`command -v` guard:** POSIX-standard idiom, already used extensively in this codebase

## Follow-up Issues (Out of Scope)

1. **`session-context.sh` uses macOS `stat -f %m`** — Line 17 uses macOS stat syntax. On Linux, `stat -c %Y` is the equivalent. Causes cache TTL to always read as stale, triggering unnecessary `brew list` on every session start. Fix: `stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0`
2. **Wrapper naming** — If `ssh-keygen` becomes the primary signing path on multiple machines, consider renaming from `op-ssh-sign-wrapper` to `git-sign-wrapper` for accuracy
3. **Split trust model documentation** — On the headless server, SSH authentication uses 1Password agent socket but git signing uses local key file. Document in solution doc for audit clarity.

## References

- Existing wrapper: `stow/local/dot-local/bin/op-ssh-sign-wrapper`
- Hook config: `stow/claude/dot-claude/settings.json:152-236`
- SSH config (agent socket paths): `stow/ssh/dot-ssh/config:100-110`
- Git signing config: `stow/git/dot-gitconfig` (gpg.ssh.program = op-ssh-sign-wrapper)
- Prior solution doc: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Git gpg-interface.c: how git constructs ssh-keygen invocations
- OpenSSH 8.2+ required for `-Y sign` support
- `command -v` pattern usage: `dot-zshrc:204`, `dot-secrets:43`, `statusline.sh:26`, `auto-format.sh:67,81`
