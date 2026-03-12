# Dotfiles

Personal dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/) for syncing across macOS and Linux machines.

> **Note:** Active development of the dotfiles CLI tool has moved to
> [dotfiles-cli](https://github.com/brettdavies/dotfiles-cli) (Rust). This repository is now a configuration store.

## Repository Layout

```text
stow/              Stow packages — each subdirectory symlinks into $HOME
config/shell/      Shell environment fragments sourced by .profile
.githooks/         Repo-local git hooks (activated via core.hooksPath)
.github/           GitHub platform config (rulesets, CI)
scripts/stow-deploy  Stow wrapper with automatic conflict resolution
scripts/sync/      iCloud sync scripts
```

### Stow Packages

Each directory under `stow/` is a stow package. Files prefixed with `dot-` are converted to dotfiles (`.` prefix)
when symlinked via `stow --dotfiles`.

| Package    | What it manages |
|------------|-----------------|
| `bash`     | `.bashrc`, `.bash_profile`, `.bash_aliases` |
| `brew`     | `Brewfile`, `Brewfile.optional` |
| `claude`   | `.claude/` (settings, hooks, statusline, CLAUDE.md) |
| `codex`    | `.codex/config.toml` |
| `cursor`   | `.cursor/`, `extensions.txt` |
| `gh`       | `.config/gh/` (GitHub CLI), `.local/bin/gh` (merge guard wrapper) |
| `ghostty`  | `.config/ghostty/config` |
| `git`      | `.gitconfig`, `.config/git/` (ignore, allowed_signers) |
| `launchagent` | `~/Library/LaunchAgents/` (macOS only, no `dot-` prefix needed) |
| `local`    | `.local/bin/env`, `.local/bin/op-ssh-sign-wrapper` |
| `opencode` | `.config/opencode/config.json` |
| `pip`      | `.config/pip/` |
| `secrets`  | `.secrets` (encrypted via git-crypt) |
| `shell`    | `.profile` |
| `ssh`      | `.ssh/config` (encrypted via git-crypt) |
| `zsh`      | `.zshrc`, `.zprofile`, `.p10k.zsh` |

### Shell Environment (`config/shell/`)

`.profile` resolves the repo root via its own symlink, then sources every `*.sh` file in `config/shell/`. Adding a
new file to this directory automatically picks it up — no manifest to maintain.

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

## Bootstrap a New Machine

### 1. Install Homebrew (macOS)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"   # Apple Silicon
```

### 2. Install core tools

```bash
brew install stow git-crypt
```

> **Stow >= 2.4.0 required.** Versions 2.3.x have a [bug with `--dotfiles` and nested directories][stow-bug] that
> breaks packages like `ssh`, `git`, and `gh`. Install via Homebrew/Linuxbrew to get the latest version. Ubuntu
> 24.04's apt repo only has 2.3.1.

[stow-bug]: https://github.com/aspiers/stow/issues/33

### 3. Clone and unlock

```bash
git clone git@github.com:brettdavies/dotfiles.git ~/dotfiles
cd ~/dotfiles
git-crypt unlock ~/.config/git-crypt/key
```

> **SSH preferred:** After the gitconfig is stowed, all GitHub URLs are rewritten to SSH via `url.insteadOf`. Using
> SSH for the initial clone keeps things consistent. HTTPS also works for the initial clone since the rewrite rules
> aren't active yet.
>
> The git-crypt key must be copied from a secure backup (password manager). Without it, `stow/secrets/dot-secrets`
> and `stow/ssh/dot-ssh/config` remain encrypted.

### 4. Stow packages

Use the `stow-deploy` wrapper for automatic conflict resolution:

```bash
cd ~/dotfiles

# macOS: all packages (shared + desktop)
scripts/stow-deploy --all

# Headless servers: shared packages only
scripts/stow-deploy --headless --all
```

`--all` deploys `SHARED_PACKAGES` on Linux and `SHARED_PACKAGES + DESKTOP_PACKAGES` on macOS (see
`scripts/stow-deploy` for the lists). Without `--all`, extra args extend the shared defaults:

```bash
scripts/stow-deploy                   # shared packages only
scripts/stow-deploy ghostty cursor    # shared + ghostty + cursor
```

The wrapper handles non-stow symlinks, existing plain files (`--adopt`), tree-fold detection/resolution, and always
uses `--no-folding`. It also auto-configures `core.hooksPath=.githooks` for repo-local hooks (pre-commit branch
protection, git-crypt auto-unlock, Git LFS chaining). The `--headless` flag auto-restores repo versions after adopt.

**Manual alternative** (without conflict resolution — package lists must match arrays in `scripts/stow-deploy`):

```bash
cd ~/dotfiles/stow

# macOS (shared + desktop)
stow --dotfiles --no-folding --target="$HOME" \
  secrets shell zsh bash git ssh gh local claude codex opencode pip brew \
  ghostty cursor launchagent

# Headless (shared only)
stow --dotfiles --no-folding --target="$HOME" \
  secrets shell zsh bash git ssh gh local claude codex opencode pip brew
```

### 5. Install packages from Brewfile

```bash
brew bundle --file=~/dotfiles/stow/brew/Brewfile
```

Optional packages:

```bash
brew bundle --file=~/dotfiles/stow/brew/Brewfile.optional
```

### 6. Set up oh-my-zsh

Install oh-my-zsh:

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

#### macOS — symlink brew packages into oh-my-zsh

Homebrew installs the plugins and theme as formulae. They need to be symlinked into oh-my-zsh's custom directory:

```bash
BREW_SHARE="$(brew --prefix)/share"
OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"

# Plugins
mkdir -p "$OMZ_CUSTOM/plugins"
ln -sf "$BREW_SHARE/zsh-autosuggestions"     "$OMZ_CUSTOM/plugins/zsh-autosuggestions"
ln -sf "$BREW_SHARE/zsh-syntax-highlighting" "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting"
ln -sf "$BREW_SHARE/zsh-completions"         "$OMZ_CUSTOM/plugins/zsh-completions"

# Theme
mkdir -p "$OMZ_CUSTOM/themes"
ln -sf "$BREW_SHARE/powerlevel10k" "$OMZ_CUSTOM/themes/powerlevel10k"
```

#### Linux — git clone into oh-my-zsh

```bash
OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"

# Plugins
git clone https://github.com/zsh-users/zsh-autosuggestions     "$OMZ_CUSTOM/plugins/zsh-autosuggestions"
git clone https://github.com/zsh-users/zsh-syntax-highlighting "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting"
git clone https://github.com/zsh-users/zsh-completions         "$OMZ_CUSTOM/plugins/zsh-completions"

# Theme
git clone --depth=1 https://github.com/romkatv/powerlevel10k   "$OMZ_CUSTOM/themes/powerlevel10k"
```

### 7. macOS — Ghostty Application Support symlink

Ghostty on macOS checks both `~/.config/ghostty/` (created by stow) and
`~/Library/Application Support/com.mitchellh.ghostty/`. Create the second symlink manually:

```bash
mkdir -p "$HOME/Library/Application Support/com.mitchellh.ghostty"
ln -sf ~/dotfiles/stow/ghostty/dot-config/ghostty/config \
  "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
```

### 8. macOS — iCloud sync LaunchAgent

The `launchagent` package uses `Library/` (no `dot-` prefix) because `~/Library` doesn't start with a dot. Stow it
normally — included in `stow-deploy` desktop packages on macOS:

```bash
# Already handled by: scripts/stow-deploy ghostty cursor launchagent
# Or manually:
cd ~/dotfiles/stow
stow --dotfiles --no-folding --target="$HOME" launchagent
launchctl load "$HOME/Library/LaunchAgents/com.user.devtosync.plist"
```

### 9. Install Cursor extensions

```bash
while IFS= read -r ext; do
  [[ "$ext" =~ ^[[:space:]]*#|^$ ]] && continue
  cursor --install-extension "$(echo "$ext" | xargs)"
done < ~/dotfiles/stow/cursor/extensions.txt
```

### 10. Restart shell

```bash
exec zsh
```

### Restow after changes

```bash
cd ~/dotfiles/stow
stow --dotfiles --target="$HOME" -R <package>
```

## Secrets Management

Sensitive files are encrypted with [git-crypt](https://github.com/AGWA/git-crypt):

- `stow/secrets/dot-secrets` — API keys and tokens
- `stow/ssh/dot-ssh/config` — SSH host configurations
- `stow/git/dot-config/git/allowed_signers` — SSH allowed signers

Git hooks in `.githooks/` auto-unlock on checkout and merge.

Back up the key file (`~/.config/git-crypt/key`) in a password manager. If lost, encrypted files cannot be recovered.

## Release Automation

Every squash merge to `main` triggers a GitHub Action that:

1. Computes a CalVer version (`YYYY.MM.DD`, with `.N` suffix
   for same-day releases, in `America/Los_Angeles` timezone)
2. Generates `CHANGELOG.md` from conventional commits via
   [git-cliff](https://git-cliff.org/)
3. Commits the changelog, tags the release, and creates a
   GitHub Release

### RELEASE_TOKEN secret

The workflow pushes back to protected `main`, which requires a
fine-grained PAT stored as the `RELEASE_TOKEN` repo secret.

**Create / rotate the token:**

```bash
# Token is stored in 1Password
op read "op://secrets-dev/dotfiles_RELEASE_TOKEN/credential" \
  | gh secret set RELEASE_TOKEN
```

If the token expires or is revoked, the release workflow will
fail silently (the merge itself still succeeds). Re-run the
command above to restore it.

**Creating a new PAT** (if the 1Password entry doesn't exist):

1. Go to <https://github.com/settings/personal-access-tokens/new>
2. **Repository access:** `brettdavies/dotfiles` only
3. **Permissions:** Contents: Read and write
4. Save the token to 1Password at
   `secrets-dev/dotfiles_RELEASE_TOKEN`
5. Run the `gh secret set` command above

## Cross-Platform Notes

- Shell configs use `$HOME` and conditional `$OSTYPE` checks
- Homebrew setup in `.profile` is gated behind `darwin*` detection
- VS Code stow targets `Library/Application Support/` (macOS only)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths (macOS and Linux)
- Git signing uses `op-ssh-sign-wrapper` with cross-platform fallback (1Password on macOS, `ssh-keygen` on Linux)
- All GitHub/Gist URLs are rewritten from HTTPS to SSH via `url.insteadOf` in `.gitconfig`
- SSH key must be named `~/.ssh/brett_ed25519` on all machines
- oh-my-zsh plugins: brew symlinks on macOS, git clones on Linux

## License

Personal dotfiles — use at your own risk.
