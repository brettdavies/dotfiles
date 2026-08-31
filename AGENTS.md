# Dotfiles Project Instructions

## Deployment Context

This repository is a **configuration store** deployed to thousands of headless Ubuntu servers, plus the development
macOS machine. Everything must be fully automated -- no manual steps, no interactive prompts, no human intervention
during deployment.

- **macOS (development):** Single machine, interactive use, 1Password desktop app available
- **Ubuntu servers (headless):** Thousands of machines, non-interactive, no GUI, no 1Password desktop app
- **Default shell:** zsh on all machines (macOS and Ubuntu)
- **This repo is config-only** — configuration payloads plus the scripts that deploy them.

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

Stow's `--dotfiles` flag converts `dot-` to `.` automatically. **Requires Stow >= 2.4.0** — versions 2.3.x have a bug
where `--dotfiles` fails with nested `dot-` directories. Install via Homebrew/Linuxbrew (Ubuntu 24.04 apt only has
2.3.1).

To add a new package:

1. Create `stow/<package-name>/` with `dot-` prefixed files
2. Add the package name to `SHARED_PACKAGES` or `DESKTOP_PACKAGES` in `scripts/stow-deploy`

**Tree folding:** `stow-deploy` passes `--no-folding` globally. This prevents stow from creating directory-level
symlinks (which would pollute the repo when programs write into symlinked dirs). Individual file symlinks are created
instead. No per-package opt-in is needed.

### Conflict Resolution (`scripts/stow-deploy`)

GNU Stow has no `--force` flag. The `scripts/stow-deploy` wrapper handles three conflict types:

| Conflict            | Cause                                 | Resolution                                                           |
| ------------------- | ------------------------------------- | -------------------------------------------------------------------- |
| Non-stow symlink    | Manually created absolute symlink     | Remove symlink, restow                                               |
| Existing plain file | Config created by installer           | `--adopt` moves file into package, then review or auto-restore       |
| Tree folding        | Directory-level symlink pollutes repo | Detected and resolved pre-deploy; `--no-folding` prevents recurrence |

**Usage:**

```bash
scripts/stow-deploy --all                     # macOS: shared + desktop packages
scripts/stow-deploy --headless --all          # headless: shared packages only
scripts/stow-deploy ghostty cursor            # shared defaults + explicit extras
```

**Flags:** `--all` expands to `SHARED_PACKAGES` + `DESKTOP_PACKAGES` (macOS) or `SHARED_PACKAGES` only (Linux). Without
`--all`, extra args extend `SHARED_PACKAGES`. `--headless` auto-restores repo versions after adopt. Encrypted packages
(`secrets`, `ssh`, `git`) require git-crypt unlock first.

### System-Level Units (`config/systemd/system/`)

System-level systemd units (targeting `/etc/systemd/system/`) are **not** managed by stow. Stow targets `$HOME` and
creating symlinks from root-owned system paths into a user-owned directory is a security concern. Instead, these units
are version-controlled in `config/systemd/system/` and deployed via dedicated scripts that `sudo cp` them into place.

**Current units:**

- `mnt-nas.mount` + `mnt-nas.automount` — deployed by `scripts/nas-deploy.sh`

**Pattern for adding new system-level units:**

1. Create the unit file in `config/systemd/system/`
2. Create or extend a deploy script in `scripts/` that copies and activates the unit
3. Do NOT add to `stow/` or `SHARED_PACKAGES`

### AppArmor Profiles (`config/apparmor.d/`)

System-level AppArmor profiles follow the same "not managed by stow" rationale as systemd units. They live in
`config/apparmor.d/` and are deployed via `scripts/apparmor-deploy.sh`, which copies every file to `/etc/apparmor.d/`
and reloads it with `apparmor_parser -r`. Profiles persist across reboots.

**Current profiles:**

- `playwright` — grants `userns` to Playwright's bundled Chromium binaries so the browse tool works on Ubuntu 24.04.
  Without this, Chromium fails sandbox init under `kernel.apparmor_restrict_unprivileged_userns=1`.

**Pattern for adding new profiles:**

