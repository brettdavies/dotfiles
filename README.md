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
│   ├── launchd/           macOS launchd user PATH for GUI apps and LaunchAgents (via launchd-user-path.sh)
│   └── systemd/system/    System-level units (NAS mounts via nas-deploy.sh, apparmor-playwright via apparmor-deploy.sh)
├── scripts/
│   ├── stow-deploy        Stow wrapper with conflict resolution
│   ├── nas-deploy.sh      System-level NAS mount/automount deploy
│   ├── apparmor-deploy.sh System-level AppArmor profile deploy + boot unit (Playwright/Chromium)
│   ├── sshd-locale-deploy.sh  Strip LANG/LC_* from sshd AcceptEnv so sessions use the server locale
│   ├── playwright-browsers-deploy.sh  Playwright browser binaries into the shared cache (curl + unzip)
│   ├── playwright-deps-deploy.sh  Playwright browser launch provisioning (binaries + apparmor + opt-in browser deps)
│   ├── *-enable.sh        Service enablers (qmd-serve, qmd-launchd, host-jobs)
│   ├── tailscale-serve-setup.sh   Reproducible tailnet serve config (svc:ollama, svc:codex-proxy)
│   ├── tailscale-serve-deploy.sh  System unit that re-runs the serve setup on every tailscaled start
│   ├── macos-gpu-monitor.sh       Metal GPU residency/power trace around any command (macOS)
│   ├── launchd-user-path.sh       Check (or --apply) the launchd user PATH against config/launchd/ (macOS)
│   ├── fseventsd-check.sh         Warn when fseventsd outgrows its launchd memory budget (macOS, run at Claude Code session start)
│   ├── lint-shell, lint-workflows, run-tests   CI gate dispatchers, shared by CI and the git hooks
│   ├── core-env-guard.sh  Fails a test that resets HOME or another core env var (allowlist beside it)
│   ├── generate-changelog.py      Release changelog extraction from merged PR bodies
│   ├── sync-dev-after-release.sh  Backport the released CHANGELOG.md to dev by PR
│   ├── release/           Release gates (drift.sh, guarded-paths.sh)
│   ├── tools-atime/       Multi-package-manager unused-tool audit + reclaim
│   └── sync/              iCloud and Box sync
├── .githooks/             Repo-local git hooks (core.hooksPath)
├── .github/
│   ├── workflows/         CI: release, shellcheck (+ actionlint), bats, and three main-PR guards
│   └── rulesets/          Branch protection rules (protect-dev, protect-main)
├── tests/                 bats-core test suites
└── docs/
    ├── solutions/         Solved problems and patterns (symlink to a separate private repo)
    ├── runbooks/          Operational runbooks (GPU driver drift, Playwright launch)
    ├── plans/             Implementation plans (dev only)
    └── brainstorms/       Design explorations (dev only)
