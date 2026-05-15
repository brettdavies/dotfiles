# Bootstrap Guide

Detailed setup instructions for new machines. For a quick overview, see [README.md](README.md).

## Prerequisites

### Homebrew

**macOS (Apple Silicon):**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**Linux:**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

### Core Tools

```bash
brew install stow git-crypt
```

> **Stow >= 2.4.0 required.** Versions 2.3.x have a
> [bug with `--dotfiles` and nested directories][stow-bug] that breaks
> packages like `ssh`, `git`, and `gh`. Ubuntu 24.04 apt only has 2.3.1 —
> use Homebrew/Linuxbrew.

[stow-bug]: https://github.com/aspiers/stow/issues/33

## Clone and Unlock

```bash
git clone git@github.com:brettdavies/dotfiles.git ~/dotfiles
cd ~/dotfiles
git-crypt unlock ~/.config/git-crypt/key
```

The git-crypt key must be copied from a secure backup (password manager). Without it, `stow/secrets/dot-secrets` and
`stow/ssh/dot-ssh/config` remain encrypted.

> **SSH preferred:** After the gitconfig is stowed, all GitHub URLs are
> rewritten to SSH via `url.insteadOf`. Using SSH for the initial clone
> keeps things consistent. HTTPS also works since the rewrite rules
> aren't active yet.

## Deploy Stow Packages

```bash
cd ~/dotfiles

# macOS: all packages (shared + desktop)
scripts/stow-deploy --all

# Headless servers: shared packages only
scripts/stow-deploy --headless --all

# Selective: shared defaults + specific extras
scripts/stow-deploy ghostty cursor
```

The wrapper handles non-stow symlinks, existing plain files (`--adopt`), and tree-fold detection. It always uses
`--no-folding` and auto-configures `core.hooksPath=.githooks`. The `--headless` flag auto-restores repo versions after
adopt.

**Manual alternative** (without conflict resolution):

```bash
cd ~/dotfiles/stow

# macOS (shared + desktop)
stow --dotfiles --no-folding --target="$HOME" \
  secrets shell zsh bash git ssh gh github local claude codex opencode pip bun brew \
  tmux tmuxinator lazygit micro yazi caam gogcli ghostty cursor launchagent

# Headless (shared only)
stow --dotfiles --no-folding --target="$HOME" \
  secrets shell zsh bash git ssh gh github local claude codex opencode pip bun brew \
  tmux tmuxinator lazygit micro yazi rclone qmd obsidian opendataloader-pdf caam gogcli
```

### Restow After Changes

```bash
cd ~/dotfiles/stow
stow --dotfiles --no-folding --target="$HOME" -R <package>
```

## Install Packages from Brewfile

```bash
brew bundle --file=~/dotfiles/stow/brew/Brewfile
```

Optional packages:

```bash
brew bundle --file=~/dotfiles/stow/brew/Brewfile.optional
```

## oh-my-zsh

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

### macOS — Symlink Brew Packages

Homebrew installs plugins and the theme as formulae. Symlink them into oh-my-zsh's custom directory:

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

### Linux — Git Clone

```bash
OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"

# Plugins
git clone https://github.com/zsh-users/zsh-autosuggestions     "$OMZ_CUSTOM/plugins/zsh-autosuggestions"
git clone https://github.com/zsh-users/zsh-syntax-highlighting "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting"
git clone https://github.com/zsh-users/zsh-completions         "$OMZ_CUSTOM/plugins/zsh-completions"

# Theme
git clone --depth=1 https://github.com/romkatv/powerlevel10k   "$OMZ_CUSTOM/themes/powerlevel10k"
```

## Tmux Plugins

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
~/.tmux/plugins/tpm/scripts/install_plugins.sh
```

> TPM reads the plugin list from `~/.config/tmux/tmux.conf` (deployed by the `tmux` stow package).

## macOS-Only Setup

### Ghostty Application Support Symlink

Ghostty checks both `~/.config/ghostty/` (created by stow) and `~/Library/Application Support/com.mitchellh.ghostty/`:

```bash
mkdir -p "$HOME/Library/Application Support/com.mitchellh.ghostty"
ln -sf ~/dotfiles/stow/ghostty/dot-config/ghostty/config \
  "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
```

### iCloud Sync LaunchAgent

Already deployed by `stow-deploy --all` on macOS. To load manually:

```bash
launchctl load "$HOME/Library/LaunchAgents/com.user.devtosync.plist"
```

### Cursor Extensions

```bash
while IFS= read -r ext; do
  [[ "$ext" =~ ^[[:space:]]*#|^$ ]] && continue
  cursor --install-extension "$(echo "$ext" | xargs)"
done < ~/dotfiles/stow/cursor/extensions.txt
```

### Rectangle Window Manager

Installed by `brew bundle` from the Brewfile. First-launch requires Accessibility permission, then run the defaults
script to lock in the Recommended preset, enable size-cycling on repeated presses, and disable macOS native tiling so
Rectangle is the sole snapper.

```bash
# 1. Launch Rectangle once and grant Accessibility permission
open -a Rectangle
# System Settings → Privacy & Security → Accessibility → toggle Rectangle ON

# 2. Apply preferences (idempotent; re-run any time)
bash ~/dotfiles/scripts/rectangle-defaults.sh
```

Hotkeys after setup: `⌃⌥←/→/↑/↓` for halves, `⌃⌥U/I/J/K` for quarters, `⌃⌥↵` maximize, `⌃⌥⌫` restore previous size.
Repeat the same arrow to cycle 1/2 → 2/3 → 1/3 width.

## Restart Shell

```bash
exec zsh
```
