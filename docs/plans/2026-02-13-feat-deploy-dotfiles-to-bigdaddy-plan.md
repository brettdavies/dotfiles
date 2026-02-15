---
title: Deploy dotfiles to bigdaddy (Ubuntu server)
type: feat
status: active
date: 2026-02-13
---

# Deploy dotfiles to bigdaddy (Ubuntu server)

## Enhancement Summary

**Deepened on:** 2026-02-13  
**Agents used:** security-sentinel, deployment-verification, architecture-strategist, pattern-recognition-specialist, code-simplicity-reviewer, best-practices-researcher (x2)

### Critical Issues Discovered

1. **SSH lockout risk:** `.profile` unconditionally sources `~/.local/bin/env` -- if missing, login shells fail
2. **oh-my-zsh ordering:** Must install BEFORE stowing zsh (`.zshrc` sources `oh-my-zsh.sh` on load)
3. **SSH config breaks Linux:** `Host *` block has macOS 1Password agent path -- all outbound SSH fails
4. **`.gitconfig` breaks Linux:** `op-ssh-sign` program path hardcoded to `/Applications/1Password.app/...` -- fixed with cross-platform wrapper script
5. **Hardcoded paths in `.zshrc`:** Lines 323, 326 use `/Users/brett/` instead of `$HOME`
6. **`chsh` requires sudo on Ubuntu:** PAM authentication blocks non-interactive `chsh`

### Key Simplifications Applied

- Removed feature branch workflow (unnecessary for first-time setup)
- Reduced from 16 to 8-10 stow packages (skip macOS-only packages)
- Added emergency shell access as safety net before any changes
- Replaced manual backup-and-remove with `stow --adopt` pattern
- Reordered phases to prevent SSH lockout

## Overview

Deploy the dotfiles repository to bigdaddy, an Ubuntu server with existing configuration. The approach is: fix cross-platform issues in the repo first, then clone on bigdaddy, install oh-my-zsh, and stow packages in a safe order with rollback capability.

## Connection Details

- **SSH alias:** `bigdaddy_wifi`
- **Host:** 192.168.1.112, port 22, user `brett`
- **Auth:** `~/.ssh/brett_ed25519` key file
- **OS:** Ubuntu Server

## Strategy

```text
Local (macOS)                          bigdaddy (Ubuntu)
─────────────                          ─────────────────
1. Fix cross-platform issues
   in repo (SSH, git, zsh)
2. Push to development
                                       3. Create emergency shell access
                                       4. Install prerequisites
                                       5. Clone repo, unlock git-crypt
                                       6. Install oh-my-zsh + plugins
                                       7. Deploy ~/.local/bin/env
                                       8. Stow packages (bash first, verify, then zsh)
                                       9. Harden file permissions
                                       10. Change default shell to zsh
                                       11. Verify via new SSH session
```

## Phase 0: Pre-flight code fixes (local)

These issues must be fixed in the repo before deploying to Linux. Each is a separate commit on `development`.

### 0.1 Fix hardcoded paths in `.zshrc`

`stow/zsh/dot-zshrc` has two hardcoded `/Users/brett/` paths that will silently fail on Linux:

```bash
# Line 323 -- change:
[ -s "/Users/brett/.oh-my-zsh/completions/_bun" ] && source "/Users/brett/.oh-my-zsh/completions/_bun"
# To:
[ -s "$HOME/.oh-my-zsh/completions/_bun" ] && source "$HOME/.oh-my-zsh/completions/_bun"

# Line 326 -- change:
export PATH="/Users/brett/.antigravity/antigravity/bin:$PATH"
# To:
export PATH="$HOME/.antigravity/antigravity/bin:$PATH"
```

### 0.2 Add platform-conditional SSH config

The current `Host *` block at the end of `stow/ssh/dot-ssh/config` hardcodes the macOS 1Password agent socket. Replace it with `Match exec` blocks that detect the OS at runtime. This works on both macOS (OpenSSH 9.9) and Linux (OpenSSH 7.3+).

