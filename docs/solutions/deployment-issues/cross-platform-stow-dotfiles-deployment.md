---
title: Cross-platform dotfiles deployment (macOS to Ubuntu 24.04)
category: deployment-issues
tags:
  - gnu-stow
  - cross-platform
  - ssh-config
  - git-signing
  - shell-config
  - oh-my-zsh
  - 1password
  - deployment
module: dotfiles deployment
symptom: Multiple failures when deploying macOS dotfiles to Ubuntu — SSH lockout, git signing errors, stow errors with nested directories
root_cause: Hardcoded macOS paths, GNU Stow 2.3.1 --dotfiles bug, deployment ordering dependencies, tool behavior differences across platforms
date: 2026-02-15
severity: critical
---

# Cross-Platform Dotfiles Deployment (macOS to Ubuntu 24.04)

## Problem

Deploying a GNU Stow-managed dotfiles repository from macOS to an Ubuntu 24.04 server revealed 7 cross-platform issues that caused SSH lockout risk, git signing failures, and stow deployment errors.

## Issues and Solutions

### 1. SSH config breaks on Linux

**Symptom:** `Host *` block hardcoded the macOS 1Password agent socket path. All outbound SSH fails on Linux.

**Root cause:** Single-platform assumption. The 1Password agent socket lives in different locations:

- macOS: `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
- Linux: `~/.1password/agent.sock`

**Fix:** Replace `Host *` with platform-conditional `Match exec` blocks:

```ssh
Match host * exec "test $(uname -s) = Darwin"
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

Match host * exec "test $(uname -s) = Linux"
  IdentityAgent ~/.1password/agent.sock

Host *
  AddKeysToAgent yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Remove per-host `IdentityAgent` directives -- the global Match exec handles agent selection for all hosts.

**Compatibility:** `Match exec` requires OpenSSH 7.3+ (August 2016). macOS ships 9.9, Ubuntu 18.04+ ships 7.6+.

### 2. Git commit signing fails on Linux

**Symptom:** `gpg.ssh.program` pointed to `/Applications/1Password.app/Contents/MacOS/op-ssh-sign` which doesn't exist on Linux.

**Fix:** Create a wrapper script at `~/.local/bin/op-ssh-sign-wrapper`:

```bash
#!/bin/sh
if [ -x /Applications/1Password.app/Contents/MacOS/op-ssh-sign ]; then
    exec /Applications/1Password.app/Contents/MacOS/op-ssh-sign "$@"
elif [ -x /opt/1Password/op-ssh-sign ]; then
    exec /opt/1Password/op-ssh-sign "$@"
else
    echo "op-ssh-sign not found" >&2
    exit 1
fi
```

Reference it by bare name in `.gitconfig`:

```gitconfig
[gpg "ssh"]
  program = op-ssh-sign-wrapper
```

**Critical detail:** Git's `gpg.ssh.program` uses `exec()`, not a shell. Tilde (`~`) is NOT expanded. The wrapper must be on `$PATH` and referenced by bare name. Using `program = ~/.config/git/op-ssh-sign-wrapper` will fail with `cannot exec: No such file or directory`.

### 3. Hardcoded home directory paths in .zshrc

**Symptom:** Paths like `/Users/brett/.oh-my-zsh/completions/_bun` fail silently on Linux where home is `/home/brett/`.

**Fix:** Replace all hardcoded home paths with `$HOME`:

```bash
# Before
[ -s "/Users/brett/.oh-my-zsh/completions/_bun" ] && source "/Users/brett/.oh-my-zsh/completions/_bun"
export PATH="/Users/brett/.antigravity/antigravity/bin:$PATH"

# After
[ -s "$HOME/.oh-my-zsh/completions/_bun" ] && source "$HOME/.oh-my-zsh/completions/_bun"
export PATH="$HOME/.antigravity/antigravity/bin:$PATH"
```

**Detection:** `grep -r "/Users/" stow/` to find all hardcoded macOS paths.

### 4. GNU Stow --dotfiles bug with nested directories (fixed in 2.4.0)

**Symptom:** `stow --dotfiles` fails with:

```text
stow: ERROR: stow_contents() called with non-directory path: dotfiles/stow/git/.config
```

**Root cause:** Bug in Stow 2.3.x where `--dotfiles` flag's `dot-` to `.` conversion fails for nested directories. Only top-level `dot-` prefixed files/dirs are converted correctly. [Fixed in Stow 2.4.0](https://github.com/aspiers/stow/issues/33).

**Fix:** Install Stow >= 2.4.0 via Homebrew/Linuxbrew (`brew install stow`). Ubuntu 24.04's apt repo only ships 2.3.1. The `stow-deploy` script warns when it detects a pre-2.4.0 version.

**Affected packages (on 2.3.x only):** Any with nested `dot-` dirs (git/`dot-config`, ssh/`dot-ssh`, gh/`dot-config`, pip/`dot-config`, claude/`dot-claude`).

**Legacy workaround (if stuck on 2.3.x):** Manual `ln -sf` for affected packages:

