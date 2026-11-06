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
│   ├── playwright/        The system browser set's pin: versions, revisions, aliases, archive hashes (via playwright-browsers-deploy.sh)
│   ├── rex/               Rex login server accounts template (via rex-login-server-deploy.sh)
│   ├── sysctl.d/          Kernel settings copied to /etc/sysctl.d (via sysctl-deploy.sh)
│   └── systemd/system/    System-level units (NAS mounts via nas-deploy.sh, apparmor-playwright via apparmor-deploy.sh)
├── scripts/
│   ├── stow-deploy        Stow wrapper with conflict resolution
│   ├── nas-deploy.sh      System-level NAS mount/automount deploy
│   ├── apparmor-deploy.sh System-level AppArmor profile deploy + boot unit (Playwright/Chromium)
│   ├── sshd-locale-deploy.sh  Strip LANG/LC_* from sshd AcceptEnv so sessions use the server locale
│   ├── sysctl-deploy.sh   Copy config/sysctl.d into /etc/sysctl.d, apply, and read each key back (--check: read only)
│   ├── playwright-browsers-deploy.sh  The system browser set into the shared cache, from config/playwright/browsers.pin (curl + unzip; --check: read only)
│   ├── playwright-deps-deploy.sh  Playwright browser launch provisioning (the set, plus apparmor and opt-in browser deps on Linux)
│   ├── *-enable.sh        Service enablers (qmd-serve, qmd-launchd, host-jobs)
│   ├── tailscale-serve-setup.sh   Reproducible tailnet serve config (svc:ollama, svc:codex-proxy)
│   ├── tailscale-serve-deploy.sh  System unit that re-runs the serve setup on every tailscaled start
│   ├── rex-login-server-deploy.sh Rex login server accounts + tailnet listener, then enable the service
│   ├── macos-gpu-monitor.sh       Metal GPU residency/power trace around any command (macOS)
│   ├── launchd-user-path.sh       Check (or --apply) the launchd user PATH against config/launchd/ (macOS)
│   ├── fseventsd-check.sh         Warn when fseventsd outgrows its launchd memory budget (macOS, run at Claude Code session start)
│   ├── lint-shell, lint-workflows, run-tests   CI gate dispatchers, shared by CI and the git hooks
│   ├── core-env-guard.sh  Fails a test that resets HOME or another core env var (allowlist beside it)
│   ├── generate-changelog.py      Release changelog extraction from merged PR bodies
│   ├── sync-dev-after-release.sh  Backport a release's CHANGELOG.md and release-branch edits to dev by PR
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
| `qmd`         | `.local/bin/qmd` wrapper (both platforms); the qmd-serve daemon and index-timer units ship in `local` (Linux)                    |
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

| Binary                  | Purpose                                                                                        |
| ----------------------- | ---------------------------------------------------------------------------------------------- |
| `agent-slot`            | Hand out and tear down clones of a repo for parallel Claude agents, one task per clone         |
| `agent-slot-rex`        | The Rex half of `agent-slot`: one tab per slot in the server's Rex; on the Mac, a forwarder    |
| `brave-search`          | Query the Brave Search API, printing ranked results as plain text or raw JSON                  |
| `charcount`             | Count characters against platform length caps, exiting non-zero so it gates in scripts         |
| `env`                   | Put `~/.local/bin` on `PATH` for user-installed binaries                                       |
| `gh-revision-audit`     | List your issues and PRs that still carry prior edit revisions on GitHub                       |
| `github-stars`          | Clone and update starred GitHub repos under `~/github-stars`, run by the `github-stars` timers |
| `github-stars-pdf`      | Markdown copies of star PDFs marked `convert` in `pdfs.tsv` for qmd; reports new PDFs          |
| `gstack-config-apply`   | Converge `~/.gstack/config.yaml`, which gstack rewrites and so cannot be a stow package        |
| `mac-open`              | Open a file from yazi on a Linux host on the Mac the session is driven from                    |
| `mac-open-here`         | The Mac half of `mac-open`, run over SSH: open a host file in VS Code or the default app       |
| `op-ssh-sign-wrapper`   | Cross-platform commit signing: 1Password agent on macOS, `ssh-keygen -Y sign` headless         |
| `qmd-gpu-verify`        | Prove the `qmd-serve` daemon runs its model work on the GPU rather than the CPU                |
| `qmd-ollama-unload-all` | Evict resident Ollama models, but only when VRAM is too low for `qmd embed` to load safely     |
| `sd-commit-doc`         | Publish `docs/solutions/` files from a slot's worktree or the shared clone without races       |
| `skill-listing-refresh` | List skills no session used in 30 days by name only in Claude Code's `settings.json`, daily    |
| `tmux-new-session`      | Write a tmuxinator config for a repo and start its 3-pane session                              |
| `transcribe-diarize`    | Local GPU speaker-diarized transcription (ffmpeg → whisperx → pyannote)                        |
| `unslop`                | Machine-level entry point for the prose scorer, resolved through `~/.claude/skills`            |
| `unslop-gate`           | Git-hook prose gate over `unslop`, scoring only the markdown in the change being pushed        |
| `uuidv7`                | Print a time-ordered UUIDv7, used for collision-proof `/tmp` artifact names                    |
| `xurl`                  | Real `xurl` on `PATH` that execs xurl-rs's `xr`, for callers that load no interactive alias    |

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

Many Claude Code agents can work on the same repo at once, each in an *agent slot*: a clone of the repo at
`~/slots/<repo>/<N>` on the Linux server, set up like the repo's own checkout (its hooks, the `docs/solutions` link, the
`.context/repo-recon` link when the repo has a repo-recon store, its Claude memory and permission grants, and its
partial-clone filter when it has one), with one task per slot. Setup also runs `bun install --frozen-lockfile`,
`pnpm install --frozen-lockfile`, or `npm ci` before the slot's agent starts, so the repo's tool-backed hooks work on
the first push. An install runs the head's code with this account's credentials before anyone reads it, so it runs only
when the prime has `node_modules`, Claude trusts the prime, and the base branch holds the head; `deps.status` reads
`prime-not-set-up` or `head-not-on-base` otherwise, `failed`, `timed-out` (past `AGENT_SLOT_DEPS_TIMEOUT` seconds, 60),
or `tool-missing` when an install does not finish, and `installed` when it does. A frozen install writes no lockfile,
and it takes whatever the lockfile pins without consulting the supply-chain age gate, so the gate binds only whoever
wrote the lock. A slot's `docs/solutions` links to its own detached worktree of the solutions repo at
`~/slots/<repo>/.solutions/<N>-<suffix>`, made at origin/main during setup and recorded as `solutions_worktree`; its
agent writes and publishes there with `sd-commit-doc`, the slot is kept while that worktree holds anything origin/main
lacks (`solutions-unpublished`), and teardown removes it. The repo-recon link points at
`~/dev/repo-recon/<owner>/<repo>`, named for the prime's `origin`, else for its `upstream`, the remote a fork names its
parent by. Setup never makes a store, and a teardown deletes the link but not the store, so whatever an agent filed
through it stays. `agent-slot` on the server owns every slot and every check before a slot is deleted; `agent-slot-rex`
on the same server drives that server's Rex, where each repo is one session and each agent one tab, and Rex.app and the
Rex iOS app are windows onto it through the Rex login server. Every slot runs three tmux sessions on the server's
`agent-slots` socket (Claude, yazi, and lazygit), so agents keep working with no client connected and through a restart
of the Rex server, and each pane of a slot's tab attaches again by itself when its tab is rebuilt. A slot launched or
torn down on the server, by an agent or by hand, opens or closes its tab with no key press and no client connected. On
the Mac, `agent-slot-rex` hands each slot verb to the server's helper over ssh, so the slot keys act on the server
whichever session has focus.

Each slot's Claude starts and resumes with `--dangerously-skip-permissions`, so it skips its permission prompts except
under an ask rule and for the few actions Claude never auto-approves. Deny rules and hooks still block in that mode, ask
rules are how `agent-slot sweep`, `agent-slot finish`, and `agent-slot reopen`, and the helper's `agent-slot-rex finish`
and `agent-slot-rex sweep`, which run them with `--yes` on the same host, keep asking first, and Claude's trust dialog
still shows for a path it does not trust. Claude skips its own bypass warning only when `~/.claude/settings.json` sets
`skipDangerousModePermissionPrompt` to `true`, as this repo's settings do; `agent-slot doctor` warns when it does not.
Slot agents run as the operator on the Linux server, so they can reach its Rex server's socket and drive any tab there
with `rex send` and `rex send-key`, a `sudo` session or a root shell on another host kept in that server included. The
account already gives them the operator's files and keys, so this adds reach rather than a privilege.