```

The engineering-doc directories marked *dev only* are inert planning text that never ships. They live on `dev`, the
release recipe strips them from the release branch, and `guard-main-docs.yml` blocks them from any PR to `main` — so a
checkout of `main` carries `docs/runbooks/` and the `docs/solutions/` symlink but none of the planning trees.

### Stow Packages

Each directory under `stow/` is a package. Files prefixed with `dot-` become dotfiles (`.` prefix) when symlinked via
`stow --dotfiles`.

| Package       | What it manages                                                                                                                  |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `bash`        | `.bashrc`, `.bash_profile`, `.bash_aliases`                                                                                      |
| `brew`        | `Brewfile`, `Brewfile.optional`                                                                                                  |
| `bun`         | `.bunfig.toml`                                                                                                                   |
| `caddy`       | `.config/caddy/Caddyfile`, `caddy.service` — loopback proxy fronting Ollama for `svc:ollama` (Host rewrite) (Linux only)         |
| `cargo`       | `.cargo/config.toml` (git fetches via the git CLI), `cargo-target-sweep` + weekly timer (stale build output; Linux only)         |
| `claude`      | `.claude/` (settings, hooks, statusline, templates incl. the `gitattributes` canon), `.markdownlint-cli2.yaml`, `.editorconfig`  |
| `codex`       | `.codex/config.toml`                                                                                                             |
| `codex-proxy` | systemd user unit for the docker-compose codex-proxy backend (Linux only)                                                        |
| `cswap`       | systemd timer and oneshot unit running the cswap account rotation check each minute (Linux only)                                 |
| `cursor`      | `.cursor/rules/`, `extensions.txt`                                                                                               |
| `gh`          | `.config/gh/` (GitHub CLI config), `.local/bin/gh` (merge guard wrapper)                                                         |
| `ghostty`     | `.config/ghostty/config`                                                                                                         |
| `git`         | `.gitconfig`, `.config/git/` (ignore, allowed\_signers)                                                                          |
| `github`      | `.config/github/` (PR template and other repo-workflow assets)                                                                   |
| `gogcli`      | `.config/gogcli/config.json` — Google Workspace CLI config                                                                       |
| `launchagent` | `~/Library/LaunchAgents/` (macOS only)                                                                                           |
| `lazygit`     | `.config/lazygit/config.yml` — clipboard over SSH via OSC 52                                                                     |
| `local`       | `.local/bin/` — signing, prose, session, qmd, and commit helpers (see [Local Binaries](#local-binaries)); systemd timers (Linux) |
| `micro`       | `.config/micro/settings.json` — editor settings                                                                                  |
| `obsidian`    | `.config/obsidian/`, systemd service, CLI wrapper, vault-mirror timers (Linux only)                                              |
| `ollama`      | systemd service override binding Ollama to loopback `127.0.0.1:11434`; system-level, stowed into `/etc` with `sudo` (Linux only) |
| `opencode`    | `.config/opencode/config.json`                                                                                                   |
| `pip`         | `.config/pip/pip.conf`                                                                                                           |
| `qmd`         | `.local/bin/qmd` wrapper (both platforms) + systemd user units for the qmd-serve daemon and index timers (Linux)                 |
| `rex`         | `.config/rex/`: Rex's `init.lua`, the dev layout actions, and the agent-slot actions and keys (macOS only)                       |
| `rclone`      | `.config/rclone/`, Box bisync systemd service + timer (Linux only)                                                               |
| `rust`        | `rustup-update.service` + `.timer` (nightly `rustup update stable --no-self-update`; units land on Linux only)                   |
| `secrets`     | `.secrets` (git-crypt encrypted)                                                                                                 |
| `shell`       | `.profile` — the shell config chain's entry file, which auto-sources `config/shell/`                                             |
| `ssh`         | `.ssh/config` (git-crypt encrypted)                                                                                              |
| `tmux`        | `.config/tmux/tmux.conf`                                                                                                         |
| `tmuxinator`  | Session configs read in place from the repo; never stowed (see [Tmuxinator Sessions](#tmuxinator-sessions))                      |
| `yazi`        | `.config/yazi/` — file manager config, keymaps, theme, packages                                                                  |
| `zsh`         | `.zshrc`, `.zshenv`, `.zprofile`, `.p10k.zsh`                                                                                    |

Two directories under `stow/` are not in any package set and never deploy through `stow-deploy`: `ollama` targets `/etc`
rather than `$HOME` and is stowed with `sudo stow -t /etc -d stow ollama` (see
[stow/ollama/README.md](stow/ollama/README.md)), and `tmuxinator` is read in place rather than symlinked. Both are
recorded as exemptions in `tests/stow-deploy-packages.bats`, which fails when any other `stow/` directory is missing
from a package set.

### Local Binaries

The `local` package deploys `stow/local/dot-local/bin/` to `~/.local/bin/`. These are machine-level entry points: repo
hooks, systemd units, and agent tooling call them by name, so each one resolves the same way on every host without
knowing where the underlying implementation lives.

| Binary                     | Purpose                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------- |
| `agent-slot`               | Hand out and tear down full clones of a repo for parallel Claude agents, one task per clone    |
| `agent-slot-rex`           | The Mac half of `agent-slot`: start agents and keep their slot tabs and panes attached in Rex  |
| `backup-openclaw-settings` | Back up OpenClaw's settings to the NAS, run daily by `openclaw-settings-backup.timer`          |
| `brave-search`             | Query the Brave Search API, printing ranked results as plain text or raw JSON                  |
| `charcount`                | Count characters against platform length caps, exiting non-zero so it gates in scripts         |
| `env`                      | Put `~/.local/bin` on `PATH` for user-installed binaries                                       |
| `gh-revision-audit`        | List your issues and PRs that still carry prior edit revisions on GitHub                       |
| `github-stars`             | Clone and update starred GitHub repos under `~/github-stars`, run by the `github-stars` timers |
| `github-stars-pdf`         | Markdown copies of star PDFs marked `convert` in `pdfs.tsv` for qmd; reports new PDFs          |
| `gstack-config-apply`      | Converge `~/.gstack/config.yaml`, which gstack rewrites and so cannot be a stow package        |
| `mac-open`                 | Open a file from yazi on a Linux host on the Mac the session is driven from                    |
| `mac-open-here`            | The Mac half of `mac-open`, run over SSH: open a host file in VS Code or the default app       |
| `op-ssh-sign-wrapper`      | Cross-platform commit signing: 1Password agent on macOS, `ssh-keygen -Y sign` headless         |
| `qmd-gpu-verify`           | Prove the `qmd-serve` daemon runs its model work on the GPU rather than the CPU                |
| `qmd-ollama-unload-all`    | Evict resident Ollama models, but only when VRAM is too low for `qmd embed` to load safely     |
| `sd-commit-doc`            | Commit and push `docs/solutions/` files from the shared clone without racing another agent     |
| `tmux-new-session`         | Write a tmuxinator config for a repo and start its 3-pane session                              |
| `transcribe-diarize`       | Local GPU speaker-diarized transcription (ffmpeg → whisperx → pyannote)                        |
| `unslop`                   | Machine-level entry point for the prose scorer, resolved through `~/.claude/skills`            |
| `unslop-gate`              | Git-hook prose gate over `unslop`, scoring only the markdown in the change being pushed        |
| `uuidv7`                   | Print a time-ordered UUIDv7, used for collision-proof `/tmp` artifact names                    |
| `xurl`                     | Real `xurl` on `PATH` that execs xurl-rs's `xr`, for callers that load no interactive alias    |

### Tmuxinator Sessions

Session configs live in `stow/tmuxinator/dot-config/tmuxinator/` and are **not** stowed. `config/shell/tmuxinator.sh`
exports `TMUXINATOR_CONFIG` to point at that directory, so tmuxinator reads, writes, and lists projects in the repo
itself — `tmuxinator new` and `tmuxinator copy` land on the source of truth with no deploy step.

Keep `~/.config/tmuxinator` empty. tmuxinator searches that path in `start` and `stop` but not in `list`, so a config
sitting there shadows the repo: it starts a session that never appears in `tmuxinator list`. `sudo tmuxinator …` is the
usual way one gets there, because `sudo` scrubs `TMUXINATOR_CONFIG` and falls back to the XDG path — and it strands the
tmux server at UID 0, invisible to your own `tmux ls`. Run tmuxinator as yourself.

Every config defines the same 3-pane working layout: yazi on the left (1/3 width, full height), a bare shell top-right
(2/3 × 2/3), and lazygit bottom-right (2/3 × 1/3), except where the paragraph below notes otherwise. All three panes
start in the project's root.

tmuxinator renders each config through ERB before parsing it, which is how `vault.yml` serves both machines from one
file: it branches on `RUBY_PLATFORM`, rooting at the server's checkout on Linux and at the Taildrive share
(`/Volumes/vault`) on macOS. On macOS an `on_project_start` hook runs `taildrive-mount vault` and ends the start script
when the share does not mount, so no session is created with its panes pointed at a missing directory. The bottom-right
pane there is a plain shell rather than lazygit, because the share exposes the vault's files but not its git dir.
`tests/tmuxinator-configs.bats` renders both branches and checks the emitted script.

The guard covers an absent share, not a wedged one: tmuxinator emits `cd <root>` ahead of every hook, so a mount whose
server has gone away blocks the start script on that `cd` before `taildrive-mount` can report anything. Recover with
`taildrive-unmount` (or `diskutil unmount force /Volumes/vault`) and start again.

Start or attach to a configured session with `tmuxinator start <name>` — it creates the session on the first call and
attaches on every subsequent call, so the same command works whether or not the session is already running:

```bash
tmuxinator start anc                          # local terminal
mux start anc                                 # zsh shell alias (same thing)
ssh <dev-host> -t tmuxinator start anc        # over SSH (preferred connection idiom)
```

Raw `tmux attach -t <name>` only works after the session has already been started, which makes it the wrong default for
SSH.

To create a new session from scratch (config + first start in one shot), use `tmux-new-session <name> <repo-path>` — it
writes a new tmuxinator config into `stow/tmuxinator/dot-config/tmuxinator/`, then runs `tmuxinator start`.

`tmuxinator copy` duplicates a config verbatim, including the source project's `name:` and its `on_project_first_start`
resize targets. Edit both after copying, or the new session resizes panes in the project it was copied from.
`tests/tmuxinator-configs.bats` enforces that every config's resize targets match its own `name:`.

### Yazi Hand-off to the Mac

On a Linux host, yazi's open action (`Enter` or `o` on a file) puts the file on the Mac the session is driven from,
routed by what the file is:

- **Edit route.** Anything yazi would hand to the editor (text, JSON, JavaScript, empty files) opens in VS Code on the
  Mac through Remote-SSH, editing the host's file in place: a save is a write to the host's disk.
- **View route.** Everything else (PDFs, images, audio, video, office documents, unknown binaries) opens in the Mac's
  default app. A file under a Taildrive share opens in place at `/Volumes/<share>/…`, and the share is mounted first
  when it is not; the share roots come from `tailscale drive list`. A file outside every share is streamed to the Mac as
  a copy in `~/Downloads/mac-open/`, where nothing is ever deleted automatically, and yazi says so: edits to a copy do
  not write back.

The hand-off runs only when the SSH connection driving the session comes from the Mac. Inside tmux that is the session's
most recently active client, whose address `tailscale whois` must name as the Mac. From the host's console, or from a
session attached from any other device, files open locally as they always do there. When the session is not from the
Mac, the Mac cannot be reached, or the hand-off fails, text falls back to `$EDITOR` and PDFs to the local `pdftotext`
view in micro; other types have no local opener on a headless host. Every such outcome prints one `mac-open: <reason>`
line naming the next step, and yazi shows it as a notification once the fallback editor exits. For text, the `O` picker
still offers the local `$EDITOR`; a PDF reaches the local text view only when the hand-off fails. Directories open as
they always do, archives extract on the host, and yazi's bulk rename and bulk create keep using the local editor, since
yazi reads their list back when the editor exits.

Setup, from a merged change to the first file on the Mac:

1. On the Linux host: `cd ~/dotfiles && git pull && scripts/stow-deploy local yazi`.
2. On the Mac: the same two commands in `~/dotfiles`.
3. On the Mac: System Settings → General → Sharing → Remote Login (ⓘ) → turn on "Allow full disk access for remote
   users". Without it, an SSH session cannot read a Taildrive share, and in-place viewing fails with `no-disk-access`.
   The grant covers every SSH session on the Mac, including the one this host's key opens, so a compromised host could
   then read the Mac's protected data; leaving it off keeps text edits and copies working and gives up only in-place
   viewing.
4. Quit and restart every yazi already running in a tmux pane. yazi reads its openers only at startup, and `ya emit`
   notifications fail while any yazi from before a yazi upgrade is still running.
5. Press `Enter` on a markdown file; a VS Code tab opens on the Mac. The first connection after a VS Code update
   installs its server on the host and takes a few seconds longer.

The Mac is reached by its SSH alias with `BatchMode`, a 3 s connect timeout, and a hard 20 s bound per call (plus 1 s
per MiB for a copy); Ctrl-C abandons a hand-off in progress, which is the way out of a large copy. Overrides:
`MAC_OPEN_HOST` (the Mac's SSH alias, which is also its tailnet name) and `MAC_OPEN_SERVER_ALIAS` (this host as the
Mac's SSH config names it, default `hostname -s`) on the Linux host; `MAC_OPEN_CODE_CLI` (the VS Code CLI inside the app
bundle by default) on the Mac. `tests/mac-open.bats` and `tests/mac-open-here.bats` stub every external command, and
`tests/yazi-config.bats` pins the routing table in `yazi.toml`, which replaces yazi's built-in one.

### Parallel Agents

Many Claude Code agents can work on the same repo at once, each in an *agent slot*: a full clone of the repo at
`~/slots/<repo>/<N>` on the Linux server, set up like the repo's own checkout (its hooks, the `docs/solutions` link, its
Claude memory and permission grants), with one task per slot. `agent-slot` on the server owns every slot and every check
before a slot is deleted; `agent-slot-rex` on the Mac drives Rex, where each repo is one session and each agent one tab.
Every slot runs three tmux sessions on the server's `agent-slots` socket (Claude, yazi, and lazygit), so agents keep
working while the Mac sleeps, and each pane of a slot's tab reattaches by itself after a sleep or a network drop.

A slot stays while its task is open, review rounds included, and is deleted only once the task has finished (its PRs
merged with none open, or the operator finished it) and nothing in it is missing from origin. Anything else keeps it on
the *needs-you list*, shown on its tab and in the `agent-slots` control session.

#### Setup

1. Deploy both machines: `scripts/stow-deploy --headless --all` on the Linux server, then enable its prune timer with
   `systemctl --user enable --now tmux-prune-orphans-slots.timer`; `scripts/stow-deploy --all` on the Mac, which also
   reloads Rex's config (see BOOTSTRAP.md for moving a hand-written `~/.config/rex` aside first).
2. Run `agent-slot-rex doctor` on the Mac. It checks the Mac's side, then runs `agent-slot doctor` on the server, with
   every next step written to run through the ssh alias.
3. Run `agent-slot warm <repo>` on the server for the repos you use, so a first launch there skips Claude's trust step.
   A slot is trusted automatically only for a repo whose prime checkout you have trusted in Claude, because trust lets
   Claude load the repo's own settings and hooks; open Claude once in any other repo's prime checkout first.

#### Keys and tab labels

| Key         | Action                                                                                          |
| ----------- | ----------------------------------------------------------------------------------------------- |
| `cmd+alt+n` | Start an agent on the session's repo in a background tab; focus stays where it is               |
| `cmd+alt+r` | Give every live slot its tab back, resume dormant slots, and close tabs whose slot is gone      |
| `cmd+alt+f` | Finish the focused tab's task (no open PR) and delete its slot when nothing in it would be lost |

A slot's tab is labelled `<repo>/<N>`, then `· <task>` (the task name, or the agent's branch once it has one), then:

- `· trust needed` when the repo's prime checkout is not trusted in Claude, or Claude's trust dialog for the slot path
  did not look as expected: accept it in the tab;
- `· needs you: <first blocker>` when something keeps the slot from being deleted;
- `<repo> · launch failed` on a launch tab that stopped, with the error, its next step, and its log; Enter retries a
  retryable failure with the same request ID, and q closes the tab.

#### Commands

On the Linux server, `agent-slot repos` lists the repos a slot can be made from, `agent-slot list` every slot with its
state, agent, and blockers, and `agent-slot whoami` the slot a directory is in. `agent-slot launch <repo> --request-id
<id> [--prompt-file <file>]` starts an agent, and agents use it to hand a task to a slot; a repeat with the same request
ID returns the same slot. `agent-slot resume <repo>/<N>` restarts a dormant slot's sessions and conversation,
`agent-slot warm <repo>` trusts slot paths ahead of time, and `agent-slot check [<repo>/<N>]` gives the teardown
verdict. `agent-slot sweep` and `agent-slot finish <repo>/<N>` delete slots, so both only report unless given `--yes`,
and agents ask before running them. `agent-slot doctor` checks every prerequisite and the time from key press to Claude
idle.

On the Mac, the keys run `agent-slot-rex launch`, `agent-slot-rex restore`, and `agent-slot-rex finish`; each pane runs
`agent-slot-rex attach <repo>/<N> claude|files|git`, the control session's tab runs `agent-slot-rex sweep`, and
`agent-slot-rex doctor` checks both machines. Every verb answers `--help`.

With `--output json`, every verb prints one JSON object on success and one error object on stderr, with a `reason` from
the table below, an exit code (0 ok, 1 failed, 2 usage, 77 auth, 78 configuration), a `next_step`, a `recovery` that
says whether a retry is safe, and a `log`. `--output` goes after the verb. `agent-slot schema` prints both
objects as JSON Schema with every reason, and each verb's `--help` lists the fields it returns.

#### agent-slot reasons

| Reason                        | Exit | Meaning and fix                                                                                |
| ----------------------------- | ---- | ---------------------------------------------------------------------------------------------- |
| `usage`                       | 2    | A verb, flag, or value is wrong; `--help` lists them                                           |
| `script-error`                | 1    | The command stopped unexpectedly; its log says where. `agent-slot list` shows what changed     |
| `dependency-missing`          | 78   | A tool is not installed; `next_step.command` installs it                                       |
| `record-schema-newer`         | 78   | A slot record was written by a newer `agent-slot`; update dotfiles                             |
| `not-in-slot`                 | 1    | The directory is not inside a slot                                                             |
| `repo-not-found`              | 2    | No checkout with that name has an origin; `agent-slot repos` lists the names                   |
| `slot-not-found`              | 1    | No slot holds that number                                                                      |
| `slot-busy`                   | 1    | Another `agent-slot` process holds the slot, or it is still setting up; retry                  |
| `invalid-task-name`           | 2    | A task name uses letters, digits, `-`, `_`, and `/`, and starts with a letter or digit         |
| `prompt-file-unreadable`      | 2    | The first-message file cannot be read                                                          |
| `slot-limit-reached`          | 78   | The repo holds the most live slots allowed; finish one, or raise `AGENT_SLOT_MAX_PER_REPO`     |
| `clone-failed`                | 1    | Cloning from origin failed; retry with the same request ID                                     |
| `solutions-symlink-missing`   | 78   | The shared solutions repo is missing, so the slot cannot get its `docs/solutions` link         |
| `hooks-path-outside-checkout` | 78   | The repo's own `core.hooksPath` points outside its checkout                                    |
| `git-crypt-locked`            | 78   | A git-crypt repo could not be unlocked: git-crypt or its key is missing                        |
| `trust-dialog-unrecognized`   | 78   | Claude showed a screen other than its trust dialog for the path; accept it by hand             |
| `tmux-unresponsive`           | 1    | The `agent-slots` tmux server did not answer in time                                           |
| `tmux-failed`                 | 1    | A tmux session could not be started; `agent-slot resume` tries again                           |
| `pr-state-unknown`            | 1    | `gh` could not read the repo's PRs; check `gh auth status`, then retry                         |
| `task-has-open-pr`            | 1    | `finish` refused: the task has an open PR; merge or close it first                             |
| `teardown-blocked`            | 1    | `finish` kept the slot; `agent-slot check <repo>/<N>` names why                                |
| `slot-outside-root`           | 78   | The slot path resolves outside the slot root, so nothing was deleted; look at it by hand       |
| `gh-auth-missing`             | 77   | `gh` is not signed in; `gh auth login`                                                         |
| `git-crypt-key-missing`       | 78   | There is no git-crypt key to unlock git-crypt repos with                                       |
| `solutions-corpus-missing`    | 78   | The shared solutions repo is not cloned                                                        |
| `slots-config-missing`        | 78   | `slots.conf` is not deployed; `scripts/stow-deploy tmux`                                       |
| `prune-timer-inactive`        | 78   | The slot server's orphan-client prune timer is not enabled                                     |
| `slot-path-untrusted`         | 78   | Doctor warning: a slot path, or the repo's prime checkout, is not trusted in Claude yet        |
| `version-unverified`          | 0    | Doctor warning: Claude or Rex differs from the version the checklist last ran on               |
| `repo-required`               | 2    | The new-agent key was pressed outside a repo's session, with no terminal to ask in             |
| `server-unreachable`          | 1    | ssh to the Linux server failed; retry once the network is back                                 |
| `rex-action-unregistered`     | 78   | Rex has not loaded the agent-slot actions; deploy the `rex` package or run `rex config reload` |
| `rex-failed`                  | 1    | A `rex` command failed; retry                                                                  |

#### Teardown blockers

`agent-slot check` names what keeps a finished slot with one of these codes, a count or the offending paths, and a
message such as `1 unpushed commit`.

| Code                     | What keeps the slot                                                                      |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| `pr-state-unknown`       | `gh` could not read the PRs, so whether the task has finished is unknown                 |
| `pr-closed-unmerged`     | A PR closed without merging; reopen and merge it, or press the finish key                |
| `git-state-unknown`      | `git` could not fetch, or read the slot's state                                          |
| `agent-not-idle`         | The agent is mid-turn or waiting on the operator                                         |
| `agent-state-unknown`    | The agent's state could not be read, or a process outside the slot's panes uses the slot |
| `uncommitted-changes`    | Tracked files have changes                                                               |
| `stash-present`          | Something is stashed                                                                     |
| `unpushed-commits`       | Commits are in no PR's final head and on no origin branch or tag, counting local tags    |
| `commits-without-pr`     | Commits sit only on an origin branch that has no PR, such as one pushed after the merge  |
| `untracked-files`        | Untracked or ignored files beyond build and dependency output                            |
| `local-only-files`       | `.context`, `todos`, `TODO*`, or `.env*` files, which never reach origin                 |
| `home-symlink-into-slot` | A symlink under the home directory resolves into the slot                                |
| `home-scan-incomplete`   | The scan for such symlinks did not finish                                                |
| `slot-busy`              | Another `agent-slot` process holds the slot                                              |

### System-Level Units (`config/systemd/system/`)

System-level systemd units are **not** managed by stow (which targets `$HOME`). They live in `config/systemd/system/`
and are deployed via `scripts/nas-deploy.sh`, which copies them to `/etc/systemd/system/` and activates them.

| Unit                | Purpose                                         |
| ------------------- | ----------------------------------------------- |
| `mnt-nas.mount`     | SMB mount for the NAS (`//<nas-host>/openclaw`) |
| `mnt-nas.automount` | On-demand automount, solves WiFi boot race      |