1. Drop the profile file in `config/apparmor.d/` (filename must match the `/etc/apparmor.d/` target exactly)
2. Re-run `sudo scripts/apparmor-deploy.sh` — it copies every file in the directory and reloads each one
3. Do NOT add to `stow/` or `SHARED_PACKAGES`

---

## Shell Config Chain

`.profile` is symlinked to `stow/shell/dot-profile` and sets `DOTFILES_SHELL_DIR` pointing to the stow/shell directory.
Helper files are sourced directly from the repo -- no symlink needed for individual shell helpers:

```text
~/.profile (symlink) --> stow/shell/dot-profile
  sources: config/shell/*.sh (telemetry, models, caches, python, paths, etc.)
  sources: ~/.secrets (git-crypt encrypted, tokens + API keys)
  sets up: Homebrew, PATH, Cargo, GPG_TTY

~/.zshenv (symlink) --> stow/zsh/dot-zshenv
  sources: ~/.profile (if not already loaded)
  PURPOSE: ensures non-interactive zsh (SSH commands, cron) has environment

~/.zprofile (symlink) --> stow/zsh/dot-zprofile
  fires AFTER /etc/zprofile in zsh login shells
  PURPOSE: macOS-only — repairs PATH after Apple's /etc/zprofile runs
  /usr/libexec/path_helper -s, which pushes /opt/homebrew/bin behind
  /usr/bin. Re-prepends $HOMEBREW_PREFIX/{bin,sbin}. POSIX-safe,
  idempotent, Darwin-gated (returns 0 on Linux).

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

**Critical:** `.zshenv` is the ONLY file zsh sources for non-interactive invocations. Without it, `ssh host 'command'`
with zsh as default shell gets zero environment. See
`docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` for the full zsh vs bash startup file
reference.

### Supported invocation shapes

The supported set is `{zsh, bash}` x `{login, non-login}` x `{interactive, non-interactive}`. Seven of the eight read at
least one startup file and must end with a fully assembled `PATH`; the eighth reads nothing by design.

| Shell  | Login | Interactive | Reads                                    | Reached by                                           |
| ------ | ----- | ----------- | ---------------------------------------- | ---------------------------------------------------- |
| `zsh`  | yes   | yes         | `.zshenv .zprofile .zshrc`               | terminal window, tmux pane, `ssh host`               |
| `zsh`  | yes   | no          | `.zshenv .zprofile`                      | `zsh -lc`                                            |
| `zsh`  | no    | yes         | `.zshenv .zshrc`                         | `zsh -i`, editor subshells                           |
| `zsh`  | no    | no          | `.zshenv`                                | `ssh host cmd`, cron with `SHELL=zsh`                |
| `bash` | yes   | yes         | `.bash_profile` → `.profile` → `.bashrc` | login console, `bash -l`                             |
| `bash` | yes   | no          | `.bash_profile` → `.profile`             | `bash -lc`                                           |
| `bash` | no    | yes         | `.bashrc` → `.profile`                   | `bash -i`                                            |
| `bash` | no    | no          | nothing, or `$BASH_ENV`                  | `bash script.sh`, git hooks, CI, the agent Bash tool |

The last row is the *bare launcher* case (see [CONCEPTS.md](CONCEPTS.md)): bash has no all-invocations file, so the
shape inherits whatever its launcher handed it. Scripts in that position source the helper they need explicitly, per the
section below. Claude Code's Bash tool is wired through `CLAUDE_ENV_FILE` by `stow/claude/dot-claude/bash-env-path.sh`,
which repairs keg-only Ruby ordering only; it assumes an inherited `PATH` rather than assembling one.

`tests/shell-path-matrix.bats` exercises every row from an `env -i` launchd-style environment, so a pass means the shape
assembles `PATH` itself rather than inheriting it from a working parent shell.

**Environment variables needed by all contexts** (Claude Code, SSH commands, cron, interactive shells) belong in
`.profile` or `config/shell/*.sh` — never in `.zshrc`/`.bashrc`. Consult the startup file matrix in
`docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` before choosing a location.

**`config/shell/*.sh` must use functions, not aliases.** These files are sourced by `.profile` under POSIX `sh` where
aliases don't exist. Aliases belong in `.zshrc`/`.bashrc` (after the interactive guard) only.

**External scripts that need a helper must source it explicitly.** `.profile`'s auto-source loop in
`stow/shell/dot-profile` runs only for shells that read `.profile` (interactive zsh/bash; non-interactive zsh via the
`.zshenv` → `.profile` chain). A script invoked as `bash scripts/foo.sh` (e.g. from a git pre-push hook, CI runner, or
`gh` action) is **non-login bash** and reads no startup files at all — `DOTFILES_SHELL_DIR` is unset and the helper
functions are not defined. Such scripts must source the file themselves:

```bash
LT_LIB="${DOTFILES_SHELL_DIR:-$HOME/dotfiles/config/shell}/languagetool.sh"
if [[ ! -f "$LT_LIB" ]]; then
  echo "scripts/foo: required helper $LT_LIB not found (install brettdavies/dotfiles)" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$LT_LIB"
```

The `DOTFILES_SHELL_DIR` fallback to `$HOME/dotfiles/config/shell` works when the script is invoked from any shell —
interactive (var is set by `.profile`) or non-interactive (var is unset; the literal path resolves on both Linux and
macOS since the dotfiles repo lives at `~/dotfiles` on both). See `scripts/prose-check.sh` in any agentnative-* repo for
the live pattern.

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

**SSH key convention:** The key must be named `~/.ssh/brett_ed25519` on all machines (macOS and Linux). The SSH config
explicitly references this path with `IdentitiesOnly yes`, so no other key name will be tried.

**Ordering constraint:** After stowing the `git` package, all GitHub operations require SSH authentication. The SSH key
must be deployed and authorized on GitHub before stowing.

## Git Signing

All commits must be signed. The signing infrastructure is cross-platform:

- **macOS:** 1Password SSH agent via `op-ssh-sign-wrapper` → `op-ssh-sign`
- **Ubuntu (headless):** `op-ssh-sign-wrapper` falls back to `ssh-keygen -Y sign` (Linux-only guard prevents macOS
  downgrade)
- **Signing key:** `user.signingkey` in `.gitconfig` is a literal public key (works with 1Password). Headless servers
  override via `~/.config/git/local` to point to the private key file path (avoids `-U`/ssh-agent requirement).

See `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md` for the full signing architecture.

---

## Git Hooks

Git hooks live in `.githooks/` and are activated via `core.hooksPath`:

```bash
git config core.hooksPath .githooks
```

This is set during bootstrap (see README) or via `bash .githooks/setup`.

| Hook            | Purpose                                                            |
| --------------- | ------------------------------------------------------------------ |
| `pre-commit`    | Branch + signing policy, then the CI checks scoped to staged files |
| `post-checkout` | Auto-unlocks git-crypt if key is available, chains Git LFS         |
| `post-merge`    | Auto-unlocks git-crypt if key is available, chains Git LFS         |
| `pre-push`      | Full local CI mirror, then chains Git LFS pre-push                 |

### Local gates mirror CI

The hooks exist so a red pipeline is a surprise rather than a routine. Every check is defined once, in a script that all
three gates call:

| Check      | Definition           | CI job                             | pre-push | pre-commit           |
| ---------- | -------------------- | ---------------------------------- | -------- | -------------------- |
| ShellCheck | `scripts/lint-shell` | `.github/workflows/shellcheck.yml` | `--all`  | staged paths         |
| Bats       | `scripts/run-tests`  | `.github/workflows/bats.yml`       | `--all`  | staged `.bats` files |

`pre-push` is the repo-wide mirror: its steps map one-to-one onto CI jobs, and passing it should mean passing the
pipeline. `pre-commit` runs the same scripts over staged paths only, so it stays fast enough for every commit while
catching the same class of failure. The two policy checks in `pre-commit` (protected branch, signing) have no CI
equivalent because they govern how a commit is made rather than what is in it.

**Adding a CI job means adding a step to `pre-push` that calls the same script.** Put the target list and per-tool flags
in the script, never in a hook or a workflow, so the three cannot drift. `tests/lint-shell.bats` and
`tests/run-tests.bats` cover the dispatchers themselves.

A missing tool skips its step with an install hint instead of failing, so a machine without the full toolchain can still
commit and push; CI stays the backstop. `.githooks/lib/report.sh` holds the shared pass/skip/fail output helpers.

---

## Branch Workflow

- **`main`** -- stable release branch, deployed to all machines. Protected by GitHub ruleset: requires PR to merge,
  squash-only, signed commits.
- **`dev`** -- integration branch. Protected by GitHub ruleset: signed commits required.
- **Feature branches** -- created from `dev` (e.g., `feat/user-auth`, `fix/shell-startup`). Merged to `dev` via PR, then
  `dev` merged to `main` when ready.

Never commit directly to `main`. All work goes through feature branches and PRs.

### Enforcement

- **Remote (GitHub):** Rulesets exported to `.github/rulesets/`. Main requires PR + squash merge + signed commits.
  Development requires signed commits.
- **Local (git hooks):** `.githooks/pre-commit` blocks commits on `main` and verifies `commit.gpgsign = true`, then runs
  the CI checks over staged paths; `.githooks/pre-push` runs the full CI mirror. Activated via `core.hooksPath`. See
  [Local gates mirror CI](#local-gates-mirror-ci).

---

## Cross-Platform Considerations

When adding or modifying configuration:

- Use `$HOME`, never hardcoded user-home paths like `/Users/<you>/` or `/home/<you>/`
- Gate macOS-only features behind `[[ "$OSTYPE" == darwin* ]]` or `uname -s` checks
- Gate Homebrew paths: check both `/opt/homebrew` (macOS) and `/home/linuxbrew/.linuxbrew` (Linux)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths
- All GitHub/Gist URLs are forced through SSH via `url.insteadOf` in `.gitconfig`
- SSH key must be `~/.ssh/brett_ed25519` on all machines (standardized name)
- Assume no GUI, no desktop app, no interactive prompts on Ubuntu servers
- Default shell is zsh everywhere -- `.zshenv` is the non-interactive entry point

---

## Shell Script Conventions

All shell scripts and hooks in this repo follow these conventions:

- **Error prefixes:** Use UPPERCASE severity — `ERROR:`, `WARNING:`, `NOTE:`, `FATAL:` — followed by a space and the
  message. Always output to stderr via `>&2`.
- **Binary wrappers** (e.g., `op-ssh-sign-wrapper`) use `programname: message` format instead, which is the standard
  Unix convention for utilities identifying themselves.

---

## GitHub Actions

All workflows live in `.github/workflows/`. When adding or modifying actions:

- **Node.js 24 required:** Set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` as a top-level `env` in every workflow.
  Node.js 20 actions are deprecated and will stop working after June 2, 2026.
- **Commit signing:** The release bot (`github-actions[bot]`) creates unsigned commits. The `dev` branch ruleset
  requires signed commits, so bot commits from `main` cannot be merged into `dev` directly. Sync `main` into `dev` via
  GitHub UI merge or cherry-pick only signed commits.

---

## Reference

- `CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts) with project-specific meaning.
  Relevant when orienting to the codebase or discussing domain concepts.
- `docs/solutions/` (symlink to `~/dev/solutions-docs`) — documented solutions organized by category
  (`deployment-issues/`, `integration-issues/`, `configuration-fixes/`, etc.) with YAML frontmatter (`module`, `tags`,
  `problem_type`, `applies_when`). Relevant when debugging or implementing in documented areas; search with `qmd query
  "<topic>" --collection solutions`.
- Signing architecture: `docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`
- Shell config fixes: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Cross-platform deployment: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Cross-platform stow package gating (file-level `--ignore` for scattered OS-specific content):
  `docs/solutions/architecture-patterns/cross-platform-stow-package-gating-2026-05-17.md`
- Headless Cloudflare wrangler + scoped API token in 1P:
  `docs/solutions/developer-experience/cloudflare-api-token-headless-wrangler-1password-2026-04-13.md`
