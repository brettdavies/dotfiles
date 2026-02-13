# Dotfiles

Personal dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/) for syncing across macOS and Linux machines.

> **Note:** Active development of the dotfiles CLI tool has moved to [dotfiles-cli](https://github.com/brettdavies/dotfiles-cli) (Rust). This repository is now primarily a configuration store — the shell scripts in `scripts/` are retained for reference but are being superseded by the Rust rewrite.

## Repository Layout

```text
stow/           Stow packages — each subdirectory symlinks into $HOME
config/shell/   Shell environment fragments sourced by .profile
scripts/        Legacy shell CLI (install, check, sync, tests)
docs/           Architecture docs
```

### Stow Packages

Each directory under `stow/` is a stow package. Files prefixed with `dot-` are converted to dotfiles (`.` prefix) when symlinked via `stow --dotfiles`.

| Package    | What it manages |
|------------|-----------------|
| `bash`     | `.bashrc`, `.bash_profile`, `.bash_aliases` |
| `brew`     | `Brewfile`, `packages.yaml`, `generate-brewfile.sh` |
| `claude`   | `.claude/` (settings, hooks, statusline, CLAUDE.md) |
| `codex`    | `.codex/config.toml` |
| `cursor`   | `.cursor/`, `extensions.txt` |
| `gh`       | `.config/gh/` (GitHub CLI) |
| `ghostty`  | `.config/ghostty/config` |
| `git`      | `.gitconfig`, `.config/git/` (ignore, allowed_signers) |
| `local`    | `.local/bin/env`, macOS LaunchAgent |
| `opencode` | `.config/opencode/config.json` |
| `pip`      | `.config/pip/` |
| `secrets`  | `.secrets` (encrypted via git-crypt) |
| `shell`    | `.profile` |
| `ssh`      | `.ssh/config` (encrypted via git-crypt) |
| `zsh`      | `.zshrc`, `.zprofile`, `.p10k.zsh` |

### Shell Environment (`config/shell/`)

`.profile` resolves the repo root via its own symlink, then sources every `*.sh` file in `config/shell/`. Adding a new file to this directory automatically picks it up — no manifest to maintain.

| File              | Purpose |
|-------------------|---------|
| `caches.sh`       | XDG cache directory locations |
| `claude-code.sh`  | Claude Code environment variables |
| `github.sh`       | GitHub CLI aliases |
| `litellm.sh`      | LiteLLM proxy configuration |
| `lm-studio.sh`    | LM Studio PATH setup |
| `models.sh`       | AI/ML model storage locations (`~/models`) |
| `python.sh`       | Python tooling config (Poetry, etc.) |
| `telemetry.sh`    | Telemetry opt-out environment variables |
| `shell-functions` | Shell utilities (no `.sh` extension — sourced by bashrc/zshrc directly) |

## Quick Start

### Prerequisites

- Git
- [GNU Stow](https://www.gnu.org/software/stow/)
- Homebrew (macOS)

### Install

```bash
git clone <your-repo-url> ~/dotfiles
cd ~/dotfiles
./install.sh
```

The install script handles dependencies, stow symlinking, secrets file creation, and optional package installation.

```text
./install.sh              Full installation
./install.sh --dry-run    Preview without changes
./install.sh --check      Verify current status
./install.sh --verbose    Detailed output
```

### Manual Stow

```bash
cd ~/dotfiles/stow
stow --dotfiles --target="$HOME" shell zsh bash git ssh ghostty gh claude
```

### Restow After Changes

```bash
cd ~/dotfiles/stow
stow --dotfiles --target="$HOME" -R <package>
```

## Secrets Management

Sensitive files are encrypted with [git-crypt](https://github.com/AGWA/git-crypt):

- `stow/secrets/dot-secrets` — API keys and tokens
- `stow/ssh/dot-ssh/config` — SSH host configurations
- `stow/git/dot-config/git/allowed_signers` — SSH allowed signers

### Setup

1. Copy your git-crypt key to `~/.config/git-crypt/key`
2. Run `./install.sh` — encrypted files are unlocked automatically
3. Back up the key file in a password manager

## iCloud Drive Sync (macOS)

A LaunchAgent syncs `~/dev` to iCloud Drive every 5 minutes using `rsync` with hardlinks.

- **Script:** `scripts/sync/sync_dev_to_icloud.sh`
- **LaunchAgent:** `com.user.devtosync.plist` (installed via stow `local` package)
- **Logs:** `scripts/sync/logs/`

```bash
launchctl load ~/Library/LaunchAgents/com.user.devtosync.plist    # start
launchctl unload ~/Library/LaunchAgents/com.user.devtosync.plist  # stop
```

## Cross-Platform Notes

- Shell configs use `$HOME` and conditional `$OSTYPE` checks
- Homebrew setup in `.profile` is gated behind `darwin*` detection
- VS Code stow targets `Library/Application Support/` (macOS only)
- 1Password SSH agent paths in `.ssh/config` and `.gitconfig` are macOS-specific

## License

Personal dotfiles — use at your own risk.