A slot's Claude also starts on a lean profile, which `scripts/agent-slot/lib/profile.sh` defines and the command line
carries as one inline `--settings` object plus `--disallowedTools`, so a pull needs no restow before it applies. It
drops the `Artifact`, `AskUserQuestion`, `ScheduleWakeup`, and `ReportFindings` tools, which no slot can use, and turns
off the skills no slot has called and the obsidian and cloudflare plugins. A repo with a `wrangler.toml`,
`wrangler.json`, or `wrangler.jsonc` within three levels of its root keeps the cloudflare plugin. The object sets skills
to `off` only and merges over `~/.claude/settings.json`, so the name-only skill entries `skill-listing-refresh` keeps
there still apply; idle compaction stays off in the same object. The profile reaches launch, resume, reopen, and a model
switch, and the subagents of those sessions. It does not reach primes, generic sessions, or a `claude -p` a slot's agent
starts, a review run included.

The Obsidian vault takes slots too, several at once, under the name `agent-slot repos` lists it by:
`agent-slot launch obsidian-vault --model (opus | sonnet) --request-id <id> --prompt-file <brief>`. `~/obsidian-vault`
keeps its git directory in `~/dev/vault-git`, so its `.git` is a file. A prime's `.git` may be a file when its git
directory is also its common directory, which rules out a linked worktree; the git directory itself has no `.git` and is
never listed. The prime map names no prime session for the vault, so the new-agent key always starts a slot of it.
Nothing automated commits in the vault. A vault slot commits only its own task's work, on main, and runs `git fetch`
then `git rebase origin/main` before each push, so parallel slots never clobber each other. Its SessionStart context
carries those rules, and tells it to keep vault content out of `docs/solutions`, other repos, PR bodies, and every
outside service. With no PR, its task finishes when its agent runs `agent-slot release`. A slot clones from origin, so
it holds only what is pushed, and its work reaches `~/obsidian-vault`, which Obsidian and qmd read, when the operator
pulls there. A slot's teardown treats no ignored directory as tool output, since the vault's whitelist `.gitignore`
ignores every new top-level directory.

Nobody watches a slot's tab, so no agent there waits on a dialog. `slot-unattended.sh` (in `stow/claude/dot-claude/`)
answers every dialog Claude Code raises in a slot, for the slot's own Claude and for its subagents. It denies a
permission request, which an ask rule still raises in bypass mode, and a call to `AskUserQuestion`, `EnterPlanMode`, or
`ExitPlanMode`. The denial message tells the agent to do the work another way within its brief, or to send the decision
to the session its brief reports to. Each denial appends a `prompt-denied` event to
`~/.local/state/agent-slot/ledger.jsonl` with the slot, the tool, and the first 200 characters of its input. A dialog
still waiting after about 6 s got past the hook, for example because the hook failed, which leaves the dialog to show.
That wait appends a `prompt-waiting` event, and `slot-status.sh` marks the tab blocked. Outside a slot the hook does
nothing, so an ask rule prompts there as it always has.

A slot's agent gets at most 2 review rounds per PR. `slot-review-cap.sh` (also in `stow/claude/dot-claude/`, on
`PreToolUse` for the `Skill` tool) counts each call of `compound-engineering:ce-code-review`, by the slot's own Claude
or its subagents and under its bare name too, as one round for the PR on the slot's current branch. It appends a
`review-round` event to the ledger with the slot and the branch, and denies the third, naming the rule, the count, the
PR and head commit to send the coordinating session, and the grant command for the operator. Rounds are counted per
branch, so several PRs reviewed from one branch share one cap; on a detached head the commit stands in for the branch,
and each new commit starts a new count. They count from the slot's `created_at`, so a reused slot number starts at none,
and a call counts when it starts, so a review that fails at once still uses its round. Outside a slot the hook prints
nothing, and `/devex-review` and `/cso` are not counted.

The operator allows one more round with `agent-slot grant-review <repo>/<N>`, which appends a `review-grant` event for
the slot's current branch and reports the rounds used and allowed. Each run is one round. It refuses with
`review-grant-from-slot` when run from a slot's directory or its tmux server, and an ask rule makes a slot's own request
for it a denial through `slot-unattended.sh`. The cap is a guard, not a trust boundary: an agent with a shell could
still write a ledger line.

```bash
agent-slot grant-review dotfiles/2
```

A slot's agent changes only the paths its brief declares. A brief carries `Touches:`, the paths its PR may change as
comma-separated git pathspec globs, and `Adds:`, the public surface it may add (verbs, flags, reason codes, environment
variables, settings keys) or `none`, beside `Scope:`, `Limits:`, `Reviews:`, and `Reports to:`; `launch` and `reopen`
refuse a brief that lacks any of the six with `brief-incomplete`. They record the globs as `scope.touches` and the
`Adds:` text as `scope.adds` in the slot's record, and the slot's context names both. `slot-scope-guard.sh` (also in
`stow/claude/dot-claude/`, on `PreToolUse` for the `Bash` tool) runs when the slot's own Claude or one of its subagents
runs a `git push`. It lists the paths `git diff --name-only --no-renames origin/<base>...HEAD` reports, with a rename as
its old and new path, and denies the push when any of them matches none of the record's `scope.touches` globs and none
of the slot's `scope-grant` ledger lines (counted from the slot's `created_at`). The denial names each path outside the
scope and the next step: revert that change, or record it under "Not in scope" in the PR body and send the coordinating
session a request for a scope grant. A slot whose record has no `scope.touches` passes, and outside a slot the hook
prints nothing. `Adds:` is recorded and shown, and is not checked against the diff. The hook judges the commits as they
stand at the push: a push of another branch or another repository than the slot's checked-out one is judged by the
slot's `HEAD`, and a dry run or a branch deletion is not judged. A command that changes `HEAD` before it pushes, such as
`git commit && git push`, is denied for a slot with a scope, because the hook runs before the commit exists: the agent
commits first and pushes as its own command.

```text
Touches: scripts/agent-slot/**, tests/*.bats, README.md
Adds: one flag, --dry-run; the reason code scope-grant-from-slot
```

A glob is a git pathspec relative to the repo root: `*` crosses `/`, so `tests/*.bats` also matches `tests/lib/x.bats`;
a directory name matches everything under it; a comma always separates two globs, so a brace list does not work. A
second `Touches:` line adds to the first. `launch` and `reopen` refuse a glob git rejects, such as an absolute path, or
one with a space, semicolon, brace, or quote, with `brief-incomplete` naming it and the line as parsed, and the hook
denies a push whose recorded glob git rejects instead of leaving it unguarded. A slot's base is the repo's base branch,
so a slot stacked on another PR's branch sees that PR's paths as its own changes: its `Touches:` lists them, or the
operator grants them. The hook is a guard, not a trust boundary: it recognises a `git push` by its text, so a wrapper it
does not list, or a script that pushes, runs unjudged.

The operator lets a slot's PR change one more path with `agent-slot grant-scope <repo>/<N> <pathspec>`, which appends a
`scope-grant` event for the slot, and the hook then lets the paths that pathspec matches through. The verb lists to
`/dev/tty` the paths the slot's branch changes that the pathspec covers, and how many it leaves out, and reads the
slot's key back from it within 120 s, so it asks for a person at a terminal: with none, as in an agent's Bash tool, or
under Claude Code (`CLAUDECODE` set) even with a pseudo-terminal, it refuses with `grant-needs-terminal`, and with no
answer or any other, `grant-not-confirmed`. It refuses with `scope-grant-from-slot` when run from a slot's directory or
its tmux server, with `slot-busy` while the slot is still being set up, and an ask rule makes a slot's own request for
it a denial through `slot-unattended.sh`. A pathspec git rejects, an exclude pathspec, one with a control character, and
one that covers none of the paths the branch changes are refused with `usage` before the terminal is asked. One run
grants one pathspec; the grant list is the `scope-grant` events in the ledger, and there is no revoke. This is a guard,
not a trust boundary: a shell that unsets `CLAUDECODE` and gives a command a pseudo-terminal, or writes the ledger, can
still grant, as with `grant-review`. The coordinating session relays a slot's request to the operator.

```bash
agent-slot grant-scope dotfiles/2 'docs/*.md'
```

A slot stays while its task is open, review rounds included, and is deleted only once the task has finished (its PRs
merged with none open, the operator finished it, whatever state its PRs are in, or its agent released it with no PR
open) and nothing in it is missing from GitHub. A commit is safe there once a PR's final head holds it, an origin branch
or tag holds it, or a branch of a fork holds it: a remote on origin's host that one of the slot's branches tracks or
pushes to, as `gh pr checkout` sets up for a PR from a fork. A task owns the PRs opened from its branches after its slot
was made, and an older PR whose head one of its branches holds beyond the base, such as the PR a review-round slot works
on. Anything else keeps it on the *needs-you list*, shown on its tab and in the `agent-slots` control session.