```ssh
# Replace the current Host * block (lines 93-97) with:

# Platform-specific 1Password SSH agent
Match host * exec "test $(uname -s) = Darwin"
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

Match host * exec "test $(uname -s) = Linux"
    IdentityAgent ~/.1password/agent.sock

Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Also remove the per-host `IdentityAgent` macOS paths from individual host blocks where `IdentityFile` is already specified (e.g., `bigdaddy_10`, `bigdaddy_wifi`). The platform-conditional `Match exec` blocks handle agent selection globally.

**Cross-platform verification:** `Match exec` is supported in OpenSSH 7.3+ (August 2016). macOS ships 9.9, Ubuntu 18.04+ ships 7.6+. The `uname -s` command returns `Darwin` on macOS and `Linux` on Ubuntu. Only the matching block activates -- the other is silently ignored.

#### Research Insights: SSH Include directive

An alternative approach is splitting SSH config into `config.d/` fragments with `Include`. This was researched but `Match exec` is simpler for this case because:

- SSH `Include` does not support platform-conditional loading natively
- Using `config.d/` would require a `platform/` subdirectory to avoid double-inclusion from globs
- `Match exec` is a single-file change with no structural rework
- Both approaches require OpenSSH 7.3+, which all supported Ubuntu versions provide

If the SSH config grows significantly or needs per-machine host definitions, migrating to `config.d/` later is straightforward. For now, `Match exec` is sufficient.

**References:**

- [ssh_config(5) man page](https://man7.org/linux/man-pages/man5/ssh_config.5.html)
- [1Password SSH Agent docs](https://developer.1password.com/docs/ssh/agent/)

### 0.3 Add git signing wrapper script (cross-platform, no local files)

`stow/git/dot-gitconfig` has a hardcoded macOS path for `op-ssh-sign` (line 19). Git config does not support OS-conditional directives, but `gpg.ssh.program` just needs an executable -- it does not care how that executable finds the right binary.

**Create a wrapper script** at `stow/git/dot-config/git/op-ssh-sign-wrapper`:

```bash
#!/bin/sh
if [ -x /Applications/1Password.app/Contents/MacOS/op-ssh-sign ]; then
    exec /Applications/1Password.app/Contents/MacOS/op-ssh-sign "$@"
elif [ -x /opt/1password/op-ssh-sign ]; then
    exec /opt/1password/op-ssh-sign "$@"
else
    echo "op-ssh-sign not found" >&2
    exit 1
fi
```

**Update `dot-gitconfig`** to point to the wrapper instead of the hardcoded path:

```gitconfig
[gpg "ssh"]
    program = ~/.config/git/op-ssh-sign-wrapper
    allowedSignersFile = ~/.config/git/allowed_signers
```

The wrapper is fully stow-managed (deployed alongside `allowed_signers` in the `git` package), works on both macOS and Linux, and gracefully handles the case where 1Password is not installed. No machine-local files needed.

### 0.4 Commit and push fixes

```bash
cd ~/dotfiles
# Stage specific files
git add stow/zsh/dot-zshrc stow/ssh/dot-ssh/config stow/git/dot-gitconfig
git commit -m "fix: make zsh, ssh, and git configs cross-platform for Linux deployment"
git push origin development
```

## Phase 1: Audit bigdaddy's current state

SSH into bigdaddy and inventory what exists before making any changes:

```bash
ssh bigdaddy_wifi 'bash -s' << 'AUDIT'
echo "=== OS ==="
lsb_release -a 2>/dev/null || cat /etc/os-release

echo "=== Shell ==="
echo "Default shell: $SHELL"
which zsh bash 2>/dev/null

echo "=== OpenSSH version ==="
ssh -V 2>&1

echo "=== Installed tools ==="
for cmd in stow git-crypt git zsh curl sudo; do
  printf "%-12s %s\n" "$cmd:" "$(which $cmd 2>/dev/null || echo 'NOT INSTALLED')"
