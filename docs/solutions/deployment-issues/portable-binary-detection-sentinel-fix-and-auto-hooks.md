---
title: "Portable binary detection, shell sentinel leak fix, and auto hooksPath"
category: deployment-issues
tags:
  - shell-configuration
  - git-hooks
  - git-crypt
  - stow-deploy
  - headless
  - cross-platform
  - sentinel
  - non-interactive-shell
  - binary-detection
  - core-hookspath
module: shell/hooks/stow-deploy
symptom: >
  Three headless Ubuntu deployment failures: (1) non-interactive zsh child
  processes inherited DOTFILES_SHELL_DIR sentinel from parent, skipped
  re-sourcing .profile, and lost access to secrets; (2) git hooks and
  stow-deploy used the `file` command to detect git-crypt locked files, but
  `file` is not installed on minimal Ubuntu servers, causing silent failures
  in post-checkout, post-merge, and encrypted-package guards; (3) after
  cloning the dotfiles repo, core.hooksPath was not set until users manually
  ran `bash .githooks/setup`, leaving hooks inactive on fresh deployments.
root_cause: >
  (1) DOTFILES_SHELL_DIR was exported in .profile, so child processes
  (scripts, cron, non-interactive zsh subshells) inherited the sentinel and
  skipped .profile sourcing entirely — they never loaded secrets or
  environment. (2) The `file` command is not part of a minimal Ubuntu
  install; git hooks and stow-deploy depended on `file --mime` output to
  distinguish binary (locked) from text (unlocked) git-crypt files.
  (3) core.hooksPath configuration was a manual post-clone step documented
  in the README but not enforced by any automated deployment path.
date: 2026-02-17
severity: high
---

# Portable Binary Detection, Shell Sentinel Leak Fix, and Auto hooksPath

## Problem Symptom

After deploying dotfiles to headless Ubuntu servers, three classes of failure emerged:

1. **Secrets silently missing in child processes.** Non-interactive zsh subshells (spawned by scripts, `ssh host 'command'`, cron) inherited the `DOTFILES_SHELL_DIR` sentinel from their parent and skipped sourcing `.profile`. These child processes had no PATH modifications, no secrets, no Homebrew — a completely empty environment.

2. **Git hooks failed silently on minimal Ubuntu.** The `post-checkout` and `post-merge` hooks used `file ... | grep "text"` to check whether git-crypt files were locked (binary) or unlocked (text). The `file` command is not installed on minimal Ubuntu server images, so the check failed and git-crypt auto-unlock never triggered.

3. **Hooks never activated on fresh deployments.** `core.hooksPath=.githooks` was a manual post-clone step. On headless servers deployed via automation, no human ran the setup command, so hooks (pre-commit branch protection, auto git-crypt unlock) were silently absent.

## Root Cause

### 1. Exported sentinel leaked to child processes

`.profile` declared `export DOTFILES_SHELL_DIR="$_CONFIG_DIR"`. The sentinel served dual purpose: prevent double-sourcing and provide a path for `.bashrc`/`.zshrc` to locate `shell-functions`. Because it was exported, child processes inherited it and their `.zshenv`/`.bashrc` guard check `[ -z "${DOTFILES_SHELL_DIR:-}" ]` evaluated as false — they believed `.profile` had already been sourced.

### 2. `file` command not available on minimal installs

The `file` command (part of the `file`/`libmagic` package) is not part of `coreutils` and is not installed on minimal Ubuntu server images. Git hooks depended on parsing `file` output to distinguish binary from text files, with output strings that also varied between macOS and Linux.

### 3. Manual bootstrap step not automated

`core.hooksPath` configuration existed only as a README instruction and a standalone `bash .githooks/setup` script. The deployment script (`stow-deploy`) did not handle it, so automated deployments to thousands of servers left hooks inactive.

## Solution

Three fixes were applied across PRs #7, #8, and #9 (commits `9aeb936`, `a7566ce`, `49a98e5`).

### 1. Shell-local sentinel (no export)

**Before** (`stow/shell/dot-profile`):

```sh
# Exported so bashrc/zshrc can source shell-functions from the same directory
export DOTFILES_SHELL_DIR="$_CONFIG_DIR"
```

**After** (`stow/shell/dot-profile`):