```bash
# Instead of: stow --dotfiles -t "$HOME" git
ln -sf ~/dotfiles/stow/git/dot-gitconfig ~/.gitconfig
for f in ~/dotfiles/stow/git/dot-config/git/*; do
  ln -sf "$f" "$HOME/.config/git/$(basename "$f")"
done
```

### 5. Deployment ordering prevents SSH lockout

**Critical dependency chain:**

1. `.profile` (line 65) unconditionally sources `~/.local/bin/env` -- deploy this file BEFORE stowing shell package
2. oh-my-zsh must be installed BEFORE stowing zsh (`.zshrc` sources `$ZSH/oh-my-zsh.sh` on load)
3. Verify bash login BEFORE stowing zsh (safety gate)
4. Create emergency shell BEFORE any config changes

**Safe deployment order:**

```text
1. Create ~/.bashrc.emergency (escape hatch)
2. Deploy ~/.local/bin/env (profile dependency)
3. Stow: shell, bash, git, secrets, ssh, gh, pip, claude
4. Verify bash login via new SSH session
5. Install oh-my-zsh (KEEP_ZSHRC=yes CHSH=no RUNZSH=no)
6. Stow: zsh
7. Change default shell (sudo chsh)
```

### 6. oh-my-zsh installer flags

The installer overwrites `.zshrc` unless prevented. Correct invocation:

```bash
KEEP_ZSHRC=yes CHSH=no RUNZSH=no \
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

- `KEEP_ZSHRC=yes` -- preserves existing `.zshrc` (must be env var, not CLI flag)
- `CHSH=no` -- don't change default shell (we use `sudo chsh` ourselves)
- `RUNZSH=no` -- don't launch zsh after install

### 7. stow --adopt pattern for existing files

When target files already exist (not symlinks), stow refuses to overwrite. The `--adopt` pattern resolves this:

```bash
# Step 1: Adopt existing files (moves them into stow package, creates symlinks)
stow --dotfiles --adopt -t "$HOME" <package>

# Step 2: Restore repo version (symlink now points to correct content)
cd ~/dotfiles && git checkout -- stow/<package>/
```

## Prevention Strategies

### Cross-platform checklist for new stow packages

- [ ] No hardcoded `/Users/` or `/home/` paths (use `$HOME`)
- [ ] No macOS-specific binary paths without platform detection
- [ ] Verify Stow >= 2.4.0 (`stow --version`; install via `brew install stow` if needed)
- [ ] Gate platform-specific config behind `$OSTYPE`, `uname -s`, or `Match exec`
- [ ] Verify tool supports tilde expansion if using `~` in config values

### Before deploying to a new machine

- [ ] Create emergency shell access first
- [ ] Deploy critical dependencies (`.local/bin/env`) before stowing shell
- [ ] Install oh-my-zsh before stowing zsh
- [ ] Verify bash login before stowing zsh
- [ ] Back up existing configs (`~/.config-backup-$(date +%Y%m%d)`)
- [ ] Verify Stow >= 2.4.0 (`brew install stow`; Ubuntu apt only has 2.3.1)

### SSH-only GitHub access after stow

The stowed gitconfig uses `url.insteadOf` rules to rewrite all HTTPS GitHub URLs to SSH:

```gitconfig
[url "git@github.com:"]
    insteadOf = https://github.com/
[url "git@gist.github.com:"]
    insteadOf = https://gist.github.com/
```

**Ordering constraint:** After stowing the `git` package, all GitHub operations (including cloning public repos) require SSH authentication. The SSH key (`~/.ssh/brett_ed25519`) must be deployed to the server and authorized on GitHub **before** stowing the git package.

**Initial clone is exempt:** The `insteadOf` rules aren't active until the gitconfig is stowed, so the initial `git clone` of the dotfiles repo can use either HTTPS or SSH. SSH is preferred, but HTTPS won't break anything.

### Cross-platform patterns

| Pattern | Use case | Example |
|---------|----------|---------|
| `Match exec` | SSH config platform conditionals | `Match host * exec "test $(uname -s) = Darwin"` |
| `url.insteadOf` | Force SSH for all GitHub access | `[url "git@github.com:"] insteadOf = https://github.com/` |
| Wrapper script | Tool binary path differences | `op-ssh-sign-wrapper` detects macOS vs Linux binary |
| `$HOME` | Home directory references | Never hardcode `/Users/brett` |
| `$OSTYPE` | Shell config conditionals | `if [[ "$OSTYPE" == "darwin"* ]]; then` |
| `stow --adopt` | Existing file conflicts | Adopt then `git checkout` to restore |

## References

- [ssh_config(5) -- Match exec](https://man7.org/linux/man-pages/man5/ssh_config.5.html)
- [1Password SSH Agent -- Linux path](https://developer.1password.com/docs/ssh/agent/)
- [oh-my-zsh install flags](https://github.com/ohmyzsh/ohmyzsh/blob/master/tools/install.sh)
- [GNU Stow --adopt](https://www.gnu.org/software/stow/manual/stow.html)
- Initial deployment plan: `docs/plans/2026-02-13-feat-deploy-dotfiles-to-ubuntu-server-plan.md`