done

echo "=== Existing dotfiles ==="
for f in .profile .bashrc .bash_profile .bash_aliases .zshrc .zprofile .p10k.zsh \
         .gitconfig .secrets .ssh/config .config/gh .config/ghostty .config/pip \
         .config/git .claude .codex .config/opencode .local/bin/env .cargo/env; do
  if [ -L "$HOME/$f" ]; then
    echo "SYMLINK: ~/$f -> $(readlink "$HOME/$f")"
  elif [ -e "$HOME/$f" ]; then
    echo "EXISTS:  ~/$f ($(file -b "$HOME/$f" | head -c 40))"
  else
    echo "MISSING: ~/$f"
  fi
done

echo "=== oh-my-zsh ==="
[ -d "$HOME/.oh-my-zsh" ] && echo "INSTALLED" || echo "NOT INSTALLED"

echo "=== Disk space ==="
df -h ~ | tail -1
AUDIT
```

Review the output. If bigdaddy has customizations worth preserving, diff them on the server:

```bash
# Example: compare bigdaddy's .bashrc against the repo version
ssh bigdaddy_wifi 'diff ~/.bashrc ~/dotfiles/stow/bash/dot-bashrc 2>/dev/null || echo "Cannot diff yet (repo not cloned)"'
```

## Phase 2: Prepare bigdaddy

### 2.0 Create emergency shell access (CRITICAL -- do this first)

If `.profile` or `.bashrc` break, SSH login shells may fail. Create a fallback:

```bash
ssh bigdaddy_wifi 'bash -s' << 'EMERGENCY'
# Emergency bashrc -- use: ssh bigdaddy 'bash --rcfile ~/.bashrc.emergency'
cat > "$HOME/.bashrc.emergency" << 'EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PS1='[EMERGENCY] \u@\h:\w\$ '
echo "EMERGENCY SHELL ACTIVE -- normal configs bypassed"
EOF
chmod 644 "$HOME/.bashrc.emergency"
echo "Emergency shell created at ~/.bashrc.emergency"

# Verify bare shell access works
bash --norc --noprofile -c "echo BARE_SHELL_OK"
EMERGENCY
```

**Stop gate:** Do not proceed unless `BARE_SHELL_OK` prints. This is your escape hatch if configs break.

### 2.1 Install prerequisites

```bash
ssh bigdaddy_wifi 'bash -s' << 'INSTALL'
sudo apt update
sudo apt install -y stow git-crypt zsh curl git

# Verify
for cmd in stow git-crypt git zsh; do
  printf "%-12s" "$cmd:"
  which $cmd && $cmd --version 2>/dev/null | head -1
done

# Ensure zsh is in /etc/shells (required for chsh)
ZSH_PATH=$(which zsh)
grep -qF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells
INSTALL
```

### 2.2 Verify SSH host key, then copy git-crypt key

```bash
# Verify bigdaddy's host key fingerprint before transferring secrets
ssh-keygen -l -F 192.168.1.112

# Create config directory on bigdaddy
ssh bigdaddy_wifi 'mkdir -p ~/.config/git-crypt && chmod 700 ~/.config/git-crypt'

# Copy key
scp ~/.config/git-crypt/key bigdaddy_wifi:~/.config/git-crypt/key

# Lock down permissions and verify integrity
LOCAL_HASH=$(shasum -a 256 ~/.config/git-crypt/key | cut -d' ' -f1)
ssh bigdaddy_wifi "chmod 600 ~/.config/git-crypt/key && echo \$(sha256sum ~/.config/git-crypt/key | cut -d' ' -f1)"
# Compare the two hashes manually
echo "Local hash: $LOCAL_HASH"
```

#### Research Insights: git-crypt key security

- git-crypt symmetric keys cannot be rotated or revoked. Protect the key.
- File names are not encrypted, only contents. Do not put secrets in filenames.
- On a fresh clone before `unlock`, encrypted files appear as binary blobs. Always unlock immediately after cloning.
- Store the key backup in a password manager (already documented in README).

### 2.3 Clone repo via HTTPS

```bash
ssh bigdaddy_wifi 'bash -s' << 'CLONE'
git clone https://github.com/brettdavies/dotfiles.git ~/dotfiles
cd ~/dotfiles
git-crypt unlock ~/.config/git-crypt/key

