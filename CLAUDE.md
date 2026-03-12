# Dotfiles Project Instructions

## Deployment Context

This repository is a **configuration store** deployed to thousands of headless Ubuntu servers, plus the development
macOS machine. Everything must be fully automated -- no manual steps, no interactive prompts, no human intervention
during deployment.

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

Stow's `--dotfiles` flag converts `dot-` to `.` automatically. **Requires Stow >= 2.4.0** — versions 2.3.x have a
bug where `--dotfiles` fails with nested `dot-` directories. Install via Homebrew/Linuxbrew (Ubuntu 24.04 apt only
has 2.3.1).

To add a new package:

1. Create `stow/<package-name>/` with `dot-` prefixed files
2. Add the package name to `SHARED_PACKAGES` or `DESKTOP_PACKAGES` in `scripts/stow-deploy`

### Conflict Resolution (`scripts/stow-deploy`)

GNU Stow has no `--force` flag. The `scripts/stow-deploy` wrapper handles three conflict types:

| Conflict | Cause | Resolution |
|----------|-------|------------|
| Non-stow symlink | Manually created absolute symlink | Remove symlink, restow |
| Existing plain file | Config created by installer | `--adopt` moves file into package, then review or auto-restore |
| Tree folding | Directory-level symlink pollutes repo | Detected and resolved pre-deploy; `--no-folding` prevents recurrence |

**Usage:**

```bash
scripts/stow-deploy --all                     # macOS: shared + desktop packages
scripts/stow-deploy --headless --all          # headless: shared packages only
scripts/stow-deploy ghostty cursor            # shared defaults + explicit extras
```

**Flags:** `--all` expands to `SHARED_PACKAGES` + `DESKTOP_PACKAGES` (macOS) or `SHARED_PACKAGES` only (Linux).
Without `--all`, extra args extend `SHARED_PACKAGES`. `--headless` auto-restores repo versions after adopt.
Encrypted packages (`secrets`, `ssh`, `git`) require git-crypt unlock first.

---

## Shell Config Chain

`.profile` is symlinked to `stow/shell/dot-profile` and sets `DOTFILES_SHELL_DIR` pointing to the stow/shell
directory. Helper files are sourced directly from the repo -- no symlink needed for individual shell helpers:

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

**Critical:** `.zshenv` is the ONLY file zsh sources for non-interactive invocations. Without it,
`ssh host 'command'` with zsh as default shell gets zero environment. See
`docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` for the full zsh vs bash startup file
reference.

---

## Git Authentication

All GitHub and Gist access uses SSH. The `.gitconfig` enforces this globally:

```gitconfig
[url "git@github.com:"]
    insteadOf = https://github.com/
[url "git@gist.github.com:"]
    insteadOf = https://gist.github.com/
```

This transparently rewrites HTTPS URLs to SSH at the git transport layer. No HTTPS credential helpers are needed.

**SSH key convention:** The key must be named `~/.ssh/brett_ed25519` on all machines (macOS and Linux). The SSH
config explicitly references this path with `IdentitiesOnly yes`, so no other key name will be tried.

**Ordering constraint:** After stowing the `git` package, all GitHub operations require SSH authentication. The SSH
key must be deployed and authorized on GitHub before stowing.

## Git Signing

All commits must be signed. The signing infrastructure is cross-platform:

- **macOS:** 1Password SSH agent via `op-ssh-sign-wrapper` → `op-ssh-sign`
- **Ubuntu (headless):** `op-ssh-sign-wrapper` falls back to `ssh-keygen -Y sign` (Linux-only guard prevents macOS downgrade)
- **Signing key:** `user.signingkey` in `.gitconfig` is a literal public key (works with 1Password). Headless
  servers override via `~/.config/git/local` to point to the private key file path (avoids `-U`/ssh-agent
  requirement).

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

- **`main`** -- stable release branch, deployed to all machines. Protected by GitHub ruleset: requires PR to
  merge, squash-only, signed commits.
- **`development`** -- integration branch. Protected by GitHub ruleset: signed commits required.
- **Feature branches** -- created from `development` (e.g., `feat/user-auth`, `fix/shell-startup`). Merged to
  `development` via PR, then `development` merged to `main` when ready.

Never commit directly to `main`. All work goes through feature branches and PRs.

### Enforcement

- **Remote (GitHub):** Rulesets exported to `.github/rulesets/`. Main requires PR + squash merge + signed commits.
  Development requires signed commits.
- **Local (git hooks):** `.githooks/pre-commit` blocks commits on `main` and verifies `commit.gpgsign = true`.
  Activated via `core.hooksPath`.

---

## Cross-Platform Considerations

When adding or modifying configuration:

- Use `$HOME`, never hardcoded paths like `/Users/brett/` or `/home/brett/`
- Gate macOS-only features behind `[[ "$OSTYPE" == darwin* ]]` or `uname -s` checks
- Gate Homebrew paths: check both `/opt/homebrew` (macOS) and `/home/linuxbrew/.linuxbrew` (Linux)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths
- All GitHub/Gist URLs are forced through SSH via `url.insteadOf` in `.gitconfig`
- SSH key must be `~/.ssh/brett_ed25519` on all machines (standardized name)
- Assume no GUI, no desktop app, no interactive prompts on Ubuntu servers
- Default shell is zsh everywhere -- `.zshenv` is the non-interactive entry point

---

## GitHub Actions

All workflows live in `.github/workflows/`. When adding or modifying actions:

- **Node.js 24 required:** Set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` as a top-level `env` in every workflow.
  Node.js 20 actions are deprecated and will stop working after June 2, 2026.
- **Commit signing:** The release bot (`github-actions[bot]`) creates unsigned commits. The `development` branch
  ruleset requires signed commits, so bot commits from `main` cannot be merged into `development` directly. Sync
  `main` into `development` via GitHub UI merge or cherry-pick only signed commits.

---

## Reference

- Signing architecture: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Shell config fixes: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Cross-platform deployment: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
