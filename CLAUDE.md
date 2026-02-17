# Dotfiles Project Instructions

## Deployment Context

This repository is a **configuration store** deployed to thousands of headless Ubuntu servers, plus the development macOS machine. Everything must be fully automated -- no manual steps, no interactive prompts, no human intervention during deployment.

- **macOS (development):** Single machine, interactive use, 1Password desktop app available
- **Ubuntu servers (headless):** Thousands of machines, non-interactive, no GUI, no 1Password desktop app
- **Default shell:** zsh on all machines (macOS and Ubuntu)
- **Active CLI tooling** lives in [dotfiles-cli](https://github.com/brettdavies/dotfiles-cli) (Rust). This repo is config-only.

### Automation Requirements

- Clone + unlock + stow must be scriptable with zero interaction
- Git hooks auto-install via `core.hooksPath` (no manual `cp` commands)
- Shell environment must work for both interactive and non-interactive zsh
- Git signing must work headless (ssh-keygen fallback, no 1Password dependency)
- Per-host overrides via `~/.config/git/local` (not tracked in repo)

---

## Stow Packages

Packages live in `stow/<package-name>/`. Files use the `dot-` prefix convention:

- `stow/git/dot-config/git/ignore` becomes `~/.config/git/ignore`
- `stow/zsh/dot-zshrc` becomes `~/.zshrc`

Stow's `--dotfiles` flag converts `dot-` to `.` automatically.

To add a new package:

1. Create `stow/<package-name>/` with `dot-` prefixed files
2. The package is auto-discovered during deployment

---

## Shell Config Chain

`.profile` is symlinked to `stow/shell/dot-profile` and sets `DOTFILES_SHELL_DIR` pointing to the stow/shell directory. Helper files are sourced directly from the repo -- no symlink needed for individual shell helpers:

```text
~/.profile (symlink) --> stow/shell/dot-profile
  sources: config/shell/*.sh (telemetry, models, caches, python, paths, etc.)
  sources: ~/.secrets (git-crypt encrypted, tokens + API keys)
  sets up: Homebrew, PATH, Cargo, GPG_TTY

~/.zshenv (symlink) --> stow/zsh/dot-zshenv
  sources: ~/.profile (if not already loaded)
  PURPOSE: ensures non-interactive zsh (SSH commands, cron) has environment

~/.bashrc (symlink) --> stow/bash/dot-bashrc
  sources: ~/.profile (if not already loaded)
  INTERACTIVE GUARD: case $- in *i*) ;; *) return;; esac
  sources: $DOTFILES_SHELL_DIR/shell-functions (interactive only)
  sets up: history, completion, prompt, aliases, OSC 7

~/.zshrc (symlink) --> stow/zsh/dot-zshrc
  sources: ~/.profile (redundant with .zshenv, sentinel guard skips)
  INTERACTIVE GUARD: [[ $- == *i* ]] || return
  sources: $DOTFILES_SHELL_DIR/shell-functions (interactive only)
  sets up: oh-my-zsh, history, modules, completions, p10k
```

**Critical:** `.zshenv` is the ONLY file zsh sources for non-interactive invocations. Without it, `ssh host 'command'` with zsh as default shell gets zero environment. See `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` for the full zsh vs bash startup file reference.

---

## Git Signing

All commits must be signed. The signing infrastructure is cross-platform:

- **macOS:** 1Password SSH agent via `op-ssh-sign-wrapper` → `op-ssh-sign`
- **Ubuntu (headless):** `op-ssh-sign-wrapper` falls back to `ssh-keygen -Y sign` (Linux-only guard prevents macOS downgrade)
- **Signing key:** `user.signingkey` in `.gitconfig` is a literal public key (works with 1Password). Headless servers override via `~/.config/git/local` to point to the private key file path (avoids `-U`/ssh-agent requirement).

See `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md` for the full signing architecture.

---

## Git Hooks

Git hooks live in `.githooks/` and are activated via `core.hooksPath`:

```bash
git config core.hooksPath .githooks
```

This is set during bootstrap (see README) or via `bash .githooks/setup`.

| Hook | Purpose |
|------|---------|
| `pre-commit` | Blocks commits on `main`, verifies `commit.gpgsign = true` |
| `post-checkout` | Auto-unlocks git-crypt if key is available, chains Git LFS |
| `post-merge` | Auto-unlocks git-crypt if key is available, chains Git LFS |
| `pre-push` | Chains Git LFS pre-push |

---

## Branch Workflow

- **`main`** -- stable release branch, deployed to all machines. Protected by GitHub ruleset: requires PR to merge, squash-only, signed commits.
- **`development`** -- integration branch. Protected by GitHub ruleset: signed commits required.
- **Feature branches** -- created from `development` (e.g., `feat/user-auth`, `fix/shell-startup`). Merged to `development` via PR, then `development` merged to `main` when ready.

Never commit directly to `main`. All work goes through feature branches and PRs.

### Enforcement

- **Remote (GitHub):** Rulesets exported to `.github/rulesets/`. Main requires PR + squash merge + signed commits. Development requires signed commits.
- **Local (git hooks):** `.githooks/pre-commit` blocks commits on `main` and verifies `commit.gpgsign = true`. Activated via `core.hooksPath`.

---

## Cross-Platform Considerations

When adding or modifying configuration:

- Use `$HOME`, never hardcoded paths like `/Users/brett/` or `/home/brett/`
- Gate macOS-only features behind `[[ "$OSTYPE" == darwin* ]]` or `uname -s` checks
- Gate Homebrew paths: check both `/opt/homebrew` (macOS) and `/home/linuxbrew/.linuxbrew` (Linux)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths
- Assume no GUI, no desktop app, no interactive prompts on Ubuntu servers
- Default shell is zsh everywhere -- `.zshenv` is the non-interactive entry point

---

## Reference

- Signing architecture: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Shell config fixes: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Cross-platform deployment: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