# Verify decryption worked
head -1 stow/secrets/dot-secrets  # Should show readable text, not binary
head -1 stow/ssh/dot-ssh/config   # Should show "Host github.com" or similar
CLONE
```

**Future option:** If push access is needed later, switch to a read-only deploy key for least-privilege SSH access.

## Phase 3: Deploy stow packages

### 3.1 Install oh-my-zsh and plugins FIRST

oh-my-zsh must be installed before stowing the `zsh` package. The `.zshrc` sources `$ZSH/oh-my-zsh.sh` on line 84 and references plugins that must exist. The oh-my-zsh installer replaces `.zshrc` by default -- use `--keep-zshrc` to prevent this.

```bash
ssh bigdaddy_wifi 'bash -s' << 'OMZ'
# Install oh-my-zsh (--keep-zshrc prevents it from overwriting .zshrc)
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

OMZ_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# Plugins (git clone on Linux)
[ -d "$OMZ_CUSTOM/plugins/zsh-autosuggestions" ] || \
  git clone https://github.com/zsh-users/zsh-autosuggestions "$OMZ_CUSTOM/plugins/zsh-autosuggestions"

[ -d "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting" ] || \
  git clone https://github.com/zsh-users/zsh-syntax-highlighting "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting"

[ -d "$OMZ_CUSTOM/plugins/zsh-completions" ] || \
  git clone https://github.com/zsh-users/zsh-completions "$OMZ_CUSTOM/plugins/zsh-completions"

# Theme
[ -d "$OMZ_CUSTOM/themes/powerlevel10k" ] || \
  git clone --depth=1 https://github.com/romkatv/powerlevel10k "$OMZ_CUSTOM/themes/powerlevel10k"

# Verify all exist
for d in plugins/zsh-autosuggestions plugins/zsh-syntax-highlighting \
         plugins/zsh-completions themes/powerlevel10k; do
  [ -d "$OMZ_CUSTOM/$d" ] && echo "OK: $d" || echo "FAIL: $d"
done
OMZ
```

#### Research Insights: oh-my-zsh + stow

- `--unattended` alone does NOT preserve `.zshrc`. You must also pass `--keep-zshrc` (or set `KEEP_ZSHRC=yes`).
- If stdin is not a TTY, the installer auto-sets `RUNZSH=no` and `CHSH=no`, but still overwrites `.zshrc`.
- The `CHSH=no` flag prevents the installer from changing the default shell -- we do that ourselves in Phase 4.

### 3.2 Deploy `~/.local/bin/env` (critical dependency)

`.profile` (line 65) unconditionally sources `$HOME/.local/bin/env`. This file must exist before `.profile` is stowed, or all login shells will fail.

```bash
ssh bigdaddy_wifi 'bash -s' << 'LOCAL'
mkdir -p "$HOME/.local/bin"
ln -sf ~/dotfiles/stow/local/dot-local/bin/env "$HOME/.local/bin/env"
chmod +x "$HOME/.local/bin/env"

