---
title: "fix: Cross-platform SSH authentication for github.com"
type: fix
status: active
date: 2026-02-17
---

# fix: Cross-platform SSH authentication for github.com

## Overview

The SSH config's `Host github.com` block had `IdentityFile ~/.ssh/brett_ed25519` commented out, combined with `IdentitiesOnly yes`, meaning SSH never offered the correct key to GitHub on any platform. The fix standardizes the key filename to `brett_ed25519` on all machines and uncomments the `IdentityFile` directive.

## Problem Statement

Two issues were preventing `git push` without a manual `GIT_SSH_COMMAND` override:

1. **macOS:** `IdentityFile ~/.ssh/brett_ed25519` was commented out in the `Host github.com` block. With `IdentitiesOnly yes`, SSH fell back to default key names (`id_rsa`, `id_ed25519`, etc.). The key is named `brett_ed25519` (not a default), so it was never tried.

2. **Headless Linux:** Same commented-out `IdentityFile` issue, plus the key was stored as `~/.ssh/id_ed25519` instead of `~/.ssh/brett_ed25519`. Even after uncommenting, the filename mismatch would cause a failure.

## Solution: Standardize Key Name + Uncomment IdentityFile

Rather than adding platform-conditional `Match exec` blocks for different key names, the simpler approach is to **standardize the key filename to `brett_ed25519` on all machines**. This keeps the SSH config simple and universal:

```ssh-config
Host github.com
  User git
  IdentityFile ~/.ssh/brett_ed25519
  IdentitiesOnly yes
```

### What was done

1. **SSH config** (`stow/ssh/dot-ssh/config`): Uncommented `IdentityFile ~/.ssh/brett_ed25519` on line 6
2. **Headless server key rename**: `~/.ssh/id_ed25519` → `~/.ssh/brett_ed25519` (and `.pub`)
3. **Headless server git local config**: Updated `~/.config/git/local` signingkey from `~/.ssh/id_ed25519` to `~/.ssh/brett_ed25519`

### Verification performed

- **Fingerprints match**: Both macOS and the headless server have `SHA256:n4UpR9oDUpPZ/Z5WFDr34cpp7qHiZzoSk2GIuEr9Cc4` (same key material, was just named differently)
- **macOS `ssh -T git@github.com`**: Authenticated successfully
- **Headless server git signing**: Verified working with renamed key
- **Headless server SSH auth to GitHub**: Pending -- requires restowing the updated SSH config (pull from main after PR merge)

## Remaining Steps

### 1. Audit Other SSH Hosts with Missing IdentityFile

Several hosts have `IdentitiesOnly yes` without an explicit `IdentityFile`:

| Host | IdentityFile | IdentitiesOnly | Status |
|---|---|---|---|
| `github.com` | `~/.ssh/brett_ed25519` | yes | **Fixed** |
| `arouter` | (none) | yes | Broken -- agent-only, no fallback |
| `bigdaddy_25` | (none) | yes | Broken -- agent-only, no fallback |
| `dnsdhcp` | (none) | yes | Broken -- agent-only, no fallback |
| `pool` | (none) | yes | Broken -- agent-only, no fallback |
| `speedy` | (none) | yes | Broken -- agent-only, no fallback |
| `bigdaddy_10` | `~/.ssh/brett_ed25519` | yes | OK |
| `bigdaddy_wifi` | `~/.ssh/brett_ed25519` | yes | OK |
| `raspberry` | `~/.ssh/brett_ed25519` | yes | OK |
| `gauntlet_ec2` | `~/.ssh/brettdavies-ec2.pem` | yes | OK |

**Decision needed:** For hosts with `IdentitiesOnly yes` but no `IdentityFile`, either:

- (a) Add `IdentityFile ~/.ssh/brett_ed25519` to each
- (b) Remove `IdentitiesOnly yes` (let SSH/agent try all keys)
- (c) Leave as-is if 1Password agent is the intended auth method

### 2. Add Post-Stow Validation to stow-deploy

Add an SSH config validation check to `scripts/stow-deploy` after stowing the `ssh` package:

```bash
# After stowing ssh package:
if [[ " $deployed " == *" ssh "* ]]; then
  # Verify SSH config parses correctly
  if ! ssh -G github.com >/dev/null 2>&1; then
    echo "WARNING: SSH config may be invalid -- 'ssh -G github.com' failed" >&2
  fi
  # Verify the configured identity file exists
  _id_file=$(ssh -G github.com 2>/dev/null | awk '/^identityfile /{print $2; exit}')
  _id_file="${_id_file/#\~/$HOME}"
  if [ -n "$_id_file" ] && [ ! -f "$_id_file" ]; then
    echo "WARNING: SSH IdentityFile '$_id_file' does not exist" >&2
  fi
fi
```

### 3. Deploy to the headless server

After merging to `main`:

```bash
# On the headless server:
cd ~/dotfiles && git pull
scripts/stow-deploy --headless ssh
ssh -T git@github.com  # Should authenticate
```

### 4. Update Documentation

Update `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`:

- Add SSH authentication section (currently only covers signing)
- Document the `brett_ed25519` naming convention across all machines
- Add key mapping table:

| Platform | SSH key file | Git signing key | Agent |
|---|---|---|---|
| macOS | `~/.ssh/brett_ed25519` | Literal pubkey (via 1Password) | 1Password SSH agent |
| Linux (headless) | `~/.ssh/brett_ed25519` | `~/.ssh/brett_ed25519` (via `~/.config/git/local`) | 1Password agent or none |

### 5. Convention for New Server Deployments

When deploying to a new server, the SSH key must be named `~/.ssh/brett_ed25519` (not `id_ed25519`). Document this in the deployment playbook or add a pre-stow check to `stow-deploy`.

## Acceptance Criteria

- [x] `ssh -T git@github.com` succeeds on macOS
- [ ] `ssh -T git@github.com` succeeds on the headless server (after restow)
- [x] `git push/pull` works without `GIT_SSH_COMMAND` on macOS
- [ ] `git push/pull` works without `GIT_SSH_COMMAND` on the headless server (after restow)
- [x] Git commit signing works on the headless server with renamed key
- [ ] Other hosts with missing IdentityFile audited and fixed
- [x] Post-stow validation added to stow-deploy
- [x] Documentation updated

## References

- SSH config: `stow/ssh/dot-ssh/config` (git-crypt encrypted)
- Git config: `stow/git/dot-gitconfig`
- Signing wrapper: `stow/local/dot-local/bin/op-ssh-sign-wrapper`
- Stow deploy: `scripts/stow-deploy`
- Signing architecture: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Cross-platform deployment: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
