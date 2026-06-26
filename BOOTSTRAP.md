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

### Ruby Bundler (supply-chain cooldown)

`config/shell/local-paths.sh` puts Homebrew's keg-only Ruby ahead of the macOS system Ruby 2.6, but Homebrew's Ruby
bundles a Bundler that may lag the `>= 4.0.13` the cooldown policy needs (`config/shell/supply-chain.sh`). Install a
current Bundler into Homebrew's Ruby once per machine:

```bash
"$(brew --prefix ruby)/bin/gem" install bundler -v '~> 4.0' --no-document
```

Open a fresh shell, then confirm `bundle --version` reports `4.0.13` or newer.

## oh-my-zsh

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

### Zsh plugins and theme

`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`, and `powerlevel10k` are all installed by `brew
bundle` (Brewfile entries on both macOS and Linux). They live under `$HOMEBREW_PREFIX/share/`.

- **`zsh-autosuggestions` and `zsh-syntax-highlighting`** are NOT wired through oh-my-zsh's `plugins=(...)` array. Brew
  ships them without the `<name>.plugin.zsh` file omz's `is_plugin()` requires, so `plugins=(zsh-autosuggestions ...)`
  produces `plugin '...' not found` warnings. Instead, `stow/zsh/dot-zshrc` sources them directly from
  `$HOMEBREW_PREFIX/share/...` at the end of the file (with syntax-highlighting last, per its install docs). No symlink
  needed.
- **`zsh-completions`** is loaded via `fpath` (already wired in `stow/zsh/dot-zshrc`). No symlink needed.
- **`powerlevel10k`** is the theme — needs a symlink into `$OMZ_CUSTOM/themes/` so omz's `ZSH_THEME` resolver finds it:

```bash
BREW_SHARE="$(brew --prefix)/share"
OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"

mkdir -p "$OMZ_CUSTOM/themes"
ln -sf "$BREW_SHARE/powerlevel10k" "$OMZ_CUSTOM/themes/powerlevel10k"
```

That's the only manual symlink step. If you're migrating from the old git-clone layout, trash any leftover
`$OMZ_CUSTOM/plugins/zsh-autosuggestions` and `$OMZ_CUSTOM/plugins/zsh-syntax-highlighting` directories — they're unused
now.

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

### QMD LaunchAgents (Knowledge-Base Index Maintenance)

macOS port of the Linux systemd timers under `stow/qmd/dot-config/systemd/user/`. Three LaunchAgents keep the qmd
knowledge-base index fresh:

| Agent                  | Schedule              | What it does                                                            |
| ---------------------- | --------------------- | ----------------------------------------------------------------------- |
| `com.user.qmd-update`  | every 5 min + at load | `qmd cleanup` then `qmd update` (re-index changed files)                |
| `com.user.qmd-embed`   | every 5 min + at load | `qmd embed` with throttled batches (avoids Apple Silicon KV-cache wall) |
| `com.user.qmd-cleanup` | nightly 03:00         | `qmd cleanup` (deeper vacuum, drop stale rerank cache)                  |

After `stow-deploy --all` symlinks the plists into `~/Library/LaunchAgents/`, bootstrap them into the user's GUI domain:

```bash
bash ~/dotfiles/scripts/qmd-launchd-enable.sh
```

The script is idempotent — safe to re-run after editing a plist. Logs land in `~/dotfiles/scripts/qmd-launchd/logs/`
(gitignored). Stop an agent with `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.qmd-<name>.plist`.

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

## Linux Server Setup

### Ollama Host-rewrite proxy (Caddy)

Ollama binds to loopback only (`127.0.0.1:11434`) and 403s any request whose `Host` header is not localhost
(DNS-rebinding protection). Tailscale Serve forwards the original tailnet Host (`ollama.<tailnet>.ts.net`), so the
`svc:ollama` VIP cannot reach Ollama directly. A loopback Caddy proxy rewrites `Host` to localhost before forwarding,
which keeps Ollama off the network. Deploy and enable it before pointing the serve VIP at it:

```bash
brew bundle --file=~/dotfiles/stow/brew/Brewfile          # installs caddy on Linux
cd ~/dotfiles/stow && stow --dotfiles --no-folding --target="$HOME" caddy
systemctl --user daemon-reload
systemctl --user enable --now caddy.service
```

Caddy listens on `127.0.0.1:11500` only and forwards to `127.0.0.1:11434`.

### Tailscale Serve

`bigdaddy` serves `svc:ollama` over Tailscale Serve as a tailnet service VIP, the single embedding backend for the
shared gbrain. tailscaled keeps serve config in its own state, but a binding can be dropped by a daemon restart or
version upgrade while the `AdvertiseServices` pref survives, leaving a service advertised with nothing bound.
Re-establish the config in one idempotent run (the script fail-fasts if the Caddy proxy above is not up):

```bash
bash ~/dotfiles/scripts/tailscale-serve-setup.sh
```

The script binds `https://ollama.<tailnet>/` to `127.0.0.1:11500` (svc:ollama, then Caddy, then Ollama), then prints
`tailscale serve status`. It is host-gated to `bigdaddy` and safe to re-run.

> **One-time admin step:** the service host must be approved once in the
> [admin console](https://login.tailscale.com/admin/services/svc:ollama). An advertised-but-unapproved host gets no VIP
> and the script's binding routes nowhere.

## Restart Shell

```bash
exec zsh
```
