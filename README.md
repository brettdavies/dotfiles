# Dotfiles

Cross-platform dotfiles for macOS and headless Ubuntu servers — managed with
[GNU Stow](https://www.gnu.org/software/stow/), secured with [git-crypt](https://github.com/AGWA/git-crypt).

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

For detailed platform-specific setup (oh-my-zsh, Ghostty, Cursor extensions, iCloud sync), see
[BOOTSTRAP.md](BOOTSTRAP.md).

[stow-bug]: https://github.com/aspiers/stow/issues/33

## Repository Layout

```text
dotfiles/
├── stow/                  Stow packages (symlinked into $HOME; ollama targets /etc)
├── config/
│   ├── shell/             Shell fragments auto-sourced by .profile
│   ├── git/               Per-platform git config templates
│   ├── qmd/               Per-platform qmd collections templates
│   ├── apparmor.d/        System-level AppArmor profiles (deployed via apparmor-deploy.sh)
│   └── systemd/system/    System-level units (NAS mounts via nas-deploy.sh, apparmor-playwright via apparmor-deploy.sh)
├── scripts/
│   ├── stow-deploy        Stow wrapper with conflict resolution
│   ├── nas-deploy.sh      System-level NAS mount/automount deploy
│   ├── apparmor-deploy.sh System-level AppArmor profile deploy + boot unit (Playwright/Chromium)
│   ├── playwright-browsers-deploy.sh  Playwright browser binaries into the shared cache (curl + unzip)
│   ├── playwright-deps-deploy.sh  Playwright browser launch provisioning (binaries + apparmor + opt-in browser deps)
│   ├── *-enable.sh        Service enablers (qmd-serve, qmd-launchd, opendataloader-pdf)
│   ├── tailscale-serve-setup.sh   Reproducible tailnet serve config (svc:ollama)
│   ├── macos-gpu-monitor.sh       Metal GPU residency/power trace around any command (macOS)
│   ├── generate-changelog.py      Release changelog extraction
│   ├── tools-atime/       Multi-package-manager unused-tool audit + reclaim
│   └── sync/              iCloud, Box, and Claude Code session pipeline sync
├── .githooks/             Repo-local git hooks (core.hooksPath)
├── .github/
│   ├── workflows/         CI: release.yml, shellcheck.yml, bats.yml
│   └── rulesets/          Branch protection rules (protect-dev, protect-main)
├── tests/                 bats-core test suites
└── docs/
    ├── solutions/         Solved problems and patterns (symlink to a separate private repo)
    ├── plans/             Implementation plans
    ├── runbooks/          Operational runbooks (GPU driver drift, Playwright launch)
    └── brainstorms/       Design explorations
```

### Stow Packages

Each directory under `stow/` is a package. Files prefixed with `dot-` become dotfiles (`.` prefix) when symlinked via
`stow --dotfiles`.

| Package              | What it manages                                                                                                                    |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `bash`               | `.bashrc`, `.bash_profile`, `.bash_aliases`                                                                                        |
| `brew`               | `Brewfile`, `Brewfile.optional`                                                                                                    |
| `bun`                | `.bunfig.toml`                                                                                                                     |
| `caam`               | `.caam/` (Claude account rotation config + vault, git-crypt encrypted)                                                             |
| `caddy`              | `.config/caddy/Caddyfile`, `caddy.service` — loopback proxy fronting Ollama for `svc:ollama` (Host rewrite) (Linux only)           |
| `claude`             | `.claude/` (settings, hooks, statusline, templates), `.markdownlint-cli2.yaml`                                                     |
| `codex`              | `.codex/config.toml`                                                                                                               |
| `codex-proxy`        | systemd user unit for the docker-compose codex-proxy backend (Linux only)                                                          |
| `cursor`             | `.cursor/rules/`, `extensions.txt`                                                                                                 |
| `gh`                 | `.config/gh/` (GitHub CLI config), `.local/bin/gh` (merge guard wrapper)                                                           |
| `ghostty`            | `.config/ghostty/config`                                                                                                           |
| `git`                | `.gitconfig`, `.config/git/` (ignore, allowed\_signers)                                                                            |
| `github`             | `.config/github/` (PR template and other repo-workflow assets)                                                                     |
| `gbrain`             | systemd user units for `gbrain sync` (every 15m) and `gbrain dream` (nightly); config deploys cross-platform, units are Linux-only |
| `gogcli`             | `.config/gogcli/config.json` — Google Workspace CLI config                                                                         |
| `launchagent`        | `~/Library/LaunchAgents/` (macOS only)                                                                                             |
| `lazygit`            | `.config/lazygit/config.yml` — clipboard over SSH via OSC 52                                                                       |
| `local`              | `.local/bin/` (env, op-ssh-sign-wrapper, tmux-new-session, uuidv7)                                                                 |
| `micro`              | `.config/micro/settings.json` — editor settings                                                                                    |
| `obsidian`           | `.config/obsidian/`, systemd service, CLI wrapper (Linux only)                                                                     |
| `ollama`             | systemd service override binding Ollama to loopback `127.0.0.1:11434`; system-level, stowed into `/etc` with `sudo` (Linux only)   |
| `opencode`           | `.config/opencode/config.json`                                                                                                     |
| `opendataloader-pdf` | Socket-activated hybrid PDF server with idle-exit, systemd user units (Linux only)                                                 |
| `pip`                | `.config/pip/pip.conf`                                                                                                             |
| `qmd`                | `.local/bin/qmd` wrapper + systemd user units (qmd-serve daemon, embed + update timers, Linux only)                                |
| `rclone`             | `.config/rclone/`, Box bisync systemd service + timer (Linux only)                                                                 |
| `rust`               | `rustup-update.service` + `.timer` (nightly rustup self-update, Linux, opt-in)                                                     |
| `secrets`            | `.secrets` (git-crypt encrypted)                                                                                                   |
| `ssh`                | `.ssh/config` (git-crypt encrypted)                                                                                                |
| `tmux`               | `.config/tmux/tmux.conf`                                                                                                           |
| `tmuxinator`         | `.config/tmuxinator/*.yml` — declarative session configs (20 projects, see below)                                                  |
| `yazi`               | `.config/yazi/` — file manager config, keymaps, theme, packages                                                                    |
| `zsh`                | `.zshrc`, `.zshenv`, `.zprofile`, `.p10k.zsh`                                                                                      |

Two packages deploy outside the `stow-deploy --all` flow: `caddy` (the Linux-only Ollama proxy host) is stowed
explicitly with `scripts/stow-deploy caddy`, and `ollama` targets `/etc` rather than `$HOME`, stowed with `sudo stow -t
/etc -d stow ollama` (see [stow/ollama/README.md](stow/ollama/README.md)).

### Tmuxinator Sessions

Every `.config/tmuxinator/*.yml` config defines the same 3-pane working layout: yazi on the left (1/3 width, full
height), a bare shell top-right (2/3 × 2/3), and lazygit bottom-right (2/3 × 1/3). All three panes start in the
project's root.

Start or attach to a configured session with `tmuxinator start <name>` — it creates the session on the first call and
attaches on every subsequent call, so the same command works whether or not the session is already running:

```bash
tmuxinator start anc                          # local terminal
mux start anc                                 # zsh shell alias (same thing)
ssh <dev-host> -t tmuxinator start anc        # over SSH (preferred connection idiom)
```

Raw `tmux attach -t <name>` only works after the session has already been started, which makes it the wrong default for
SSH.

To create a new session from scratch (config + symlink + first start in one shot), use `tmux-new-session <name>
<repo-path>` — it writes a new tmuxinator config into `stow/tmuxinator/dot-config/tmuxinator/`, re-stows the package,
then runs `tmuxinator start`.

### System-Level Units (`config/systemd/system/`)

System-level systemd units are **not** managed by stow (which targets `$HOME`). They live in `config/systemd/system/`
and are deployed via `scripts/nas-deploy.sh`, which copies them to `/etc/systemd/system/` and activates them.

| Unit                | Purpose                                         |
| ------------------- | ----------------------------------------------- |
| `mnt-nas.mount`     | SMB mount for the NAS (`//<nas-host>/openclaw`) |
| `mnt-nas.automount` | On-demand automount, solves WiFi boot race      |

**Deploy:** `sudo scripts/nas-deploy.sh` (requires `/root/.smbcredentials-<nas-host>` from 1Password).

Two more system-level configs deploy through their own paths: `apparmor-playwright.service` (with the AppArmor profile,
via `scripts/apparmor-deploy.sh`, below) and the `ollama` loopback override (`sudo stow -t /etc`, see the `ollama`
package).

### Playwright / browse browser launch (`scripts/playwright-deps-deploy.sh`)

On Linux the `browse` tool and Playwright e2e need three things to launch browsers: the browser binaries in the shared
cache, an AppArmor profile (for Chromium's sandbox), and, for Safari/iOS testing, WebKit system libraries. One script
provisions all three, run as your normal user (it escalates to sudo only where needed):

```bash
scripts/playwright-deps-deploy.sh            # browser binaries + AppArmor profile + boot persistence (Chromium / browse)
scripts/playwright-deps-deploy.sh --webkit   # + Safari/iOS system libs (WebKit, heavy ~380 MB)
scripts/playwright-deps-deploy.sh --all       # + Chromium and WebKit system libs
```

The **browser binaries** are provisioned into the shared cache (`$PLAYWRIGHT_BROWSERS_PATH`) by
`scripts/playwright-browsers-deploy.sh` (run directly, or via the script above) using `curl` + `unzip` rather than
`playwright install` — node's extractor deadlocks on this host's io_uring/kernel combo. One canonical version serves
every repo, so per-repo `playwright install` becomes a no-op; bumping it is a dotfiles edit (the revision map in that
script). WebKit deps are opt-in because they pull ~180 packages and are only needed for Safari/iOS e2e (the `mobile-ios`
/ `tablet` projects). See [docs/runbooks/playwright-browser-launch.md](docs/runbooks/playwright-browser-launch.md) for
failure signatures, the io_uring root cause, and recovery.

**AppArmor profiles** (`config/apparmor.d/`) are deployed by `scripts/apparmor-deploy.sh` (called by the script above,
or run standalone as `sudo scripts/apparmor-deploy.sh`), which copies each file to `/etc/apparmor.d/`, loads it with
`apparmor_parser -r`, and installs `apparmor-playwright.service` to reload it at boot. The boot unit is required because
Ubuntu's own `apparmor.service` is skipped at boot on minimized server images, so `/etc/apparmor.d/` is otherwise never
reloaded and the profile drops on reboot.

| Profile      | Purpose                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------- |
| `playwright` | Grants `userns` to Playwright's bundled Chromium so the browse tool works on Ubuntu 24.04 |

### Shell Environment (`config/shell/`)

`.profile` sources every `*.sh` file in `config/shell/` automatically — drop a file in and it's picked up, no manifest
needed.

| File                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `build-flags.sh`    | Native-CPU build flags (`-march=native`) for local compilation |
| `caam.sh`           | Claude account rotation wrapper + daemon                       |
| `caches.sh`         | XDG cache directory locations                                  |
| `claude-code.sh`    | Claude Code environment variables                              |
| `gbrain.sh`         | Default `gbrain doctor` to `--fast`                            |
| `github.sh`         | GitHub CLI aliases                                             |
| `gogcli.sh`         | Google Workspace CLI keyring password injection                |
| `languagetool.sh`   | LanguageTool wrapper for the shared prose-lint stage           |
| `litellm.sh`        | LiteLLM proxy configuration                                    |
| `lm-studio.sh`      | LM Studio PATH setup                                           |
| `local-paths.sh`    | Custom local PATH additions                                    |
| `models.sh`         | AI/ML model storage locations                                  |
| `platform-linux.sh` | Linux-specific platform checks and config                      |
| `python.sh`         | Python tooling config                                          |
| `qmd.sh`            | `QMD_REMOTE_URL` export (qmd-serve daemon URL)                 |
| `run-flags.sh`      | Runtime performance env vars (CUDA, io_uring, PyTorch) — Linux |
| `supply-chain.sh`   | Supply-chain safety (package age gates)                        |
| `taildrive.sh`      | Taildrive mount helpers (macOS)                                |
| `telemetry.sh`      | Telemetry opt-out environment variables                        |
| `tmuxinator.sh`     | `mux` and `mux-all` tmuxinator wrappers                        |
| `xurl.sh`           | Alias `xurl` to the `xr` binary (xurl-rs)                      |
| `shell-functions`   | Interactive shell utilities (sourced by bashrc/zshrc)          |

## Secrets Management

Sensitive files are encrypted with git-crypt:

- `stow/secrets/dot-secrets` — API keys and tokens
- `stow/ssh/dot-ssh/config` — SSH host configurations
- `stow/git/dot-config/git/allowed_signers` — SSH allowed signers

Git hooks auto-unlock on checkout and merge. Back up `~/.config/git-crypt/key` in a password manager — if lost,
encrypted files cannot be recovered.

## Git Hooks

Activated via `core.hooksPath` (set automatically by `stow-deploy`):

| Hook            | Purpose                                             |
| --------------- | --------------------------------------------------- |
| `pre-commit`    | Blocks commits on `main`, verifies `commit.gpgsign` |
| `post-checkout` | Auto-unlocks git-crypt, chains Git LFS              |
| `post-merge`    | Auto-unlocks git-crypt, chains Git LFS              |
| `pre-push`      | Mirrors CI (shellcheck + bats), chains Git LFS      |

## CI and Testing

| Workflow         | Trigger        | Purpose                                             |
| ---------------- | -------------- | --------------------------------------------------- |
| `release.yml`    | Push to `main` | CalVer tag, changelog via git-cliff, GitHub Release |
| `shellcheck.yml` | Pull request   | Lints shell scripts and hooks                       |
| `bats.yml`       | Pull request   | Runs the bats-core test suites                      |

`shellcheck.yml` and `bats.yml` are required status checks on `dev` and `main`. They run on every pull request with no
path filter so the required context is always reported. The `pre-push` hook runs the same shellcheck and bats checks
locally and skips them for markdown-only pushes.

Shell scripts are tested with [bats-core](https://github.com/bats-core/bats-core) (`bats tests/`). Suites cover
stow-deploy, git hooks, shell config, supply-chain age gates, symlinks, the qmd-serve and opendataloader-pdf units, and
the CLI wrappers.

## Performance

Shell startup budgets are enforced — non-interactive shells must start under 200ms, interactive shells under 500ms.

See `docs/solutions/performance-issues/` for optimization details.

## Cross-Platform Notes

- `$OSTYPE` checks gate macOS-specific features; `$HOME` used everywhere
- Homebrew paths: `/opt/homebrew` (macOS) vs `/home/linuxbrew/.linuxbrew` (Linux)
- Git signing: 1Password on macOS, `ssh-keygen` fallback on Linux (via `op-ssh-sign-wrapper`)
- SSH config uses `Match exec` for platform-conditional 1Password agent paths
- All GitHub/Gist URLs rewritten to SSH via `url.insteadOf` in `.gitconfig`
- SSH key: `~/.ssh/brett_ed25519` on all machines
- oh-my-zsh plugins: brew symlinks on macOS, git clones on Linux

## Release Automation

Every squash merge to `main` triggers a GitHub Action that computes a CalVer version (`YYYY.MM.DD`), tags the commit,
and creates a GitHub Release. Release notes are extracted from the topmost section of the committed `CHANGELOG.md`. See
[RELEASES.md](RELEASES.md) for the end-to-end flow (feature branch → dev → `release/*` cherry-pick branch → main).

### CI_RELEASE_TOKEN Secret

The workflow pushes back to protected `main`, which requires a fine-grained PAT stored as the `CI_RELEASE_TOKEN` repo
secret.

**Create / rotate the token:**

```bash
op read "op://secrets-dev/dotfiles_RELEASE_TOKEN/credential" \
  | gh secret set CI_RELEASE_TOKEN
```

**Creating a new PAT** (if the 1Password entry doesn't exist):

1. Go to <https://github.com/settings/personal-access-tokens/new>
2. **Repository access:** `brettdavies/dotfiles` only
3. **Permissions:** Contents: Read and write
4. Save to 1Password at `secrets-dev/dotfiles_RELEASE_TOKEN`
5. Run the `gh secret set` command above

## Documentation

Project vocabulary is defined in [CONCEPTS.md](CONCEPTS.md). Operational runbooks live in `docs/runbooks/` (headless GPU
driver drift, Playwright browser launch). Past solutions and design decisions live in `docs/solutions/` (a symlink to a
separate private repo):

- **Deployment** — cross-platform stow deployment, shell config fixes, headless git signing, conflict resolution
- **Configuration** — branch divergence reconciliation, workflow enforcement
- **Performance** — shell startup optimization, zsh interactive startup tuning

## License

Personal dotfiles — use at your own risk.