```sh
# NOT exported: sentinel must only prevent double-sourcing within the same
# shell process, not leak into child processes (which need their own .profile)
DOTFILES_SHELL_DIR="$_CONFIG_DIR"
```

**Why it works:** A shell-local variable is visible in the current process and in files sourced by that process (`. ~/.profile`, `. ~/.bashrc`), but is NOT inherited by child processes. This means:

- Within a single shell session, `.zshenv` and `.bashrc` both check `[ -z "${DOTFILES_SHELL_DIR:-}" ]` before sourcing `.profile`. The guard works and `.profile` is sourced only once.
- When that shell spawns a child (`bash -c '...'`, `ssh host 'cmd'`, a subshell), the child does NOT inherit `DOTFILES_SHELL_DIR`. The child's `.zshenv` sees the variable as unset and sources `.profile` fresh.

The consuming files are unchanged — they already used `${DOTFILES_SHELL_DIR:-}` with a default:

```sh
# stow/zsh/dot-zshenv
if [ -z "${DOTFILES_SHELL_DIR:-}" ] && [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
```

**Key insight:** `export` is needed when a variable must cross process boundaries. A sentinel that prevents re-sourcing should NEVER cross process boundaries — each process needs its own initialization.

### 2. Portable binary detection (`grep -qI`)

**Before** (`.githooks/post-checkout`, `.githooks/post-merge`, `scripts/stow-deploy`):

```sh
sentinel="stow/secrets/dot-secrets"
if [ -f "$sentinel" ] && ! file "$sentinel" | grep -q "text"; then
    git-crypt unlock ~/.config/git-crypt/key 2>/dev/null || true
fi
```

**After** (`.githooks/post-checkout`, `.githooks/post-merge`):

```sh
sentinel="stow/secrets/dot-secrets"
if [ -f "$sentinel" ] && ! grep -qI '' "$sentinel" 2>/dev/null; then
    git-crypt unlock ~/.config/git-crypt/key 2>/dev/null || true
fi
```

**After** (`scripts/stow-deploy`):

```sh
# grep -qI treats binary files as non-matching (no `file` command needed)
if ! grep -qI '' "$STOW_DIR/secrets/dot-secrets" 2>/dev/null; then
    echo "FATAL: git-crypt is locked. Encrypted files would be deployed as binary blobs." >&2
    echo "       Run: git-crypt unlock ~/.config/git-crypt/key" >&2
    exit 1
fi
```

**Why `grep -qI ''` works:**

- `-I` tells grep to treat binary files as if they contain no matches. When grep encounters null bytes (which git-crypt-encrypted files always contain), it immediately returns exit code 1.
- `-q` suppresses output (only the exit code matters).
- The pattern `''` (empty string) matches every line in a text file, so the command returns 0 for any non-empty text file and 1 for any binary file.
- `2>/dev/null` suppresses the "Binary file matches" warning some grep versions emit.

**Portability:** `grep` is a POSIX utility guaranteed on every Unix system. The `-I` flag is supported by GNU grep (Linux) and BSD grep (macOS). No `file` command dependency, no output-string parsing, no locale sensitivity.

### 3. Auto `core.hooksPath` in stow-deploy

**Implementation** (`scripts/stow-deploy`, post-stow validation section):

```sh
# Git hooks: ensure core.hooksPath is set for this repo
if [ -d "$REPO_ROOT/.githooks" ]; then
  _hooks_path=$(git -C "$REPO_ROOT" config --local core.hooksPath 2>/dev/null || true)
  if [ "$_hooks_path" != ".githooks" ]; then
    git -C "$REPO_ROOT" config --local core.hooksPath .githooks
    echo ""
    echo "==> Configured core.hooksPath = .githooks"
  fi
fi
```

**Design decisions:**

- **Post-stow validation phase:** Runs after all packages are deployed, alongside SSH config validation.
- **Idempotent:** Reads current value first; no-op if already set.
- **`.githooks/` existence guard:** Safe to reuse in repos without custom hooks.
- **`--local` scope:** Setting stored in `.git/config`, scoped to this repository only.
- **`-C "$REPO_ROOT"`:** Ensures the command targets the dotfiles repo even if the working directory changed during the deploy loop.

## Prevention Strategies