Deleting a slot moves its clone, `.git` included, to the trash and purges that one entry from the trash at once: the
trash shares the slot root's volume, so the move alone frees nothing. The entry is the one whose `.trashinfo` gives the
clone's path after the move and did not before it, so no other entry in the trash is touched. The purge runs after the
slot's lock is released and gets 180 seconds. A purge that fails leaves the slot torn down and says so in the result, in
a `purge` ledger event, and in `teardown.log`, with one of the [purge failures](#purge-failures) below and the
`trash-rm` command that finishes it.

Teardown needs no one to press a key. A slot's agent closes its task by running `/compound-engineering:ce-compound` once
per finding from its session, then `/compound-engineering:ce-compound mode:refresh`, then deletes the scratch files it
made and commits and PRs anything that is real work, then stops every background job it no longer needs, then runs
`agent-slot release`, which refuses until both of those ce-compound runs are in that slot's sessions and while the
slot's Claude still runs a Bash tool command other than the release's own: Claude Code lists a session with a live
background shell as busy, so a leftover job would hold the teardown back for as long as it runs. An agent still waiting
on something, such as CI or a release chain, keeps that job and runs `agent-slot release --not-yet '<why>'` instead,
which records why and withdraws the agent's earlier release, if it made one: of a release and a `--not-yet`, the newer
stands. The release starts `agent-slot finish <repo>/<N> --yes --when-idle` in a session of its own, outside the slot,
which waits for the agent to go idle and then runs the same fail-closed finish the operator does, except that it marks
the task finished on the release rather than as the operator's, so a `--not-yet` withdraws that mark with the release.
Once a `--not-yet` or a newer release replaces the release that started it, that finish stops waiting and refuses with
`release-withdrawn`, tearing nothing down. A slot whose PR is still open stays released, and `agent-slot-sweep.timer`
tears it down once the PR merges: every ten minutes it runs `agent-slot sweep --yes --auto`, which tears down only a
slot its agent released or the operator finished. A finished slot that is neither keeps its clone, so its learnings are
not lost: its idle agent is typed the closing steps once, and a slot whose agent is gone, or that still has not released
after those steps, joins the needs-you list as `not-released`. A slot whose agent recorded `--not-yet` stays off that
list while the agent is there; once the agent is idle and the record is `AGENT_SLOT_RELEASE_REMIND` seconds old (1800),
it is typed a reminder with its own reason, once, and a reminder it answers with neither a release nor a new `--not-yet`
lists the slot as before. A finished slot kept only by files left in its tree (`untracked-files`, `local-only-files`,
`uncommitted-changes`), released or not, gets its idle agent a reminder naming them, once: delete what is scratch,
commit and PR what is work, then close out and release. It stays off the needs-you list while the agent is busy, and
joins it when the agent is gone, or is idle after the reminder with the files still there and no `--not-yet` saying why.
The operator's own `agent-slot sweep --yes`, `agent-slot finish --yes`, and the finish key ignore the release: they tear
down any finished slot that check passes. An operator's finish is the operator's call, so `--not-yet` does not undo it:
on a slot the operator finished, it refuses with `finished-by-operator`, records nothing, and the slot is torn down once
its agent is idle and check passes.

#### Setup

On the Linux server:

1. `scripts/stow-deploy --headless --all` deploys the slot commands, the Rex config with its start-up step and
   tab-number watcher, and the units, then reloads the running Rex server's config.
2. `bash scripts/host-jobs-enable.sh` enables the sweep, reconcile, and warm timers and starts `rex-server.service` and
   `rex-tab-numbers.service`; `systemctl --user enable --now tmux-prune-orphans-slots.timer` adds the slot tmux server's
   orphan sweep.
3. `agent-slot-rex doctor` is the checklist from there. Each finding names what is missing with the command that fixes
   it, such as the login server's deploy or rexurrect's. Rerun it until it reports no errors.
4. Run `claude --dangerously-skip-permissions` once in each repo's prime checkout and accept its trust dialog, which the
   flag does not skip, and do the same for every repo cloned under `~/dev` later. A slot path is trusted only for a repo
   whose prime checkout you have trusted in Claude, because trust lets Claude load the repo's own settings and hooks.
   `agent-slot-warm.timer` runs `agent-slot warm --all` every ten minutes, which trusts every slot path of every repo
   `agent-slot repos` lists, so a new repo's slots start warm within ten minutes of its prime being trusted. While any
   prime is untrusted the unit fails, and the failed-units notice at every Claude session start names those repos.

On the Mac:

1. `scripts/stow-deploy --all` deploys the slot actions and keys and reloads the Mac's Rex config (see BOOTSTRAP.md for
   moving a hand-written `~/.config/rex` aside first).
2. `launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.bd-tunnel.plist` keeps the dev ports the Linux
   server serves at the Mac's localhost, with no ssh tab open.
3. In Rex.app, connect to the Linux server's host, which reaches its Rex server through the login server.

#### Keys and tab labels

| Key         | Action                                                                                          |
| ----------- | ----------------------------------------------------------------------------------------------- |
| `cmd+alt+n` | Open the session's repo prime as its first tab, or start an agent on the repo in a new tab      |
| `cmd+alt+r` | Give every live slot its tab back, resume dormant slots, and close tabs whose slot is gone      |
| `cmd+alt+f` | Finish the focused tab's task (no open PR) and delete its slot when nothing in it would be lost |

`cmd+alt+n` opens a tab that comes forward and decides what it becomes from the session's name:

- **A Linux server session named after a repo with a prime.** `config/agent-slot-rex/primes.tsv` names each such repo's
  prime tmux session on the server's default tmux server, such as `XR CLI` for `xurl-rs`. While no tab of the session is
  attached to that prime, the new tab becomes the prime's tab: first in the session, labelled with the prime's name,
  attached from `$HOME` by `agent-slot-rex prime <repo>`, and a login shell once you detach. A tab counts as the prime
  only while a tmux client of the prime runs in it, so a renamed tab still counts and a detached one does not. Once the
  prime is open, the key starts a slot of the repo.
- **A Linux server session named after any other repo.** The key starts a slot of the repo, with no question.
- **Any other session, every session on the Mac included.** The tab asks which repo to use, and the agent's tab opens in
  the background in that repo's session on the Linux server.

The tab waits up to `AGENT_SLOT_REX_SHOWN_WAIT` seconds (10) for Rex.app to show it before it does anything. It reads
"shown" from the terminal size the app asks for each pane it lays out on screen, never from the session's active window,
which Rex.app does not always move to a tab it shows. In a session with no tabs, Rex.app hands the key the session of
the pane it last focused, which can be another session on another host, where nobody sees the tab. Such a tab starts
nothing, asks for Enter, and closes itself after `AGENT_SLOT_REX_SHOWN_HOLD` seconds (60). In a session with no tabs,
open one with `cmd+t` first, then press the key.

On the Linux server every tab's label starts with its position in its session, `<n>:`, which `rex-tab-numbers.service`
keeps current as tabs open, close, and move; the slot helper matches and relabels tabs past that number and never writes
it.

A slot's tab is labelled `<repo>/<N>`, then `· <label>` (the slot's name, else its task name, else the agent's branch
once it has one), then:

- `· trust needed` when the repo's prime checkout is not trusted in Claude, or Claude's trust dialog for the slot path
  did not look as expected: accept it in the tab;
- `· needs you: <first blocker>` when something keeps the slot from being deleted;
- `<repo> · launch failed` on a launch tab that stopped, with the error, its next step, and its log; Enter retries a
  retryable failure with the same request ID, and q closes the tab.

#### Tabs follow the server

Three triggers on the Linux server keep its Rex tabs in step with the slots, with no client connected, and each one runs
an `agent-slot-rex restore` pass:

- **Push.** After `agent-slot launch` makes a slot, and after `agent-slot sweep --yes` or `agent-slot finish --yes`
  tears one down, agent-slot runs `agent-slot-rex restore --by push` in the background. It finds the helper at
  `AGENT_SLOT_REX_HELPER` (`~/.local/bin/agent-slot-rex`) and pushes nothing without it, and the verb never waits for it
  unless `AGENT_SLOT_PUSH_WAIT=1`, as the sweep timer and a release's finish set; `AGENT_SLOT_PUSH_TIMEOUT` (60 s)
  bounds it. A verb the helper ran itself pushes nothing, because the helper reconciles right after it.
- **Timer.** `agent-slot-reconcile.timer` runs `agent-slot-rex restore --by poll` every minute, which catches a push
  that changed nothing and relabels a tab once its agent has made its branch.
- **Start-up.** When the Rex server loads its config, it starts `agent-slot-rex restore --at-start`, which waits up to
  `AGENT_SLOT_REX_STARTUP_WAIT` seconds (120) for the server to answer, runs `rexurrect auto-restore` once per server
  instance under `AGENT_SLOT_REX_REXURRECT_BOUND` seconds (90), records the instance in
  `~/.local/state/agent-slot-rex/startup.json`, then reconciles with dormant slots resumed. Right before rexurrect, it
  kills each session of the new server that holds nothing but slot tabs, since rexurrect counts a session as live by ID
  and would restore a second one beside it; the reconcile then opens those tabs again. rexurrect brings each prime tab
  back as a plain shell, so before the reconcile the step makes it the prime again: in each repo session of
  `config/agent-slot-rex/primes.tsv` with no tab attached to its prime, it types `agent-slot-rex prime <repo>` into the
  first tab labelled with the prime's name when that tab is one pane at a shell prompt, clearing whatever the prompt
  holds first. Any other tab is left alone, and so is a prime whose tmux session is not running. A config reload's step
  types into no tab, since a prime-labelled shell there is a prime you detached. It logs to `restore.log` in that
  directory.