# Verify it sources without error
bash "$HOME/.local/bin/env" && echo "env script: OK" || echo "env script: FAILED"
LOCAL
```

### 3.3 Stow packages in safe order

Deploy packages one category at a time, verifying bash login works before proceeding to zsh.

**Package deployment decision:**

| Package | Deploy? | Rationale |
|---------|---------|-----------|
| `shell` | Yes | `.profile` -- cross-platform with `$OSTYPE` gates |
| `bash` | Yes | `.bashrc`, `.bash_profile` -- cross-platform |
| `git` | Yes | `.gitconfig` + `op-ssh-sign-wrapper` -- cross-platform |
| `secrets` | Yes | `.secrets` -- cross-platform |
| `ssh` | Yes | `.ssh/config` -- now cross-platform after Phase 0.2 fix |
| `gh` | Yes | GitHub CLI config -- cross-platform |
| `pip` | Yes | pip config -- cross-platform |
| `claude` | Yes | `.claude/` -- cross-platform |
| `zsh` | Yes | `.zshrc`, `.p10k.zsh` -- after bash verified |
| `codex` | Skip | `.codex/` -- deploy if using Codex on server |
| `opencode` | Skip | `.config/opencode/` -- deploy if using OpenCode on server |
| `ghostty` | Skip | macOS terminal emulator (config is cross-platform but useless on server) |
| `brew` | Skip | Brewfile is macOS-only |
| `cursor` | Skip | macOS GUI editor |
| `local` | Skip | Handled manually in 3.2; `dot-Library/` is macOS-only |

```bash
ssh bigdaddy_wifi 'bash -s' << 'STOW'
cd ~/dotfiles/stow

# Step 1: Use --adopt to handle existing files, then revert to repo versions
# --adopt moves existing files INTO the stow package, creating the symlink.
# Then git checkout restores the repo version (so the symlink points to the correct content).

# Core packages first
for pkg in shell bash git secrets ssh gh pip claude; do
  echo "Stowing: $pkg"
  if ! stow --dotfiles --no-folding -t "$HOME" "$pkg" 2>/dev/null; then
    echo "  Conflicts detected, adopting existing files..."
    stow --dotfiles --adopt --no-folding -t "$HOME" "$pkg"
    cd ~/dotfiles && git checkout -- "stow/$pkg/" && cd stow
  fi
  echo "  OK: $pkg"
done
STOW
```

### 3.4 Verify bash login before proceeding

**Stop gate:** Test that bash login works via a NEW SSH session before stowing zsh. If this fails, you can still SSH in with bash to fix things.

```bash
# From LOCAL machine -- new SSH session
ssh bigdaddy_wifi 'bash --login -c "
  echo BASH_LOGIN_OK
  echo DOTFILES_SHELL_DIR=\$DOTFILES_SHELL_DIR
  echo PATH_INCLUDES_LOCAL_BIN=\$(echo \$PATH | grep -q .local/bin && echo yes || echo no)
  git config --global user.name 2>/dev/null && echo GIT_CONFIG_OK || echo GIT_CONFIG_MISSING
"'
```

**Expected output:**

- `BASH_LOGIN_OK`
- `DOTFILES_SHELL_DIR=/home/brett/dotfiles/config/shell`
- `PATH_INCLUDES_LOCAL_BIN=yes`
- `GIT_CONFIG_OK`

If this fails, debug before proceeding. You still have bash access.

### 3.5 Stow zsh package

Only after bash login is verified:

```bash
ssh bigdaddy_wifi 'bash -s' << 'STOW_ZSH'
cd ~/dotfiles/stow

# Remove any .zshrc that oh-my-zsh may have created
[ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] && rm "$HOME/.zshrc"

if ! stow --dotfiles --no-folding -t "$HOME" zsh 2>/dev/null; then
  stow --dotfiles --adopt --no-folding -t "$HOME" zsh
  cd ~/dotfiles && git checkout -- stow/zsh/
fi
echo "OK: zsh"

# Test zsh starts without error
zsh -l -c 'echo ZSH_OK; echo ZSH_THEME=$ZSH_THEME' 2>&1
STOW_ZSH
```

### 3.6 Harden file permissions

Stow creates symlinks, but the target files may have overly permissive modes from git checkout (typically 644). Sensitive files need restricted permissions:

```bash
ssh bigdaddy_wifi 'bash -s' << 'PERMS'
chmod 700 ~/.ssh 2>/dev/null
chmod 600 ~/.ssh/config 2>/dev/null
chmod 600 ~/.secrets 2>/dev/null
chmod 700 ~/.config/git-crypt 2>/dev/null
chmod 600 ~/.config/git-crypt/key 2>/dev/null