1. **Never export sentinel/guard variables.** Any variable whose sole purpose is to prevent double-sourcing must be declared without `export`. Exporting causes child shells to inherit the sentinel, tricking them into skipping sourcing entirely.

2. **Use only POSIX-guaranteed utilities in hooks and deployment scripts.** The POSIX base set (`sh`, `grep`, `sed`, `awk`, `test`, `cat`, `tr`, `cut`, `wc`, `diff`, `mkdir`, `chmod`) is safe. Utilities like `file`, `lsof`, `column`, `jq`, and `realpath` are NOT guaranteed on minimal installs.

3. **Replace `file` with `grep -qI` for binary detection.** This is the portable idiom: `-I` treats binary files as non-matching and returns exit code 1 for binary content, 0 for text.

4. **Eliminate all manual bootstrap steps.** Any post-clone or post-pull setup action that a human might forget must be automated in the deployment script. README instructions are documentation, not enforcement.

5. **Gate optional tool usage behind `command -v` checks.** Use POSIX `command -v` (not `which`) with `>/dev/null 2>&1`.

6. **Test in the minimal target environment.** Verify hooks and scripts run in a `ubuntu:latest` container with no extras installed. The macOS dev machine has hundreds of tools via Homebrew that the Ubuntu servers do not.

## Verification Commands

```bash
# Verify sentinel is NOT exported
grep -rn 'export.*DOTFILES_SHELL_DIR' stow/shell/dot-profile
# Should return nothing

# Verify sentinel does not leak into child shells
(
  unset DOTFILES_SHELL_DIR
  . stow/shell/dot-profile
  test -n "$DOTFILES_SHELL_DIR" && echo "PASS: sentinel set in parent"
  val=$(bash -c 'echo "${DOTFILES_SHELL_DIR:-unset}"')
  test "$val" = "unset" && echo "PASS: sentinel not inherited" || echo "FAIL: sentinel leaked"
)

# Verify hooks use grep -qI (not file command)
grep -rn 'grep -qI' .githooks/
# Should show binary detection lines

# Verify no 'file' command usage remains in hooks
grep -rn '\bfile ' .githooks/
# Should return nothing

# Verify stow-deploy auto-configures core.hooksPath
grep -n 'core.hooksPath' scripts/stow-deploy
# Should show the auto-configuration logic

# Verify command -v is used (not which)
grep -rn '\bwhich\b' .githooks/ scripts/
# Should return nothing
```

## Patterns to Follow

### Sentinel variables must be shell-local

```bash
# CORRECT
DOTFILES_SHELL_DIR="$HOME/dotfiles/stow/shell"

# WRONG — leaks to every child process
export DOTFILES_SHELL_DIR="$HOME/dotfiles/stow/shell"
```

### POSIX-standard binary detection

```bash
# CORRECT — grep -qI is POSIX-portable
if grep -qI '' "$file" 2>/dev/null; then
  echo "text file"
else
  echo "binary file"
fi

# WRONG — 'file' not installed on minimal Ubuntu
if file "$path" | grep -q "text"; then
  echo "text file"
fi
```

### Automate every bootstrap step

```bash
# CORRECT — integrated into deployment
if [ -d "$REPO_ROOT/.githooks" ]; then
  git -C "$REPO_ROOT" config --local core.hooksPath .githooks
fi

# WRONG — relies on humans reading READMEs
# "After cloning, run: bash .githooks/setup"
```

## Anti-Patterns to Avoid

| Anti-Pattern | Why It Failed | Rule |
|---|---|---|
| Exporting guard variables | Child processes inherited sentinel, skipped sourcing | Guards that prevent re-execution must NOT propagate to children |
| Assuming non-POSIX tools exist | `file` absent on minimal Ubuntu, worked on macOS | Use only POSIX-guaranteed utilities in hooks/scripts |
| Manual bootstrap steps | Nobody runs README instructions on headless servers | Automate in deployment script or it will be skipped |
| Testing only on dev machine | macOS has `file`, full env, interactive shell | Test in minimal container matching production target |

## Cross-References

- Shell config architecture: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Stow deploy wrapper: `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md`
- Git signing and hook guards: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Cross-platform deployment: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Enforcement plan: `docs/plans/2026-02-16-refactor-repo-local-enforcement-consolidation-plan.md`
