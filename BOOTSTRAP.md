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

### Claude Account Rotation (cswap)

`cswap` manages multiple Claude accounts and switches between them as each nears its rate limit. It ships as a Python
tool rather than a stow package, so install it directly on every machine:

```bash
uv tool install claude-swap
```

Accounts are registered per machine with `cswap add`, or copied from an existing machine with `cswap export <path>` and
`cswap import <path>`. An export is **plaintext credentials**: transfer it over an encrypted channel and delete both
copies once the import succeeds.

Rotation runs as a scheduled `cswap auto --once` check, once a minute. The trip point and the rest of the auto-switch
settings are applied by script rather than by unit flags, so a hand-run check behaves the same as a scheduled one:

```bash
scripts/cswap-autoswitch-deploy.sh
```

That pins three keys: the trip point at 99% so a switch lands while the account can still serve, the anti-flap margin at
2 so that trip point is reachable, and the API-key-account exclusion, which is already the default but is the one
setting whose flip would start metered spend. It also holds `autoswitch.model` unset, clearing it if an earlier run
pinned it. The script is idempotent and reports what it changed.

Leaving the per-model trigger unset is deliberate. A counted per-model weekly window gates the account outright with no
fallback: once one reads 100% on every account, cswap reports all-exhausted and waits for that window to reset rather
than deciding on the 5-hour and 7-day windows. Today the only scoped window these accounts report is Fable, so counting
it would park rotation on a limit that does not bind the work. Revisit if a scoped window appears for the model actually
in use.