# SSH will refuse to use config files with loose permissions
echo "Permissions hardened"
PERMS
```

## Phase 4: Change default shell and verify

### 4.1 Change default shell to zsh

On Ubuntu, `chsh` requires a password via PAM. Use `sudo chsh` to bypass:

```bash
ssh bigdaddy_wifi 'sudo chsh -s $(which zsh) brett'
```

### 4.2 Verify via new SSH session

Open a completely new SSH session to exercise the full login chain:

```bash
ssh bigdaddy_wifi 'bash -s' << 'VERIFY'
echo "=== Session info ==="
echo "Shell: $SHELL"
echo "User: $(whoami)"
echo "Home: $HOME"

echo ""
echo "=== Symlink verification ==="
for f in .profile .bashrc .zshrc .gitconfig .ssh/config .secrets; do
  if [ -L "$HOME/$f" ]; then
    echo "OK: ~/$f -> $(readlink "$HOME/$f")"
  elif [ -f "$HOME/$f" ]; then
    echo "WARN: ~/$f exists but is NOT a symlink"
  else
    echo "MISSING: ~/$f"
  fi
done

echo ""
echo "=== Shell config chain ==="
echo "DOTFILES_SHELL_DIR=$DOTFILES_SHELL_DIR"

echo ""
echo "=== git-crypt status ==="
cd ~/dotfiles && git-crypt status 2>&1 | head -5

echo ""
echo "=== Git config ==="
git config --global user.name
git config --global user.email

echo ""
echo "=== Negative tests (should NOT exist) ==="
[ -e ~/Library ] && echo "UNEXPECTED: ~/Library exists" || echo "OK: ~/Library absent"
[ -e ~/Brewfile ] && echo "UNEXPECTED: ~/Brewfile exists" || echo "OK: ~/Brewfile absent"
VERIFY
```

### 4.3 Test zsh login specifically

```bash
ssh bigdaddy_wifi 'zsh -l -c "
  echo ZSH_LOGIN_OK
  echo DOTFILES_SHELL_DIR=\$DOTFILES_SHELL_DIR
  echo ZSH_THEME=\$ZSH_THEME
  echo PLUGINS=\$plugins
"'
```

**Expected:**

- `ZSH_LOGIN_OK`
- `DOTFILES_SHELL_DIR=/home/brett/dotfiles/config/shell`
- `ZSH_THEME=powerlevel10k/powerlevel10k`
- `PLUGINS` includes `git zsh-autosuggestions zsh-syntax-highlighting`

## Rollback Procedures

### If bash login breaks (cannot SSH in)

```bash
# Option 1: Force bare shell
ssh bigdaddy_wifi 'bash --norc --noprofile'

# Option 2: Use emergency rcfile
ssh -t bigdaddy_wifi 'bash --rcfile ~/.bashrc.emergency'

# Then unstow and restore:
cd ~/dotfiles/stow
for pkg in shell bash git; do
  stow --dotfiles -D -t "$HOME" "$pkg"
done
```

### If zsh breaks but bash works

```bash
# Unstow zsh only
cd ~/dotfiles/stow && stow --dotfiles -D -t "$HOME" zsh

# Revert to bash
sudo chsh -s /bin/bash brett
```

### Full rollback

```bash
# Unstow everything
cd ~/dotfiles/stow
for pkg in shell bash zsh git ssh secrets gh pip claude; do
  stow --dotfiles -D -t "$HOME" "$pkg" 2>/dev/null && echo "Unstowed: $pkg"
done

# git checkout restores any adopted files
cd ~/dotfiles && git checkout -- stow/