**Deploy:** `sudo scripts/nas-deploy.sh` (requires `/root/.smbcredentials-<nas-host>` from 1Password).

Three more system-level configs deploy through their own paths: `apparmor-playwright.service` (with the AppArmor
profile, via `scripts/apparmor-deploy.sh`, below), the `ollama` loopback override (`sudo stow -t /etc`, see the `ollama`
package), and the sshd locale change (`sudo scripts/sshd-locale-deploy.sh`, which edits `/etc/ssh/sshd_config` in place;
see [BOOTSTRAP.md § SSH session locale](BOOTSTRAP.md#ssh-session-locale)).

### launchd User PATH (`config/launchd/user-path`, macOS)

launchd starts every GUI application and LaunchAgent with the user PATH it reads at boot; it never reads the shell
config chain. Unset, that PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, where `#!/usr/bin/env bash` resolves to the system
bash 3.2. `config/launchd/user-path` declares the value with Homebrew first, so a process launchd starts finds
Homebrew's `bash` and the rest of `/opt/homebrew/bin` ahead of the system copies. `scripts/launchd-user-path.sh`
compares the declared value with launchd's (`/var/db/com.apple.xpc.launchd/config/user.plist`) and, on drift, prints the
exact `sudo launchctl config user path` fix and exits 1; `--apply` runs that fix. `scripts/stow-deploy` runs the check,
never the fix, on every macOS deploy to `$HOME`. launchd reads the value only at boot, so a change reaches apps after
the next reboot, and the check notes when the configured value is newer than the last boot.

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

The loop runs after `.profile` finishes assembling `PATH` (Homebrew, `~/.local/bin`, bun, cargo). Files here routinely
gate their contents on `command -v <tool>`, and that guard is evaluated at source time: sourced any earlier, every such
file would silently no-op in a shell that did not inherit a populated `PATH` — a launchd-spawned terminal, cron, or
`ssh host cmd`. `tests/shell-startup-shapes.bats` pins the ordering and exercises each shell shape;
`tests/shell-path-matrix.bats` checks `PATH` assembly across all eight supported invocation shapes, tabulated in
[AGENTS.md](AGENTS.md#supported-invocation-shapes). `tests/shell-nested-idempotence.bats` sources each fragment in a
shell and again in its child, and fails when the child's exported environment differs, since every new shell re-sources
the fragments.

Shell startup latency budgets live in `tests/perf/`, outside the `tests/*.bats` glob that the pre-push hook and CI use.
The hook runs that directory first, on a quiet machine, and each measurement is a best-of-N minimum: run at the tail of
the full suite, the several hundred shells it spawns push interactive zsh past its budget with nothing about the config
having changed.

| File                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `build-flags.sh`    | Make/CMake parallelism, CUDA architectures, Go amd64 level     |
| `caches.sh`         | XDG cache directory locations                                  |
| `claude-code.sh`    | Claude Code environment variables                              |
| `github.sh`         | GitHub CLI aliases                                             |
| `gnu-time.sh`       | `gtime` runs Homebrew's GNU time on Linux, as on macOS         |
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

| Hook            | Purpose                                                                 |
| --------------- | ----------------------------------------------------------------------- |
| Hook            | Purpose                                                                 |
| --------------- | --------------------------------------------------------------------    |
| `pre-commit`    | Blocks commits on `main`, verifies `commit.gpgsign`, gates staged paths |
| `post-checkout` | Auto-unlocks git-crypt, chains Git LFS                                  |
| `post-merge`    | Auto-unlocks git-crypt, chains Git LFS                                  |
| `pre-push`      | Mirrors CI (shellcheck, actionlint, bats, core-env), chains Git LFS     |

Both gates call the same dispatchers CI calls — `scripts/lint-shell`, `scripts/lint-workflows`, `scripts/run-tests`,
`scripts/core-env-guard.sh` — so the three cannot drift. `pre-push` runs them over the whole repo; `pre-commit` runs
them over staged paths only. See [AGENTS.md § Local gates mirror CI](AGENTS.md#local-gates-mirror-ci).

## CI and Testing

| Workflow                    | Trigger                | Purpose                                                       |
| --------------------------- | ---------------------- | ------------------------------------------------------------- |
| `release.yml`               | Push to `main`         | CalVer tag + GitHub Release, notes read from `CHANGELOG.md`   |
| `shellcheck.yml`            | Pull request           | Lints shell scripts and hooks, then workflows with actionlint |
| `bats.yml`                  | Pull request           | Runs the bats-core test suites                                |
| `guard-main-docs.yml`       | Pull request to `main` | Blocks engineering docs from reaching `main`                  |
| `guard-main-provenance.yml` | Pull request to `main` | Requires every commit to carry a PR reference                 |
| `guard-release-branch.yml`  | Pull request to `main` | Rejects any head branch that is not `release/*`               |

`shellcheck.yml` and `bats.yml` are required status checks on both `dev` and `main`; `main` additionally requires the
three guard callers. They run on every pull request with no path filter so the required context is always reported. The
`pre-push` hook runs the same checks locally and skips them for markdown-only pushes.

`release.yml` does not generate the changelog. `CHANGELOG.md` is generated on the release branch by
`scripts/generate-changelog.py` and committed through the release PR; the workflow only extracts its topmost section as
the GitHub Release body. See [RELEASES.md](RELEASES.md).

Shell scripts are tested with [bats-core](https://github.com/bats-core/bats-core) (`scripts/run-tests --all`). Suites
cover stow-deploy and its package sets, git hooks and the gate dispatchers, the shell config chain and its `PATH`
matrix, supply-chain age gates, symlinks, the qmd-serve units, tmuxinator configs, and the CLI wrappers.

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
[RELEASES.md](RELEASES.md) for the end-to-end flow (feature branch → dev → `release/*` overlay branch → main).

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