Scheduling the check is per-OS: launchd on macOS (see [macOS-Only Setup](#macos-only-setup)) and a systemd timer on
Linux (see [Linux Server Setup](#linux-server-setup)). Both are safe to enable with one account registered; ticks report
that there is nothing to rotate into and rewrite nothing.

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

**Manual alternative** (without conflict resolution). The package sets below must match `SHARED_PACKAGES` and
`DESKTOP_PACKAGES` in `scripts/stow-deploy`, which are authoritative — read them there rather than trusting this copy if
the two ever disagree:

```bash
cd ~/dotfiles/stow

# macOS (shared + desktop). The Linux-only packages are omitted: stow-deploy
# skips rclone, obsidian, opendataloader-pdf, codex-proxy, and cargo on Darwin.
# --ignore drops the systemd units that cross-platform packages carry.
stow --dotfiles --no-folding --target="$HOME" --ignore='\.(service|timer)$' \
  secrets shell zsh bash git ssh gh github local claude codex opencode pip bun brew \
  rust tmux lazygit micro yazi qmd caddy gogcli ghostty cursor launchagent

# Headless (shared only)
stow --dotfiles --no-folding --target="$HOME" \
  secrets shell zsh bash git ssh gh github local claude codex opencode pip bun brew \
  cargo rust tmux lazygit micro yazi rclone qmd obsidian opendataloader-pdf caddy \
  gogcli codex-proxy
```

`tmuxinator` is deliberately absent from both lists: its session configs are read in place from the repo and stowing
them would shadow the source of truth. `ollama` is also absent — it targets `/etc`, not `$HOME` (see
[stow/ollama/README.md](stow/ollama/README.md)).

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
| `com.user.qmd-update`  | every 5 min + at load | `qmd update` (re-index changed files)                                   |
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

### cswap auto-switching (launchd)

The `launchagent` package ships `com.user.cswap-auto.plist`, which runs the same minutely check as the Linux timer.
Apply the settings first, then load the agent:

```bash
bash ~/dotfiles/scripts/cswap-autoswitch-deploy.sh
cd ~/dotfiles/stow && stow --dotfiles --no-folding --target="$HOME" launchagent
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.cswap-auto.plist
```

Read switch decisions from `~/Library/Logs/cswap-auto.log`. A tick that finds nothing to do exits 2, which launchd
records without treating it as a crash.

## Linux Server Setup

### Rust toolchains

Rust lives only on the Linux hosts. Install rustup with the minimal profile, so no toolchain ever pulls the docs in the
first place:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --profile minimal
```

`scripts/stow-deploy` reconciles the setting on every deploy once the `cargo` package is installed, so a host that
already has rustup gets it without a manual step, and one someone set back to `default` is repaired. Neither hook helps
a toolchain that is already on disk, which is why the flag matters more than the cleanup.

There is no environment variable for this. rustup reads the profile from `~/.rustup/settings.toml`, which it rewrites
itself, so the value can be neither exported from `config/shell` nor stowed: a symlink there would be written through
into the repo.

A repo can close the gap independently of machine state with `profile = "minimal"` in its `rust-toolchain.toml`, which
rustup honors when it auto-installs the pinned toolchain.

The default profile bundles `rust-docs`, roughly 800MB of offline HTML per toolchain and 2.4GB across the three pinned
here. Nothing reads it: the host has no browser, and API lookups go to docs.rs. `minimal` still honors the `components =
["rustfmt", "clippy"]` line in each repo's `rust-toolchain.toml`, so pinned repos get what they ask for and nothing
else.

The setting governs new installs. Removing it from toolchains already on disk is a separate step, and `rustup update`
preserves whatever component set a toolchain currently has:

```bash
for tc in $(rustup toolchain list | awk '{print $1}'); do
  rustup component remove rust-docs --toolchain "$tc" 2>/dev/null || true
done
```

### SSH session locale

A minimal server has no `locales` package and generates only `C.UTF-8`, which `/etc/default/locale` selects. macOS
clients send `LANG=en_US.UTF-8` and Ubuntu's stock sshd accepts it, so every session lands on a locale the box cannot
set and glibc falls back to plain C: `perl` warns on each run, `shellcheck` aborts its report at the first non-ASCII
character, and `sort` and `grep` lose multibyte awareness. Installing `locales` (17 MB) works but adds a package the
server does not otherwise need. Stop accepting the variable instead; `pam_env` then supplies the box default:

```bash
sudo ~/dotfiles/scripts/sshd-locale-deploy.sh
```

The script strips `LANG` and `LC_*` from every `AcceptEnv` directive (main file and `sshd_config.d/` drop-ins),
validates with `sshd -t`, reloads sshd, and is safe to re-run. Sessions already open keep their value, as does a tmux
server started from one; `tmux set-environment -g LANG C.UTF-8` fixes new panes without a restart. The `ssh` package
pins `SetEnv LANG=C.UTF-8` on the affected host entries as the client-side half, so a server that still accepts the
variable gets the right value anyway.

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

The GPU server serves `svc:ollama` over Tailscale Serve as a tailnet service VIP, the single embedding backend shared
across the tailnet. tailscaled keeps serve config in its own state, but a binding can be dropped by a daemon restart or
version upgrade while the `AdvertiseServices` pref survives, leaving a service advertised with nothing bound.
Re-establish the config in one idempotent run (the script fail-fasts if the Caddy proxy above is not up):

```bash
bash ~/dotfiles/scripts/tailscale-serve-setup.sh
```

The script binds `https://ollama.<tailnet>/` to `127.0.0.1:11500` (svc:ollama, then Caddy, then Ollama), then prints
`tailscale serve status`. It is gated to that one host and safe to re-run.

> **One-time admin step:** the service host must be approved once in the
> [admin console](https://login.tailscale.com/admin/services/svc:ollama). An advertised-but-unapproved host gets no VIP
> and the script's binding routes nowhere.

### cswap auto-switching (systemd)

The `cswap` package ships a oneshot unit and the timer that drives it. Apply the settings first, then enable the timer
rather than the service:

```bash
bash ~/dotfiles/scripts/cswap-autoswitch-deploy.sh
cd ~/dotfiles/stow && stow --dotfiles --no-folding --target="$HOME" cswap
systemctl --user daemon-reload
systemctl --user enable --now cswap-auto.timer
```

Read switch decisions with `journalctl --user -u cswap-auto`. Lingering must be on for the timer to run while logged out
(`loginctl enable-linger $USER`); without it the timer looks enabled and never fires after a reboot.

A tick exits 2 when there is nothing to do and 3 when every account is spent and the credential is held. The unit counts
both as success, so the failed-unit list stays meaningful.

## Restart Shell

```bash
exec zsh
```