# Revert shell
sudo chsh -s /bin/bash brett
```

## Acceptance Criteria

- [x] Cross-platform fixes committed (SSH `Match exec`, git `op-ssh-sign-wrapper`, zshrc `$HOME`)
- [ ] Emergency shell access created on bigdaddy
- [ ] Stow packages deployed: shell, bash, git, secrets, ssh, gh, pip, claude, zsh
- [ ] macOS-only packages skipped: brew, cursor, ghostty, local
- [ ] `~/.local/bin/env` deployed manually (for `.profile` dependency)
- [ ] `.profile` correctly resolves `DOTFILES_SHELL_DIR` on Linux
- [ ] `config/shell/*.sh` fragments source without errors on Linux
- [ ] git-crypt unlocked, secrets and SSH config decrypted
- [ ] oh-my-zsh installed with plugins and powerlevel10k theme
- [ ] Default shell changed to zsh via `sudo chsh`
- [ ] File permissions hardened (`.ssh/`, `.secrets`, git-crypt key)
- [ ] SSH outbound connections work (test: `ssh -T git@github.com`)
- [ ] No macOS artifacts on server (`~/Library/`, `~/Brewfile`)

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| `.profile` sources missing `~/.local/bin/env` | CRITICAL | Deploy env file before stowing shell (Phase 3.2) |
| oh-my-zsh overwrites stow `.zshrc` symlink | HIGH | Use `KEEP_ZSHRC=yes` flag; install before stowing |
| SSH config 1Password path breaks on Linux | HIGH | `Match exec` platform conditional (Phase 0.2) |
| `.gitconfig` signing program path fails | HIGH | `op-ssh-sign-wrapper` script detects OS at runtime (Phase 0.3) |
| Stow conflicts with existing files | MEDIUM | `stow --adopt` then `git checkout --` pattern |
| `chsh` fails without password | MEDIUM | Use `sudo chsh` to bypass PAM |
| SSH lockout from broken shell config | MEDIUM | Emergency shell + verify bash before zsh |
| git-crypt key transfer integrity | LOW | SHA-256 hash verification after scp |

## Code Fixes Required Before Deployment

These are the specific file changes needed in Phase 0:

| File | Line(s) | Change |
|------|---------|--------|
| `stow/zsh/dot-zshrc` | 323 | `/Users/brett/...` to `$HOME/...` |
| `stow/zsh/dot-zshrc` | 326 | `/Users/brett/...` to `$HOME/...` |
| `stow/ssh/dot-ssh/config` | 93-97 | Replace `Host *` with `Match exec` platform blocks |
| `stow/git/dot-gitconfig` | 19 | Point `program` to `~/.config/git/op-ssh-sign-wrapper` |
| `stow/git/dot-config/git/op-ssh-sign-wrapper` | NEW | Cross-platform wrapper that finds `op-ssh-sign` binary |

## Future Improvements (not in scope)

- Split `stow/local/` into `local-bin/` (cross-platform) and `local-macos/` (LaunchAgents)
- Add `.stow-local-ignore` files to prevent `.DS_Store` symlink attempts
- Deduplicate identical `post-checkout` and `post-merge` git hooks
- Deduplicate SDKMAN init in `dot-bash_profile` and `dot-zprofile` (move to `config/shell/sdkman.sh`)
- Create a bootstrap script with platform detection and package filtering
- Add `.platform` convention to stow packages for automated filtering

## References

- Bootstrap guide: `README.md`
- SSH config: `stow/ssh/dot-ssh/config`
- Shell config: `stow/shell/dot-profile`, `config/shell/*.sh`
- Cross-platform notes: `README.md:206-211`
- [ssh_config(5) -- Match exec](https://man7.org/linux/man-pages/man5/ssh_config.5.html)
- [1Password SSH Agent -- Linux path](https://developer.1password.com/docs/ssh/agent/)
- [oh-my-zsh install flags](https://github.com/ohmyzsh/ohmyzsh/blob/master/tools/install.sh)
- [GNU Stow --adopt](https://www.gnu.org/software/stow/manual/stow.html)
- [git-crypt multi-machine](https://github.com/AGWA/git-crypt)