Every other pass first checks that a Rex server answers and that the start-up step has recorded its instance. A push or
timer pass that finds either missing changes nothing, says why under `skipped` (`rex-server-down` or `startup-pending`),
and exits 0; so does one that finds another pass holding the lock, as `reconcile-busy`, where a timer pass never waits
for the lock and a push waits up to half of `AGENT_SLOT_PUSH_TIMEOUT`. A pass that waited checks again once it holds the
lock. Each pass then checks, before every tab change and once after its last, that the server instance it planned
against still answers; when the server restarted or stopped partway, the pass makes no further change and logs
`rex-server-restarted` or `rex-server-down` under `skipped`, with the part of its plan it carried out. A restore asked
for by hand reports each of these as an error. A server older than `AGENT_SLOT_REX_STARTUP_LIMIT` seconds (300) with no
record is reconciled anyway, and that pass records rexurrect as skipped. `agent-slot-rex doctor` reports
`reconcile-stale` once three passes in a row failed or found the lock held.

Every trigger is logged, so the interval can be tuned from data. Each pass's line in
`~/.local/state/agent-slot-rex/reconcile.log` names its trigger in `by`, with `ms` (how long the pass took), `changed`
(whether it opened, relabelled, or closed a tab), `skipped`, `rexurrect` (the outcome the pass recorded: `done`,
`failed`, `stopped`, or `skipped`), and `primes`, null except in a start-up step on a new instance, where it holds each
repo's prime outcome: `reattached`, `unconfirmed` (typed, but no client showed within `AGENT_SLOT_REX_PRIME_WAIT`
seconds, 5), `already-open`, `no-session`, `no-tab`, `not-idle`, `prime-not-running`, `rex-server-restarted`,
`rex-server-down`, or the reason of the error that stopped that repo's check. A timer pass with `changed` true found
work no push had brought. `~/.local/state/agent-slot/push.log` holds one line per push: when it began, the verb and its
slots, the result (`restored`, `deferred` with the reason in `detail`, `restore-failed`, `timed-out`, or `skipped`), the
helper's exit code, the time taken, and the helper's last line on a failure. Each of these logs moves to `<log>.1` past
1 MiB. A timer pass that changes nothing writes about 180 bytes, so the reconcile log holds about four days of passes
before it moves.

#### A slot's tab is missing

1. `agent-slot-rex doctor` on the server names a Rex server that `rex-server.service` did not start, a reconcile timer
   that is stopped or whose journal shows no recent good pass (`reconcile-stale`), and a start-up step that left the
   operator's own tabs unrestored.
2. The newest lines of `~/.local/state/agent-slot-rex/reconcile.log` say what the passes did: `by` names what ran each
   one, `ok` whether it finished, `skipped` why it changed nothing on purpose, and `error.reason` what stopped it.
3. `agent-slot-rex restore` reconciles at once, and reports as an error any outcome a timer pass only logs.

The Rex iOS app runs no slot actions, so from the phone open a shell tab on the Linux server and run
`agent-slot launch <repo> --model (opus | sonnet)`: the slot's tab opens in that repo's session within seconds. `launch`
takes a first message only as `--prompt-file`, so type the first message into the new tab's Claude.

#### Work items and reopen

A slot's *work items* are the GitHub PRs and issues it works on, each kept in its record as
`{kind, repo, number, title}`. A slot gets them from `agent-slot launch <repo> --model (opus | sonnet) --pr <ref>` or
`--issue <ref>`, from `agent-slot adopt` and `agent-slot probe`, and from `agent-slot check`, which adds each PR it
finds for the task. A ref is `N` in origin's repo, `owner/name#N`, or the item's GitHub URL. The first item names the
slot `<repo>-pr<N>-<slug>` or `<repo>-issue<N>-<slug>`, from the item repo's name and the item's title, cut at a dash to
fit 64 characters. The name never changes after that, so an issue's slot keeps the issue's name once its PR opens; when
check adopts several PRs at once, the earliest created names the slot. `agent-slot list`, `agent-slot whoami`, and the
slot's tab show its `label_name`: the name, else the task, else the branch its clone has checked out. The slot's Claude
session carries the name as well: launch, resume, and reopen start Claude with `-n <name>` (the task for a slot with no
name), and a slot named while its agent runs has `/rename <name>` typed into its session, by `adopt` when the agent is
idle, else by the first automatic sweep that finds it idle, which records the session's name in `named_as`. The agent's
SessionStart context lists the slot's work items.

A launch on a PR checks out the PR's head branch tracking the remote that holds it: origin, the remote the prime
checkout has for that repository, or `fork`. A head whose branch or repository is gone is checked out from
`refs/pull/<N>/head` with no upstream, and the launch reports `head_pushable: false`. A launch on an issue keeps the
base branch. When a torn-down slot worked on the same item, the launch reports it in `prior`, with the reopen that
resumes its conversation.

A head in a repository whose owner is not in `config/agent-slot/trusted-owners`, or `AGENT_SLOT_TRUSTED_OWNERS` when
set, matched in any case, or cannot be determined is a *foreign head*, on a fork or on the PR's own repo, and nothing
from it runs before someone has read it. The launch reports `head_foreign: true` and `head_owner`, and each difference
from a normal slot exists because the head's tracked files would otherwise act as this account:

| Normal slot                                          | Foreign head                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `claude --dangerously-skip-permissions`              | adds `--setting-sources user --strict-mcp-config`                                                                                                                                                                                                                                                                  |
| The whole tree on disk                               | `.claude`, `.mcp.json`, `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `bunfig.toml`, `.env`, `.env.*`, and `node_modules` left out at any depth by a sparse checkout, so a `claude` or a Bun-run tool such as `qmd` started in the slot finds none of them; `git show` still reads them and pushes still carry them |
| yazi in the files session                            | `ls -A`, since yazi's previewers parse what the cursor lands on with no key pressed                                                                                                                                                                                                                                |
| Git finds a bare repository below the slot's root    | The sessions set `safe.bareRepository=explicit`, since a directory the head tracks in that shape runs what its config names when git runs below it                                                                                                                                                                 |
| The trust step starts Claude plainly                 | The trust step starts Claude with the same flags, since accepting runs what it loads                                                                                                                                                                                                                               |
| `core.hooksPath` or copies of the prime's hooks      | No hooks                                                                                                                                                                                                                                                                                                           |
| `.claude/settings.local.json` written from the prime | Not written, since a tracked link would carry the write to the file it names                                                                                                                                                                                                                                       |
| repo-recon and sibling links                         | Not made                                                                                                                                                                                                                                                                                                           |
| LFS smudge on checkout                               | Skipped for the slot's life, since it calls the server the head's `.lfsconfig` names                                                                                                                                                                                                                               |
| git-crypt unlock when the tree names the filter      | Never unlocked, since the key decrypts any file under its filter; encrypted files read as ciphertext                                                                                                                                                                                                               |
| `auto-format.sh` runs formatters after each edit     | Exits at once on the slot's record, since each formatter can load code from the tree                                                                                                                                                                                                                               |

A head a trusted owner holds keeps the normal setup, and so does a slot on the base with no PR, because trusting the
prime chose that base. A same-repo PR on a third party's origin is that third party's code, so it is foreign. `resume`
keeps a foreign head's flags. A reopen is foreign when the slot it reopens was, whatever branch that slot's agent left
behind, and when the head it plans or the PR's head on GitHub is. The SessionStart context tells the agent all of this
and tells it not to run the tree's code. No gate covers an agent that runs the tree's code anyway, or a foreign head
checked out by hand inside a normal slot, which every slot's context warns against.

A merge that conflicts on a left-out file puts it back on disk, as do `git checkout <tree> -- .`,
`git restore --source <tree> .`, `git apply --index`, and `git am`. Nothing runs it on its own: the slot's Claude still
skips it through its flags, and the session-context hook starts its tools outside the tree. Once it matches what is
committed, `git sparse-checkout reapply` takes it off disk again. Where the head tracks `docs/solutions` as a link,
`sparse.expectFilesOutsideOfPatterns` is on, so `git status` does not show a file `git restore --source` put back and
reapply leaves it, and it has to be trashed by hand.

A fork stays foreign until someone trusts its owner. To run one once someone has reviewed it, tear its slot down and
launch again with the owner added for that one command:
`AGENT_SLOT_TRUSTED_OWNERS='<the trusted owners> <owner>' agent-slot launch <repo> --model opus --pr <ref>`. That checks
out the branch as it is then, and its hooks run at once, so compare it with what was reviewed first. A reopen cannot do
this, since a foreign slot's reopen stays foreign.

Setup writes nothing through a link in the tree, on a slot of any head, since any branch can track one. A tracked
`.claude/settings.local.json` link is replaced in the slot and marked skip-worktree, and a `.claude`, `docs`, or
`.context` that setup would write under and that is a link out of the slot refuses the launch with
`tracked-link-leaves-slot`. A foreign head writes under `docs` alone, so only that link can refuse one.

Each teardown appends a `teardown` event to `~/.local/state/agent-slot/ledger.jsonl` with the slot's `items`, `name`,
`head` (the branch its clone had checked out), and `branches` (each branch's name and commit, with the remote and URL it
pushes to), beside its task, PRs, Claude session ID, and transcript path; `launch`, `adopt`, and `reopen` events carry
the items and name too. `agent-slot reopen <repo> --model (opus | sonnet) --pr <ref>` (or `--issue <ref>`) brings the
work back. It finds the newest teardown whose items hold the item, or, for a PR of origin's repo, the newest whose PRs
hold its number; `--session <id>` instead picks the teardown of the slot whose Claude session that was, for a teardown
that names no items. It makes a fresh slot as launch does and checks out the head: the branch the old slot had checked
out, else the PR's head branch, else the base, fetched from the remote the ledger recorded for it when that remote is on
origin's host, else from the PR's head repository. A branch that remote no longer has comes from a PR's
`refs/pull/<N>/head`, and for an issue the slot keeps the base; either way the reopen reports `head_pushable: false`. It
then starts Claude with `--resume <session ID>`, so the agent has the first round's conversation; nothing under
`~/.claude/projects` moves, since Claude Code resumes a session by its ID from any directory. The `--prompt-file` text
is the reopened agent's first prompt, its brief for the new round. Reopen refuses while a slot holds the item or the
session, while a Claude agent has the session open, when no teardown names the item, and when Claude Code no longer has
the transcript, each before it claims a slot. `--dry-run` changes nothing and exits 0 with either the plan or, under
`would_reopen: false`, the refusal a reopen would hit; a ref GitHub cannot read still fails.

The reopened slot keeps the old one's items, name, task, and session, records its source in `reopened_from`, and lists
in `settled_prs` the PRs already merged or closed when it was reopened. Those PRs neither finish the task nor keep it
open, so it finishes only on a new outcome, such as a new PR merging or the operator's finish, and their heads still
count as pushed. The release gate counts only the closing skills run since the slot was made, so the first round's
`ce-compound` runs do not release the second. Claude Code goes on writing the resumed conversation to its transcript
under the old slot's project directory while its SessionStart payload names a path under the new slot's, so wherever a
recorded transcript path does not exist, the slot record, the release gate, and the `release` and `teardown` events use
the transcript found by session ID instead. Claude Code keeps each session's transcript for 365 days
(`cleanupPeriodDays` in the stowed `~/.claude/settings.json`), so a reopen reaches back that far; past that it refuses
with `transcript-missing`.

`reopen` has an ask rule, and an ask rule on a verb also prompts on its `--help` and `--dry-run`, so an agent in a slot
nobody watches sends a reopen to the session its brief reports to instead of running it. `adopt` changes only a record
and a session name, so it runs without one.

The sequence below follows PR #887 of `acme/widget`, an illustrative upstream repo checked out as `widget`, whose head
branch lives on a fork. A dispatcher hands the PR to a slot:

```bash
agent-slot launch widget --model opus --pr 887 --request-id "$(uuidv7)" --prompt-file brief.md --output json
```

Once that slot is torn down and a reviewer replies, a dry run shows what a reopen would do. An excerpt of its output,
with home paths shortened:

```bash
agent-slot reopen widget --model opus --pr 887 --dry-run --output json
```

```json
{
  "would_reopen": true,
  "refusal": null,
  "item": {"kind": "pr", "repo": "acme/widget", "number": 887, "title": "Fix 16-bit to 8-bit reduction with tRNS"},
  "name": "widget-pr887-fix-16-bit-to-8-bit-reduction-with-trns",
  "session_id": "4e0a3f33-f697-4dff-a32f-2b0202be99d4",
  "transcript": "~/.claude/projects/-home-<user>-slots-widget-1/4e0a3f33-f697-4dff-a32f-2b0202be99d4.jsonl",
  "transcript_exists": true,
  "head": {
    "branch": "fix/trns-16-to-8",
    "remote": "fork",
    "url": "git@github.com:me/widget.git",
    "oid": "8fdb2520b0a97ed52c6235850cbcf87f08984113",
    "source": {"branch": "gh", "remote": "ledger"}
  },
  "slot": "widget/1",
  "command": "claude --dangerously-skip-permissions --resume 4e0a3f33-f697-4dff-a32f-2b0202be99d4 -n widget-pr887-fix-16-bit-to-8-bit-reduction-with-trns"
}
```

`head.source` says where the head came from: this teardown recorded no `head`, so the branch is the PR's head branch on
GitHub (`gh`), and its remote and URL are the ones the teardown's `branches` recorded for it (`ledger`). The reopen
itself takes the reply as the agent's brief:

```bash
agent-slot reopen widget --model opus --pr 887 --prompt-file reply.md --output json
```

It returns launch's fields plus `reopened_from`, `settled_prs`, `head`, and `head_moved`, which is true when the remote
branch's head is not the commit the teardown recorded.

widget/2 worked on issue acme/widget#10330, and its teardown event carries no items and no PRs, so no lookup by the item
finds it. `--session` names it by its Claude session (an excerpt of the output):

```bash
agent-slot reopen widget --model opus --issue acme/widget#10330 \
  --session e999f4ab-8387-4992-bb05-f4e6041b9b68 --dry-run --output json
