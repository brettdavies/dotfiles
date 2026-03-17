# Dotfiles

Cross-platform dotfiles for macOS and headless Ubuntu servers — managed with
[GNU Stow](https://www.gnu.org/software/stow/), secured with
[git-crypt](https://github.com/AGWA/git-crypt).

## Quick Start

```bash
# 1. Install Homebrew (skip if already installed)
#    macOS
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
#    Linux
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# 2. Install core tools
brew install stow git-crypt

# 3. Clone and unlock
git clone git@github.com:brettdavies/dotfiles.git ~/dotfiles
cd ~/dotfiles
git-crypt unlock ~/.config/git-crypt/key

# 4. Deploy
scripts/stow-deploy --all              # macOS: shared + desktop packages
scripts/stow-deploy --headless --all   # Linux: shared packages only
```

> **Stow >= 2.4.0 required.** Ubuntu 24.04 apt only has 2.3.1, which has a
> [bug with nested `dot-` directories][stow-bug]. Use Homebrew/Linuxbrew.

For detailed platform-specific setup (oh-my-zsh, Ghostty, Cursor extensions,
iCloud sync), see [BOOTSTRAP.md](BOOTSTRAP.md).

[stow-bug]: https://github.com/aspiers/stow/issues/33

## Repository Layout

```text
dotfiles/
├── stow/                  Stow packages (symlinked into $HOME)
├── config/
│   ├── shell/             Shell fragments auto-sourced by .profile
│   └── git/               Per-platform git config templates
├── scripts/
│   ├── stow-deploy        Stow wrapper with conflict resolution
│   └── sync/              iCloud sync scripts
├── .githooks/             Repo-local git hooks (core.hooksPath)
├── .github/
│   ├── workflows/         CI: release.yml, shellcheck.yml
│   └── rulesets/          Branch protection rules
├── tests/                 bats-core test suites
└── docs/
    ├── solutions/         Solved problems and patterns
    ├── plans/             Implementation plans
    └── brainstorms/       Design explorations
```

### Stow Packages

Each directory under `stow/` is a package. Files prefixed with `dot-` become
dotfiles (`.` prefix) when symlinked via `stow --dotfiles`.

| Package       | What it manages                                                            |
|---------------|----------------------------------------------------------------------------|
| `bash`        | `.bashrc`, `.bash_profile`, `.bash_aliases`                                |
| `brew`        | `Brewfile`, `Brewfile.optional`                                            |
| `claude`      | `.claude/` (settings, hooks, statusline, templates), `.markdownlint-cli2.yaml` |
| `codex`       | `.codex/config.toml`                                                       |
| `cursor`      | `.cursor/rules/`, `extensions.txt`                                         |
| `gh`          | `.config/gh/` (GitHub CLI config), `.local/bin/gh` (merge guard wrapper)   |
| `ghostty`     | `.config/ghostty/config`                                                   |
| `git`         | `.gitconfig`, `.config/git/` (ignore, allowed\_signers)                    |
| `launchagent` | `~/Library/LaunchAgents/` (macOS only)                                     |
| `lazygit`     | `.config/lazygit/config.yml` — clipboard over SSH via OSC 52              |
| `local`       | `.local/bin/` (env, op-ssh-sign-wrapper, tmux-new-session)                 |
| `opencode`    | `.config/opencode/config.json`                                             |
| `pip`         | `.config/pip/pip.conf`                                                     |
| `secrets`     | `.secrets` (git-crypt encrypted)                                           |
| `shell`       | `.profile`                                                                 |
| `ssh`         | `.ssh/config` (git-crypt encrypted)                                        |
| `tmux`        | `.config/tmux/tmux.conf`                                                   |
| `yazi`        | `.config/yazi/` — file manager config, keymaps, theme, packages            |
| `zsh`         | `.zshrc`, `.zshenv`, `.zprofile`, `.p10k.zsh`                              |

### Shell Environment (`config/shell/`)

`.profile` sources every `*.sh` file in `config/shell/` automatically — drop a
file in and it's picked up, no manifest needed.

| File                 | Purpose                                  |
|----------------------|------------------------------------------|
| `caches.sh`          | XDG cache directory locations            |
| `claude-code.sh`     | Claude Code environment variables        |
| `github.sh`          | GitHub CLI aliases                       |
| `litellm.sh`         | LiteLLM proxy configuration              |
| `lm-studio.sh`       | LM Studio PATH setup                    |
| `local-paths.sh`     | Custom local PATH additions              |
| `models.sh`          | AI/ML model storage locations            |
| `platform-linux.sh`  | Linux-specific platform checks and config |
| `python.sh`          | Python tooling config                    |
| `telemetry.sh`       | Telemetry opt-out environment variables  |
| `shell-functions`    | Interactive shell utilities (sourced by bashrc/zshrc) |

## Secrets Management

Sensitive files are encrypted with git-crypt:

- `stow/secrets/dot-secrets` — API keys and tokens
- `stow/ssh/dot-ssh/config` — SSH host configurations
- `stow/git/dot-config/git/allowed_signers` — SSH allowed signers

Git hooks auto-unlock on checkout and merge. Back up
`~/.config/git-crypt/key` in a password manager — if lost, encrypted
files cannot be recovered.

## Git Hooks

Activated via `core.hooksPath` (set automatically by `stow-deploy`):

| Hook            | Purpose                                                  |
|-----------------|----------------------------------------------------------|
| `pre-commit`    | Blocks commits on `main`, verifies `commit.gpgsign`      |
| `post-checkout` | Auto-unlocks git-crypt, chains Git LFS                   |
| `post-merge`    | Auto-unlocks git-crypt, chains Git LFS                   |
| `pre-push`      | Chains Git LFS pre-push                                  |

## CI and Testing

| Workflow          | Trigger              | Purpose                                     |
|-------------------|----------------------|---------------------------------------------|
| `release.yml`     | Squash merge to main | CalVer tag, changelog via git-cliff, release |
| `shellcheck.yml`  | Push / PR            | Lints shell scripts                         |

Shell scripts are tested with [bats-core](https://github.com/bats-core/bats-core)
(`bats tests/`). Suites cover stow-deploy, git hooks, shell config, symlinks,
and CLI wrappers.

## Performance

Shell startup budgets are enforced — non-interactive shells must start under 200ms, interactive shells under 500ms.  
  
See `docs/solutions/performance-issues/` for optimization details.

## Cross-Platform Notes

- `$OSTYPE` checks gate macOS-specific features; `$HOME` used everywhere
- Homebrew paths: `/opt/homebrew` (macOS) vs `/home/linuxbrew/.linuxbrew` (Linux)
- Git signing: 1Password on macOS, `ssh-keygen` fallback on Linux
  (via `op-ssh-sign-wrapper`)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths
- All GitHub/Gist URLs rewritten to SSH via `url.insteadOf` in `.gitconfig`
- SSH key: `~/.ssh/brett_ed25519` on all machines
- oh-my-zsh plugins: brew symlinks on macOS, git clones on Linux

## Release Automation

Every squash merge to `main` triggers a GitHub Action that computes a
CalVer version (`YYYY.MM.DD`), generates a changelog via
[git-cliff](https://git-cliff.org/), and creates a GitHub Release.

### RELEASE_TOKEN Secret

The workflow pushes back to protected `main`, which requires a
fine-grained PAT stored as the `RELEASE_TOKEN` repo secret.

**Create / rotate the token:**

```bash
op read "op://secrets-dev/dotfiles_RELEASE_TOKEN/credential" \
  | gh secret set RELEASE_TOKEN
```

**Creating a new PAT** (if the 1Password entry doesn't exist):

1. Go to <https://github.com/settings/personal-access-tokens/new>
2. **Repository access:** `brettdavies/dotfiles` only
3. **Permissions:** Contents: Read and write
4. Save to 1Password at `secrets-dev/dotfiles_RELEASE_TOKEN`
5. Run the `gh secret set` command above

## Documentation

Past solutions and design decisions live in `docs/solutions/`:

- **Deployment** — cross-platform stow deployment, shell config fixes,
  headless git signing, conflict resolution
- **Configuration** — branch divergence reconciliation, workflow enforcement
- **Performance** — shell startup optimization, zsh interactive startup tuning

## License

Personal dotfiles — use at your own risk.
