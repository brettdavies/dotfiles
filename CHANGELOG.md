# Changelog

All notable changes to this project will be documented in this file.

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