```

```json
{
  "would_reopen": true,
  "refusal": null,
  "item": {"kind": "issue", "repo": "acme/widget", "number": 10330},
  "source": {"repo": "widget", "slot": 2, "ts": "2026-10-30T19:50:08Z", "prs": []},
  "name": "widget-issue10330-16-bit-png-trns-key-convert-rgba-misses-the",
  "session_id": "e999f4ab-8387-4992-bb05-f4e6041b9b68",
  "transcript_exists": true,
  "head": {"branch": "main", "remote": "origin", "source": {"branch": "base", "remote": "base"}},
  "slot": "widget/1",
  "command": "claude --dangerously-skip-permissions --resume e999f4ab-8387-4992-bb05-f4e6041b9b68 -n widget-issue10330-16-bit-png-trns-key-convert-rgba-misses-the"
}
```

The name is cut at a dash to fit 64 characters, and an issue keeps the base branch. A live slot that works on an issue
but has no item takes one with `adopt`, which names it `widget-issue10331-jpeg-dpi-read-from-exif-uses-xresolution-for`
and returns `key`, `name`, `items`, `item`, and `renamed`:

```bash
agent-slot adopt widget/3 --issue 10331 --output json
```

#### Probe PRs

A *probe* is a draft a slot opens to exercise CI or a reusable workflow and never means to merge. It is opened as a
draft titled `test(probe): <what it probes>`, which stays a Conventional Commits title, and only such a PR can be marked
or closed by these verbs: on an open PR, any other title is refused with `pr-title-not-probe`. Nothing infers one: the
slot's agent declares it with `agent-slot probe <pr>`, run from inside the slot, which adds the PR's number to the
record's `probes` and attaches it as a work item. The mark counts only while the PR stays a draft: the first check or
verb that sees the PR out of draft drops the mark, and a return to draft does not bring it back by itself. Marking the
PR again with `agent-slot probe` is a new declaration by the agent, and the same qualifications apply.
`agent-slot check` reports `draft` and `probe` on each of a slot's `prs`.

A probe closed unmerged neither finishes its task nor blocks its teardown, as with a reopened slot's settled PRs, and
the commit checks count it as no PR. Its head counts as pushed for its own branch and nothing else, so unpushed work on
a branch the probe was cut from still blocks. A slot whose only PR is a closed probe finishes through
`agent-slot release`. An open probe keeps the task open like any open PR, every other check still holds, and any other
PR closed unmerged stays the `pr-closed-unmerged` blocker.

A slot closes its probe with `agent-slot close-probe <pr>`, also from inside the slot, because `gh pr close` sits behind
an ask rule nobody can answer there. Both verbs act only on an open draft in the repo of the slot's origin, on a branch
this clone created, whose current head this clone pushed. They read that from the reflog of the remote-tracking ref: git
writes `update by push` there for a push from this clone and a fetch message for what it merely received, and a clone
writes no entry for the branches it brings. So a log that starts from an all-zero old oid with a push reads as a branch
this clone created, while a log that starts from a fetch reads as another writer's. A head another writer moved, once it
is fetched, has no push entry and does not qualify either. A PR already closed cannot be marked afterwards.
`close-probe` also needs the mark. It leaves a comment on the PR saying why and deletes no branch, so `gh pr reopen`
undoes it, and rerunning it on a closed probe succeeds without closing again. Neither verb has an ask rule, since a
close is undoable and reaches only work this clone pushed. Each appends a line to the ledger, as a `probe` or
`close-probe` event, whose `already_closed` tells a rerun that confirmed a close from the run that made it.

The guard stops an agent closing, by mistake, a PR it did not push. It does not stop a deliberately adversarial agent
with a shell, which could forge a reflog entry, edit the record, or call the API with the gh token; that is the
environment's trust boundary. Three limits follow from the proof, because the all-zero old oid is the tracking ref's
prior value and not origin's. Any push made while the tracking ref is missing, a fixup or one that moved nothing, reads
as this clone creating the branch, so a branch only ever seen through a pull ref and then pushed reads as this clone's.
A push that moved nothing over a stale tracking ref, on a branch this clone created, records a head this clone did not
write. A fetch that lands just before a push's own update leaves a head with no push entry: on a later push, a new
commit restores the proof, and the refusal says so; on a branch's first push, the branch reads as another writer's, and
the operator closes it.

A probe starts from a new branch, pushed before the PR opens, and targets the slot's base, so it exercises that base's
CI. `agent-slot whoami --output json` returns the slot's record, and `.slot.base` in it names the base.

```bash
git switch -c test/probe-<what>
git commit --allow-empty -m 'test(probe): <what it probes>'
git push -u origin HEAD
gh pr create --draft --base <the slot's base> --title 'test(probe): <what it probes>' --fill
agent-slot probe 487 --output json
agent-slot close-probe 487 --output json
```

#### Commands

On the Linux server, `agent-slot repos` lists the repos a slot can be made from, `agent-slot list` every slot with its
state, agent, and blockers, and `agent-slot whoami` the slot a directory is in. `agent-slot launch <repo> --model (opus
| sonnet) --request-id <id> [--prompt-file <file>]` starts an agent on that model at `--effort xhigh` on the
slot profile described above, a Sonnet one with Opus as its advisor, and agents use it to hand a task to a slot; a
repeat with the same request ID returns the same slot, and a `--prompt-file` that finds a slot another request made for
the task or item is refused with `item-held-by-slot`, so no brief is dropped; `--pr <ref>` or `--issue <ref>` gives the
slot that work item, its name, and, for a PR, its head branch (see [work items and reopen](#work-items-and-reopen)).
`agent-slot resume <repo>/<N>` restarts a dormant slot's sessions and conversation, then deletes its local branches
whose PRs all merged or closed, with origin's branch of each, keeping the base, origin's default branch, the branch
checked out, any branch a PR targets, and any branch holding work its PRs never had, and reports each delete that failed
in `prune_failed`; `agent-slot warm <repo>` (or `--all`) trusts slot paths ahead of time, and
`agent-slot check [<repo>/<N>]` gives the teardown verdict. `agent-slot adopt <repo>/<N> --pr <ref>` (or
`--issue <ref>`) attaches a PR or issue to a live slot and names the slot `<repo>-pr<N>-<slug>` or
`<repo>-issue<N>-<slug>` when it has no name; it changes only the slot's record and its Claude session's name, so it
needs no ask. `agent-slot probe <pr>` and `agent-slot close-probe <pr>`, run from inside a slot, mark and close a
throwaway draft that slot pushed (see [probe PRs](#probe-prs)). `agent-slot reopen
<repo> --model (opus | sonnet) --pr <ref> --prompt-file <file>` (or `--issue <ref>`) brings a torn-down slot's work on a
PR or issue back in a fresh slot, with its Claude conversation resumed, and `--dry-run` reports what it would do or the
refusal it would hit; agents ask before running it, `--dry-run` included. `agent-slot sweep` and `agent-slot finish
<repo>/<N>` delete slots, so both only report unless given `--yes`, and agents ask before running them. `finish` refuses
a task with an open PR (`task-has-open-pr`) unless the operator adds `--allow-open-pr` to `--yes`, as in
`agent-slot finish dotfiles/2 --yes --allow-open-pr`, which ends the task whatever state its PRs are in; a release and
the finish key never pass it, and the report-only run names it in `would_need`. `agent-slot release`, run from inside a
slot, hands that slot's teardown upstream; it deletes nothing itself, so it needs no ask. `agent-slot doctor` checks
every prerequisite and the time from key press to Claude idle. Its `key_to_ready` covers the last 20 launches from the
new-agent key, from the moment the key's tab opened to the slot's Claude starting its session, with the median of each
step between: Rex.app showing the tab, the helper's own calls, agent-slot's checks before the clone, the clone, setup,
trust, and tmux phases, and Claude's start.

`agent-slot retask <repo>/<N> (--task <name> | --issue <ref>) --prompt-file <file>` gives a live slot a new task in a
new Claude session, so one conversation never carries two tasks. Follow-up work on the same task goes to the existing
session, and work on a PR starts with `launch --pr`. The agent must be idle or absent, else `agent-busy`, and the old
work pushed, else `slot-work-unfinished`. The clone returns to the base without its other local branches. The record
takes a new session ID, name, brief, and scope, and a reopen finds the old session in `prior_sessions` and the `retask`
ledger line. A slot that starts a new task without it is stopped at its push: `slot-scope-guard.sh` denies a branch that
shares no line of work with the slot's other branches. A stacked branch shares one, and a probe's branch goes under
`probe/`.

`agent-slot resume <repo>/<N> --model (opus | sonnet)` switches a live slot's model. The slot's record takes the model,
and a Claude that is idle is ended and started again in its own pane through the command line a launch builds, resuming
its conversation by session ID, so a Sonnet slot gets its Opus advisor and the SessionStart hook gives the new session
the current slot rules. Anything held only in that Claude process, such as a scheduled wakeup or a background subagent,
ends with it. Claude's `/model` command is never used, because it also writes the model into `~/.claude/settings.json`,
the default of every new session; the restarted command line is the only thing that sets it. The JSON adds `model`,
`previous_model`, and `restarted`, and a `launch` or `reopen` repeat compares its `--model` with the slot's new model
(`model-differs`). No ask rule covers `resume`.

A Claude that is busy, waiting at a prompt, or whose state cannot be read is never ended, and neither is one listed idle
that still has a Bash command running below it: the resume checks the process tree as well as the status. Claude Code
lists a session with an unfinished background shell, such as a watcher on a CI run, as busy, so that case is refused as
`busy`. The resume fails with `agent-busy` and changes nothing. `value` is the state (`busy`, `waiting`, `unknown`),
`own-agent` for a resume run by the slot's own agent, or one `<pid> <command>` line for each running command. The
`next_step.action` is `retry` for a busy agent and for running commands, which the slot's agent or the operator can end,
and `ask-operator` otherwise: a waiting or unreadable agent needs a person, and a resume run by the slot's own agent, in
the foreground or the background, needs another session, since ending that Claude would end the resume. Rerunning while
commands run changes nothing, so it is the check for them; `agent-slot list --output json` shows each slot's `.agent`
for the other states. With no Claude running, only the record changes: `agent-slot` starts no Claude in a session that
exists, so the model applies when the session is created again. Naming the model the slot already runs is a plain
resume, so a call whose answer was lost can be repeated. A pane the operator has scrolled back in is taken out of copy
mode first, before anything changes; if tmux cannot, the resume fails with `tmux-failed` and changes nothing. If the
line cannot be typed after the old Claude is gone, the Claude session is dropped and the error is `tmux-failed`, or
`tmux-unresponsive` when tmux did not answer, with partial side effects; `agent-slot resume <repo>/<N>` then creates the
session on the new model. If the session cannot be dropped either, `next_step.command` is the tmux command that drops
it.

Every release request, refusal, and `--not-yet`, every `finish --yes`, and every `sweep --yes` pass appends one JSON
line to `~/.local/state/agent-slot/teardown.log`: what ran it (`operator`, `release`, or `timer`), the slots it tore
down with each clone's purge (whether it was purged, its trash entry, the milliseconds it took, and a failure's code and
next step), the ones it kept with their blocker codes, the agents it typed the closing steps or a reminder to, the files
each cleanup reminder named, the slots held by `--not-yet`, the Claude sessions it renamed, whether a finish had
`--allow-open-pr`, why a release or finish was refused, and, for a refusal over background jobs, each job's PID and
command. A release's own finish writes its output to `~/.local/state/agent-slot/logs/release-<repo>-<N>.log`. The sweep
timer's schedule is `OnCalendar=*:0/10` in `agent-slot-sweep.timer`; change it with
`systemctl --user edit agent-slot-sweep.timer`, an empty `OnCalendar=` line, and the new schedule. A release's finish
waits up to `AGENT_SLOT_RELEASE_WAIT` seconds (3600) for the agent, looking every `AGENT_SLOT_RELEASE_POLL` seconds (5).

The keys run `agent-slot-rex launch`, `agent-slot-rex restore`, and `agent-slot-rex finish`, which on the Mac hand the
verb to the server's helper; each pane runs `agent-slot-rex attach <repo>/<N> claude|files|git`, a prime tab runs
`agent-slot-rex prime <repo>`, the control session's tab runs `agent-slot-rex sweep`, and `agent-slot-rex doctor` checks
the server's side. Every verb answers `--help`. Each launch runs the sweep again in the control session's one sweep tab,
opening it when there is none; the tab stays open while something needs you, and `r` in it sweeps again. Restore, sweep,
and finish change tabs one at a time: each waits up to `AGENT_SLOT_REX_LOCK_WAIT` seconds (300) for the one ahead of it
to finish, so it sees the tabs that one opened. Each of those passes appends one JSON line to
`~/.local/state/agent-slot-rex/reconcile.log`: when it ran, what ran it (`restore`, `restore-at-start`, `push`, `poll`,
`sweep`, or `finish`), how long it took, whether it changed a tab, the tabs it planned to open, relabel, and close, and
`ok` or the error that stopped it. Past 1 MiB the log moves to `reconcile.log.1`. Rex takes a tab label of at most 128
characters, so a longer one is cut at the end of its needs-you message and ends in `…`.

With `--output json`, every verb prints one JSON object on success and one error object on stderr, with a `reason` from
the table below, an exit code (0 ok, 1 failed, 2 usage, 77 auth, 78 configuration), a `next_step`, a `recovery` that
says whether a retry is safe, and a `log`. `--output` goes after the verb. `agent-slot schema` prints both objects as
JSON Schema with every reason, and each verb's `--help` lists the fields it returns.

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
| `brief-incomplete`            | 2    | A brief lacks a required line, or its `Touches:` line holds no glob or a glob git rejects      |
| `slot-limit-reached`          | 78   | The repo holds the most live slots allowed; finish one, or raise `AGENT_SLOT_MAX_PER_REPO`     |
| `clone-failed`                | 1    | Cloning from origin failed; retry with the same request ID                                     |
| `solutions-symlink-missing`   | 78   | The solutions repo is missing or has no origin/main, so the slot gets no worktree of it        |
| `tracked-link-leaves-slot`    | 78   | The head tracks `.claude`, `docs`, or `.context` as a link that leaves the slot                |
| `hooks-path-outside-checkout` | 78   | The repo's own `core.hooksPath` points outside its checkout                                    |
| `git-crypt-locked`            | 78   | A git-crypt repo could not be unlocked: git-crypt or its key is missing                        |
| `trust-dialog-unrecognized`   | 78   | Claude showed a screen other than its trust dialog for the path; accept it by hand             |
| `prime-untrusted`             | 78   | `warm --all` found repos whose prime Claude does not trust; open Claude once in each prime     |
| `tmux-unresponsive`           | 1    | The `agent-slots` tmux server did not answer in time                                           |
| `tmux-failed`                 | 1    | A tmux session could not be started; `agent-slot resume` tries again                           |
| `pr-state-unknown`            | 1    | `gh` could not read the repo's PRs or a work item; check `gh auth status`, then retry          |
| `item-not-found`              | 2    | GitHub has no such PR or issue that `gh` can see; `agent-slot launch --help` gives the forms   |
| `item-kind-mismatch`          | 2    | The number is a PR given as `--issue`, or an issue given as `--pr`; swap the flag              |
| `item-held-by-slot`           | 1    | A live slot holds the item or its session; brief that slot, or `agent-slot resume` it          |
| `pr-title-not-probe`          | 1    | `probe` or `close-probe` refused: an open PR's title is not `test(probe): <what it probes>`    |
| `pr-not-probe`                | 1    | `close-probe` refused: the PR is not marked a probe; `agent-slot probe` it first               |
| `pr-not-draft`                | 1    | `probe` or `close-probe` refused: the PR is not a draft, so closing it is the operator's call  |
| `pr-not-open`                 | 1    | A closed or merged PR cannot be marked, and a merged one cannot be closed                      |
| `pr-not-from-this-slot`       | 1    | The PR is in another repo, on a branch this slot did not create, or has a head it did not push |
| `pr-close-failed`             | 1    | `gh pr close` failed, so the PR may or may not be closed; rerunning `close-probe` is safe      |
| `model-differs`               | 1    | A repeat found its slot on another model than `--model`; `message` names the slot's model      |
| `agent-busy`                  | 1    | `resume --model` found the agent busy, waiting, unreadable, or running jobs; nothing changed   |
| `slot-work-unfinished`        | 1    | A new task would strand the old one; `value` names what is left                                |
| `slot-checkout-failed`        | 1    | `retask` could not reach the base, and changed nothing                                         |
| `session-in-use`              | 1    | A Claude agent has the session open; the operator closes it, then the reopen runs again        |
| `item-not-found-in-ledger`    | 1    | No teardown names the item; `--session <id>` finds an older slot, or launch a fresh one        |
| `transcript-missing`          | 1    | Claude Code no longer has the conversation to resume; launch a fresh slot for the item         |
| `task-has-open-pr`            | 1    | `finish` refused an open PR; merge or close it, or the operator reruns with `--allow-open-pr`  |
| `teardown-blocked`            | 1    | `finish` kept the slot; `agent-slot check <repo>/<N>` names why                                |
| `slot-outside-root`           | 78   | The slot path resolves outside the slot root, so nothing was deleted; look at it by hand       |
| `gh-auth-missing`             | 77   | `gh` is not signed in; `gh auth login`                                                         |
| `git-crypt-key-missing`       | 78   | There is no git-crypt key to unlock git-crypt repos with                                       |
| `solutions-corpus-missing`    | 78   | The shared solutions repo is not cloned, or has no origin/main to make slot worktrees from     |
| `solutions-worktree-orphaned` | 0    | Doctor warning: a slot's solutions worktree outlived its slot; `value` is path, files, commits |
| `slots-config-missing`        | 78   | `slots.conf` is not deployed; `scripts/stow-deploy tmux`                                       |
| `prune-timer-inactive`        | 78   | The slot server's orphan-client prune timer is not enabled                                     |
| `slot-path-untrusted`         | 78   | Doctor warning: a slot path, or the repo's prime checkout, is not trusted in Claude yet        |
| `bypass-mode-unaccepted`      | 78   | Doctor warning: settings.json does not accept bypass mode; `scripts/stow-deploy claude`        |
| `version-unverified`          | 0    | Doctor warning: Claude or Rex differs from the version the checklist last ran on               |
| `repo-required`               | 2    | The new-agent key was pressed outside a repo's session, with no terminal to ask in             |
| `prime-not-running`           | 1    | The new-agent key found the session's prime tmux session not running; start it, press again    |
| `server-unreachable`          | 1    | ssh from the Mac to the Linux server failed; retry once the network is back                    |
| `rex-action-unregistered`     | 78   | Rex has not loaded the agent-slot actions; deploy the `rex` package or run `rex config reload` |
| `rex-failed`                  | 1    | A `rex` command failed; retry                                                                  |
| `reconcile-busy`              | 1    | Another restore, sweep, or finish held the tab lock too long; retry                            |
| `compound-not-run`            | 1    | `release` refused: the slot's session has not run `ce-compound` and its `mode:refresh` run yet |
| `background-jobs-running`     | 1    | `release` refused: the slot's Claude still runs background jobs, named in `value`              |
| `finished-by-operator`        | 1    | `release --not-yet` refused: the operator finished the slot, and `--not-yet` does not undo it  |
| `release-withdrawn`           | 1    | A release's `finish` stood down: a `--not-yet` or a newer release replaced its release         |
| `sweep-timer-inactive`        | 78   | The automatic sweep timer is not enabled; `bash scripts/host-jobs-enable.sh`                   |
| `warm-timer-inactive`         | 78   | The timer that trusts new slot paths is not enabled; `bash scripts/host-jobs-enable.sh`        |
| `agent-slot-timed-out`        | 1    | A local `agent-slot` call outlived its bound; its outcome is unknown. `agent-slot-rex restore` |
| `wrong-host`                  | 2    | That `agent-slot-rex` verb runs only on the Linux server; `ssh <server> agent-slot-rex doctor` |
| `rex-server-down`             | 78   | No Rex server answers on the Linux server; `systemctl --user start rex-server.service`         |
| `startup-pending`             | 1    | Rex is still starting and its start-up step has not finished; rerun after the start-up limit   |
| `rex-server-restarted`        | 1    | The Rex server restarted under a reconcile pass, which then stopped; the new one reconciles    |
| `rex-server-foreign`          | 78   | Doctor: `rex-server.service` did not start the Rex server holding the socket; see `next_step`  |
| `rex-restart-pending`         | 0    | Doctor warning: the installed Rex is newer than the running server; update the apps first      |
| `reconcile-timer-inactive`    | 78   | The once-a-minute reconcile timer is not running; `systemctl --user enable --now` it           |
| `tab-numbers-inactive`        | 78   | The tab-number watcher is not running; `systemctl --user enable --now rex-tab-numbers.service` |
| `login-server-inactive`       | 78   | The Rex login server is not running, so no Rex client can reach the Linux server               |
| `rexurrect-missing`           | 78   | Doctor warning: rexurrect is not installed, so own tabs are not restored after a Rex restart   |
| `reconcile-stale`             | 1    | The reconcile timer runs but its journal shows no recent good pass; `agent-slot-rex restore`   |
| `own-tabs-unrestored`         | 0    | Doctor warning: the start-up step did not restore the operator's own tabs into this Rex server |
| `review-grant-from-slot`      | 1    | `grant-review` refused: run from a slot or its tmux server; only the operator grants           |
| `slot-head-missing`           | 1    | `grant-review` refused: the slot has no branch or commit to count rounds under                 |
| `scope-grant-from-slot`       | 1    | `grant-scope` refused: run from a slot or its tmux server; only the operator grants scope      |
| `grant-needs-terminal`        | 1    | `grant-scope` refused: no terminal, or a shell under Claude Code, so no person types the key   |
| `grant-not-confirmed`         | 1    | `grant-scope` refused: the answer typed at the terminal was not the slot's key                 |
| `tmux-outside-scope`          | 0    | Doctor warning: the slot tmux server runs in a service's cgroup and would end with that unit   |

#### Teardown blockers

`agent-slot check` names what keeps a finished slot with one of these codes, a count or the offending paths, and a
message such as `1 unpushed commit`. A blocker can also carry a `next_step` in the error object's shape.
`checked-by-own-agent` does, pointing at `agent-slot release`, which tears the slot down from outside once its agent is
idle; that blocker never joins the needs-you list, and a check run inside the slot's own agent leaves the slot's record
as it found it. `solutions-unpublished` does too, pointing at `git -C <worktree> status --short`, and its `values` name
each file as `docs/solutions/<path>`, the path the slot's agent reaches it by.

| Code                     | What keeps the slot                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------- |
| `pr-state-unknown`       | `gh` could not read the PRs, so whether the task has finished is unknown                             |
| `pr-closed-unmerged`     | A PR other than a probe closed without merging; reopen and merge it, or press the finish key         |
| `git-state-unknown`      | `git` could not fetch, or read the slot's state                                                      |
| `agent-not-idle`         | The agent is mid-turn or waiting on the operator                                                     |
| `checked-by-own-agent`   | The check runs inside the slot's own agent, which keeps it busy until the check ends                 |
| `agent-state-unknown`    | The agent's state could not be read, or a process outside the slot's panes uses the slot             |
| `uncommitted-changes`    | Tracked files have changes beyond setup pointing `docs/solutions` at the slot's solutions worktree   |
| `stash-present`          | Something is stashed                                                                                 |
| `unpushed-commits`       | Commits are in no PR's final head and on no origin branch or tag or fork branch, counting local tags |
| `commits-without-pr`     | Commits sit only on an origin or fork branch that has no PR, such as one pushed after the merge      |
| `untracked-files`        | Untracked files, or ignored ones other than build output and copies of tracked files                 |
| `local-only-files`       | `.context` files except setup's repo-recon link, and `todos`, `TODO*`, or `.env*` files              |
| `solutions-unpublished`  | The slot's solutions worktree holds a file, commit, or rebase origin/main lacks; publish or discard  |
| `home-symlink-into-slot` | A symlink under the home directory resolves into the slot                                            |
| `home-scan-incomplete`   | The scan for such symlinks did not finish                                                            |
| `slot-busy`              | Another `agent-slot` process holds the slot                                                          |
| `not-released`           | The automatic sweep found the task finished, but its agent is gone or never released it              |

When processes outside the slot's panes use the slot, `agent-state-unknown` names each one in its message and in
`values` as `<pid> <command>`, and names it by its oldest ancestor that still uses the slot. A loop that keeps starting
short-lived children there is named by the loop, which lives on, rather than by whichever child the scan caught.

#### Purge failures

A torn-down slot's `purge` carries one of these codes when its clone is still in the trash, with a `message`, a `log`
when `rm` failed, and a `next_step` whose command is `trash-rm <clone path>`. That command purges every trash entry
whose original path is the clone's path; only agent-slot moves a whole slot path to the trash, so each of those entries
is a clone of that slot.

| Code                  | What is left in the trash                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| `trash-entry-unknown` | The move added no single entry for the clone's path, such as one in another volume's trash       |
| `purge-failed`        | `rm` failed or ran past 180 seconds; the entry's `.trashinfo` stays until its files are all gone |

### System-Level Units (`config/systemd/system/`)

System-level systemd units are **not** managed by stow (which targets `$HOME`). They live in `config/systemd/system/`
and are deployed via `scripts/nas-deploy.sh`, which copies them to `/etc/systemd/system/` and activates them.

| Unit                | Purpose                                         |
| ------------------- | ----------------------------------------------- |
| `mnt-nas.mount`     | SMB mount for the NAS (`//<nas-host>/openclaw`) |
| `mnt-nas.automount` | On-demand automount, solves WiFi boot race      |

