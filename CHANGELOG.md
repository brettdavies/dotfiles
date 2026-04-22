# Changelog

All notable changes to this project will be documented in this file.

## [2026.04.22]

### Added

- AppArmor profile for Playwright's Chromium binaries (both `chrome-headless-shell` and full `chrome`), deployed with `sudo scripts/apparmor-deploy.sh`. Persists across reboots via `/etc/apparmor.d/`. by @brettdavies in [#39](https://github.com/brettdavies/dotfiles/pull/39)
- `opendataloader-pdf` stow package: socket unit (`127.0.0.1:5002`), service unit (socket-activated, hardened with `NoNewPrivileges` + `PrivateTmp`), and a two-file launcher (`opendataloader-pdf-hybrid-sa` sh wrapper + `.py` module with LISTEN_FDS dispatch and asyncio idle-exit watchdog). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `scripts/opendataloader-pdf-enable.sh` — one-shot idempotent enable script that stops orphan listeners, reloads systemd, enables `--now` the socket unit, and smoke-tests `/health`.
- `--idle-timeout` flag on the launcher; defaults to 60 s so qmd isn't starved by ODL's residual 4.4 GB.
- Stow-managed `qmd-serve.service` systemd user unit for the sequential-mode daemon (always-on, peak VRAM ~2.6 GB instead of ~5.4 GB). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `config/shell/qmd.sh` exports `QMD_SERVER=http://127.0.0.1:7832` in all shell contexts (interactive, non-interactive zsh, cron, systemd children that source `.profile`).
- `stow/qmd/dot-local/bin/qmd` sh wrapper dispatches to the brettdavies/qmd fork at `$HOME/dev/qmd/qmd`.
- `scripts/qmd-serve-enable.sh` is a Linux-only idempotent one-shot that cleans orphan `:7832` listeners, reloads systemd, enables --now, and smokes `/health`.
- `target/**` ignore and `# Canonical version: 2026.04.15` header in the canonical markdownlint config so per-repo copies can detect drift with a one-liner comparison. by @brettdavies in [#49](https://github.com/brettdavies/dotfiles/pull/49)

### Changed

- Change release-branch construction from `git merge origin/development` to cherry-picking PR squash commits, so `git-cliff --unreleased` only sees the true release delta. by @brettdavies in [#37](https://github.com/brettdavies/dotfiles/pull/37)
- `scripts/stow-deploy`: `opendataloader-pdf` added to `SHARED_PACKAGES` and to the Linux-only skip block (macOS deploys skip with a WARNING). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `qmd-embed.service` and `qmd-update.service` ExecStart switched to `%h/.local/bin/qmd` (the new stow wrapper). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `QMD_SERVER` export moved out of `stow/shell/dot-profile` into `config/shell/qmd.sh` (feature-named file convention).
- Rename `CLAUDE.md` to `AGENTS.md` so Claude Code, opencode, Cursor, and Codex all read the same project-level instructions. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)
- Update `README.md` stow-package table: add `github`, `openclaw`, `opendataloader-pdf`, and `rust` rows; expand the `qmd` row to cover the new qmd-serve daemon and `.local/bin/qmd` wrapper.
- Update `README.md` Shell Environment table: add `qmd.sh` (exports `QMD_SERVER`).
- Update `README.md` Release Automation section: rename `RELEASE_TOKEN` → `CI_RELEASE_TOKEN` and clarify that release notes come from the committed `CHANGELOG.md`, not from git-cliff at CI time.
- Update `BOOTSTRAP.md` manual stow commands to include `github` (macOS + headless) and `opendataloader-pdf` (headless), matching `scripts/stow-deploy`'s `SHARED_PACKAGES`.
- Update `PROJECT.md` counts (17 → 32 stow packages, 11 → 16 shell fragments) and expand the package breakdown.
- Correct the `RELEASES.md` pipeline diagram to show cherry-picking from dev onto a `release/*` branch branched from main (matches the flow landed in #37).

### Fixed

- `qmd-update.service` now sets an explicit `PATH` that includes the Homebrew prefix so timer-triggered runs can resolve subprocess dependencies. by @brettdavies in [#46](https://github.com/brettdavies/dotfiles/pull/46)
- Auto-format hook now reads its global config fallback from `~/.markdownlint-cli2.yaml` (stow-managed symlink to dotfiles canonical) instead of the deleted `~/.claude/.markdownlint-cli2.yaml` stray. by @brettdavies in [#49](https://github.com/brettdavies/dotfiles/pull/49)
- Realign table column widths across `AGENTS.md`, `README.md`, `PROJECT.md`, and `RELEASES.md` so they satisfy MD060 `aligned` style after the widened rows. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)

### Documentation

- Document the cherry-pick flow and rename "Why branch from main, not development" to explain both the `add/add` conflict and the orphan-history failure modes that motivate this workflow. by @brettdavies in [#37](https://github.com/brettdavies/dotfiles/pull/37)
- Describe \`docs/solutions/\` structure and search path in \`CLAUDE.md\` Reference section. by @brettdavies in [#41](https://github.com/brettdavies/dotfiles/pull/41)
- Mark \`docs/plans/2026-04-21-001-feat-opendataloader-pdf-socket-activation-plan.md\` as \`completed\` with post-ship notes describing shipped state, deviations, and measured timings. by @brettdavies in [#42](https://github.com/brettdavies/dotfiles/pull/42)

**Full Changelog**: [2026.04.15...2026.04.22](https://github.com/brettdavies/dotfiles/compare/2026.04.15...2026.04.22)

## [2026.04.15]

### Added

- Add `DO_NOT_TRACK=1` universal telemetry opt-out (consoledonottrack.com) plus targeted opt-outs for VS Code (`VSCODE_TELEMETRY_LEVEL=off`), PowerShell (`POWERSHELL_TELEMETRY_OPTOUT=1`), and Azure Functions Core Tools (`FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT=1`) by @brettdavies in [#31](https://github.com/brettdavies/dotfiles/pull/31) and [#32](https://github.com/brettdavies/dotfiles/pull/32)
- Add nightly autocommit for `obsidian-vault`, `solutions-docs`, and agent-skills with a systemd timer randomized to 2-4 AM CT by @brettdavies in [#33](https://github.com/brettdavies/dotfiles/pull/33)
- Add `mnt-nas.automount` for on-demand NAS mounting (fixes the WiFi boot race) and `scripts/nas-deploy.sh` for copy-deploying system-level systemd units by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)
- Add `github/` stow package targeting `~/.config/github/` for repo-workflow templates; `SHARED_PACKAGES` in `scripts/stow-deploy` now includes it by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)

### Changed

- Rename `RELEASING.md` to `RELEASES.md` and restructure to the canonical release-doc layout shared across brettdavies repos by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)
- Move the canonical PR template from `stow/claude/dot-claude/templates/pull-request.md` to `stow/github/dot-config/github/pull_request_template.md`; `.github/pull_request_template.md` is now a real inlined file so GitHub's PR-template discovery works
- Prohibit AI-attribution trailers on commit messages and PR bodies via global CLAUDE.md directive
- Move `QMD_SERVER` and Bun PATH exports from `.zshrc` to `.profile` so cron, SSH commands, and other non-interactive contexts see them
- Support markdown hard line breaks (two trailing spaces) in the `md-wrap.py` PostToolUse hook and in the markdownlint config; prefer the project-local `markdownlint-cli2.yaml` over the global one for line-width
- Strengthen the query-solutions-first instruction in global CLAUDE.md
- Stop tracking `TODOS.md` (added to global gitignore)

### Fixed

- Fix nightly autocommit to embed the Conventional Commits spec and SRP rules in the prompt, and delegate full add+commit to `claude -p` rather than staging in shell

### Documentation

- Document the system-level systemd units pattern in CLAUDE.md (copy-deploy, not stow) and add a matching section to README.md by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)

**Full Changelog**: [2026.04.01...2026.04.15](https://github.com/brettdavies/dotfiles/compare/2026.04.01...2026.04.15)

## [2026.04.01]

### Added

- Add `gogcli` stow package with `config.json` and shell wrapper by @brettdavies in
  [#27](https://github.com/brettdavies/dotfiles/pull/27)
- Add tmuxinator stow package with 13 declarative session YAML configs by @brettdavies in
  [#28](https://github.com/brettdavies/dotfiles/pull/28)
- Add `mux` (tmuxinator passthrough) and `mux-all` (start all sessions) shell functions
- Add caam account manager stow package with daemon auto-start and `claude-switch`
- Add headless Obsidian stow package with systemd service, config, and CLI wrapper
- Add rclone Box bisync stow package with systemd timer and git-crypt encrypted config
- Add systemd user timers for qmd, openclaw, and nightly rustup-update
- Add supply-chain safety for uv, npm, pip, and bun (package age gates)
- Add TPM bootstrap instructions to BOOTSTRAP.md

### Changed

- Adopt changelog-as-committed-artifact release process (no more CI-generated changelog)
- Inline brew shellenv to eliminate Ruby subprocess on startup (~200ms savings)
- Replace docs/solutions/ directory with symlink to shared solutions-docs repo
- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN by @brettdavies in [#26](https://github.com/brettdavies/dotfiles/pull/26)
- Pin external GitHub Actions to commit SHAs, upgrade to actions/checkout v6.0.2

### Fixed

- Add Homebrew site-functions to zsh fpath (fixes completions for tmuxinator, brew, gh, bat, etc.)
- Split caam interactive/non-interactive wrapper, add claude-switch helper
- Update openclaw service paths from OpenClaw to Areas/openclaw
- Enable rclone bisync filters and exclude Obsidian per-device state

### Documentation

- Add RELEASING.md with CalVer release branch procedure
- Overhaul README and extract bootstrap guide

**Full Changelog**: [2026.03.19...2026.04.01](https://github.com/brettdavies/dotfiles/compare/2026.03.19...2026.04.01)

## [2026.03.19]

### Changed

- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN for clarity by @brettdavies in
  [#26](https://github.com/brettdavies/dotfiles/pull/26)

**Full Changelog**: [2026.03.18...2026.03.19](https://github.com/brettdavies/dotfiles/compare/2026.03.18...2026.03.19)

## [2026.03.18]

### Added

- Add `bun`, `pip`, `codex`, `opencode`, `local` stow packages
- Add `lazygit`, `micro`, `yazi` stow packages with configs
- Add platform-aware `$EDITOR` via `config/shell/` and `.gitconfig`
- Add `gh` CLI merge guard wrapper to block AI merges into `main`/`master`
- Add encrypted `gh` hosts.yml via git-crypt

### Changed

- Cross-platform editor config, CI hardening, new stow packages, and docs overhaul by @brettdavies in
  [#23](https://github.com/brettdavies/dotfiles/pull/23)
- Overhaul README with stow package table, shell environment table, and performance section
- Extract BOOTSTRAP.md from README with detailed platform-specific setup

### Fixed

- Release workflow fixes and action SHA pinning by @brettdavies in
  [#24](https://github.com/brettdavies/dotfiles/pull/24)
- Pin all external actions to commit SHAs
- Fix release body extraction (use git-cliff action output instead of bare CLI)

**Full Changelog**: [2026.03.13...2026.03.18](https://github.com/brettdavies/dotfiles/compare/2026.03.13...2026.03.18)

## [2026.03.13]

### Added

- Per-platform git config templates (`config/git/local.linux`, `config/git/local.darwin`)
- `stow-deploy` auto-deploys platform template to `~/.config/git/local` if absent

### Fixed

- Cross-platform hardening for shell scripts, SSH config, and git signing by @brettdavies in
  [#22](https://github.com/brettdavies/dotfiles/pull/22)
- Headless server adoption (OpenClaw, EDITOR/VISUAL, printer aliases, tmux)
- Cross-platform guards (Obsidian macOS-only, hbash Linuxbrew fallback)

### Documentation

- Compound solution: cross-platform shell idiom and config hardening

**Full Changelog**:
  [2026.03.12.1...2026.03.13](https://github.com/brettdavies/dotfiles/compare/2026.03.12.1...2026.03.13)

## [2026.03.12.1]

### Fixed

- Force Node.js 24 for GitHub Actions by @brettdavies in [#20](https://github.com/brettdavies/dotfiles/pull/20)

**Full Changelog**:
  [2026.03.12...2026.03.12.1](https://github.com/brettdavies/dotfiles/compare/2026.03.12...2026.03.12.1)

## [2026.03.12]

### Added

- Initial dotfiles repository with GNU Stow
- Script library with sync, verification, and dry-run
- Git-crypt encryption for secrets, SSH config, and git allowed_signers
- iCloud sync via LaunchAgent (macOS)
- Claude Code configuration and project documentation
- Cross-platform deployment to Ubuntu server
- `scripts/stow-deploy` conflict resolution wrapper with `--headless` mode by @brettdavies in
  [#4](https://github.com/brettdavies/dotfiles/pull/4)
- Repo-local enforcement (hooks, rulesets, config) by @brettdavies in
  [#3](https://github.com/brettdavies/dotfiles/pull/3)
- Auto-configure `core.hooksPath` in stow-deploy by @brettdavies in [#7](https://github.com/brettdavies/dotfiles/pull/7)
- CalVer changelog automation with git-cliff by @brettdavies in [#16](https://github.com/brettdavies/dotfiles/pull/16)
- `stow/tmux` package with full tmux config and TPM by @brettdavies in
  [#11](https://github.com/brettdavies/dotfiles/pull/11)
- Platform-aware package sets (`SHARED_PACKAGES` + `DESKTOP_PACKAGES`) by @brettdavies in
  [#12](https://github.com/brettdavies/dotfiles/pull/12)

### Changed

- Restructure as configuration store, remove shell CLI
- Zero-disk secret loading with `op inject`
- Branch workflow enforcement and documentation

### Fixed

- Cross-platform git signing and Claude Code hook guards
- Portable binary detection in git hooks by @brettdavies in [#8](https://github.com/brettdavies/dotfiles/pull/8)
- Standardize hook shebangs, add strict mode, optimize git-crypt check by @brettdavies in
  [#5](https://github.com/brettdavies/dotfiles/pull/5)
- Shell startup optimization from ~440ms to ~190ms by @brettdavies in
  [#14](https://github.com/brettdavies/dotfiles/pull/14)

### Documentation

- Compound solution for deployment hardening (sentinel, binary detection, auto hooks) by @brettdavies in
  [#10](https://github.com/brettdavies/dotfiles/pull/10)