**Deploy:** `sudo scripts/nas-deploy.sh` (requires `/root/.smbcredentials-<nas-host>` from 1Password).

Four more system-level configs deploy through their own paths: `apparmor-playwright.service` (with the AppArmor profile,
via `scripts/apparmor-deploy.sh`, below), the `ollama` loopback override (`sudo stow -t /etc`, see the `ollama`
package), the sshd locale change (`sudo scripts/sshd-locale-deploy.sh`, which edits `/etc/ssh/sshd_config` in place; see
[BOOTSTRAP.md § SSH session locale](BOOTSTRAP.md#ssh-session-locale)), and the kernel settings in `config/sysctl.d/`
(`sudo scripts/sysctl-deploy.sh`; see [BOOTSTRAP.md § Kernel settings](BOOTSTRAP.md#kernel-settings)).

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
provisions all three, run as your normal user (it escalates to sudo only where needed). On a Mac it deploys the browser
set and skips the other two:

```bash
scripts/playwright-deps-deploy.sh            # browser set + AppArmor profile + boot persistence (Chromium / browse)
scripts/playwright-deps-deploy.sh --webkit   # + Safari/iOS system libs (WebKit, heavy ~380 MB)
scripts/playwright-deps-deploy.sh --all       # + Chromium and WebKit system libs
```

The **system browser set** is one Chrome for Testing build with its headless shell, one WebKit, and one ffmpeg in the
shared cache (`$PLAYWRIGHT_BROWSERS_PATH`), provisioned by `scripts/playwright-browsers-deploy.sh` (run directly, or via
the script above) on the Linux server and on Apple silicon Macs. Every version, revision, alias list, and archive sha256
comes from `config/playwright/browsers.pin`, read through one parser. Archives come over `curl` and `unzip` rather than
`playwright install`, because node's extractor deadlocks on this host's io_uring/kernel combo, each held to the pin's
sha256. Every Chromium and ffmpeg revision a Playwright release from 1.57 to the pin's `source-release` asks for is an
alias to the set, and WebKit is the one revision the pin's `library-version` (the Playwright the repos run) names, with
no alias. A repo's `playwright install` naming the set's browsers is a no-op whichever Playwright in that range it pins,
WebKit aside, which only a Playwright naming the pin's `webkit-revision` finds (a bare install also pulls Firefox, which
no alias covers); moving the set is a pin edit, steps in the runbook. The script registers the set in the cache's
`.links`, so another tool's install does not delete it, and `scripts/playwright-browsers-deploy.sh --check` reports any
difference from the pin with a stable reason. WebKit deps are opt-in because they pull ~180 packages and are only needed
for Safari/iOS e2e (the `mobile-ios` / `tablet` projects). See
[docs/runbooks/playwright-browser-launch.md](docs/runbooks/playwright-browser-launch.md) for the reason table, failure
signatures, the io_uring root cause, and recovery.

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
The hook runs that directory first, on a quiet machine, only when the push changes a file the shells read (see
`SHELL_STARTUP_PATHS` in `.githooks/lib/push-scope.sh`), and it times the checkout's startup files rather than the
installed ones. Each measurement is a best-of-N minimum: run at the tail of the full suite, the several hundred shells
it spawns push interactive zsh past its budget with nothing about the config having changed.

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
| `pre-commit`    | Blocks commits on `main`, verifies `commit.gpgsign`, gates staged paths |
| `post-checkout` | Auto-unlocks git-crypt, restows changed packages, chains Git LFS        |
| `post-merge`    | Auto-unlocks git-crypt, restows changed packages, chains Git LFS        |
| `pre-push`      | Mirrors CI (shellcheck, actionlint, bats, core-env), chains Git LFS     |

Both gates call the same dispatchers CI calls — `scripts/lint-shell`, `scripts/lint-workflows`, `scripts/run-tests`,
`scripts/core-env-guard.sh` — so the three cannot drift. `pre-push` runs them over the whole repo; `pre-commit` runs
them over staged paths only. See [AGENTS.md § Local gates mirror CI](AGENTS.md#local-gates-mirror-ci).

## CI and Testing

| Workflow                    | Trigger                | Purpose                                                       |
| --------------------------- | ---------------------- | ------------------------------------------------------------- |
| `release.yml`               | Push to `main`         | CalVer tag + GitHub Release, notes read from `CHANGELOG.md`   |
| `shellcheck.yml`            | Pull request           | Lints shell scripts and hooks, then workflows with actionlint |
| `bats.yml`                  | Pull request           | Runs the bats-core test suites, split across parallel shards  |
| `cache-seed.yml`            | Push to `dev`          | Saves the bats tools' caches on `dev` for pull requests       |
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
