# Changelog

All notable changes to this project will be documented in this file.

## [2026.04.01] - 2026-04-02

### Added

- Add `gogcli` stow package with `config.json` and shell wrapper for cross-shell, cross-context availability by @brettdavies in [#27](https://github.com/brettdavies/dotfiles/pull/27)
- Add adopt-back in shell wrapper to capture `config.json` drift when gogcli writes to it at runtime
- Add tmuxinator stow package with 13 declarative session YAML configs by @brettdavies in [#28](https://github.com/brettdavies/dotfiles/pull/28)
- Add `mux` (tmuxinator passthrough) and `mux-all` (start all sessions) shell functions
- Add TPM bootstrap instructions to BOOTSTRAP.md

### Changed

- Move git hooks from `scripts/git-hooks/` to `.githooks/` (de facto convention) by @brettdavies in [#3](https://github.com/brettdavies/dotfiles/pull/3)
- Add LFS chaining to post-checkout, post-merge, and new pre-push hook
- Add `.githooks/setup` bootstrap script for `core.hooksPath` automation
- Add GitHub rulesets (protect-main, protect-development), PR template, ShellCheck CI
- Rewrite CLAUDE.md from stale library-system docs to current config-store architecture
- Update README repository layout and bootstrap guide with hook setup step
- Fix `gh-pr-comments` alias (broken quoting) by converting to shell function
- Fix `GPG_TTY` export to avoid SC2155
- Use direct `markdownlint-cli2` binary instead of `bunx`
- Add `.stow-global-ignore` and `.markdownlint-cli2.yaml` symlink
- **New:** `scripts/stow-deploy` -- conflict resolution wrapper with `--headless` mode for fleet deployment by @brettdavies in [#4](https://github.com/brettdavies/dotfiles/pull/4)
- **Fix:** `stow/shell/dot-profile` -- guard `~/.local/bin/env` sourcing with `[ -f ... ]`
- **Docs:** `README.md` -- updated bootstrap step 4 to recommend `stow-deploy`, added to repo layout
- **Docs:** `CLAUDE.md` -- added conflict resolution section to Stow Packages
- **Docs:** Updated plan with SpecFlow analysis findings (pre-flight checks, error classification)
- **stow/tmux**: New stow package with full tmux config by @brettdavies in [#11](https://github.com/brettdavies/dotfiles/pull/11)
- **stow/ssh**: Add `bigdaddy` host entry
- Add `--all` flag with platform-aware package sets (`SHARED_PACKAGES` + `DESKTOP_PACKAGES`) by @brettdavies in [#12](https://github.com/brettdavies/dotfiles/pull/12)
- Add tree-fold detection and resolution for 4 historically tree-folded packages
- Split `local` package into `local` (shared) + `launchagent` (macOS desktop-only)
- Add distinct exit codes (2-6) for automation/CI
- Add `gh` CLI wrapper to block AI merges into `main`/`master`
- Add `IdentityFile` to all SSH hosts with `IdentitiesOnly`
- Reorganize SSH config for first-match-wins ordering with Tailscale VPN overrides
- Inline `~/.local/bin` PATH in `.profile` (remove stow dependency)
- Add bats test suite (21 tests across 3 files)
- Fix bash 3.2 compatibility (`declare -A` → loop-based dedup)
- Fix `git clean -ffdx` flags for tree-fold cleanup (gitignored files + nested repos)
- Fix dangling `.markdownlint-cli2.yaml` symlink from tree-fold era
- Update 5 solution docs, mark plan completed, fix stale references
- Cross-reference pip cache-dir settings between `caches.sh` and `pip.conf`
- Replace `npm config set cache` with `NPM_CONFIG_CACHE` env var (~105ms saving) by @brettdavies in [#14](https://github.com/brettdavies/dotfiles/pull/14)
- Unify compinit: set `ZSH_COMPDUMP` before oh-my-zsh, remove duplicate 50-line block (~170ms saving)
- Add `zcompile` safety net for compiled completion dump (~170ms -> ~2ms)
- Replace `brew --prefix` calls with `$HOMEBREW_PREFIX` env var (~32ms saving)
- Add 4 startup performance budget tests for all shell environments
- Remove ~100 lines of dead code (commented-out oh-my-zsh boilerplate, 4 near-identical platform branches)
- Compound solution doc: `docs/solutions/performance-issues/zsh-interactive-startup-optimization.md`
- Add `cliff.toml` with conventional commit → keep-a-changelog mapping and CalVer-compatible `tag_pattern` by @brettdavies in [#16](https://github.com/brettdavies/dotfiles/pull/16)
- Add `.github/workflows/release.yml` triggered on push to `main` with dual-layer infinite loop prevention
- Add seed `CHANGELOG.md` with pre-automation history summary
- Update `.github/rulesets/protect-main.json` with Admin (RepositoryRole 5) bypass actor
- Add Release Automation docs to `README.md` (workflow overview, RELEASE_TOKEN setup/rotation)
- Fix 10 pre-existing MD013 line-length violations in README
- Enhance `auto-format.sh` PostToolUse hook to report MD013 line-length limit from config in `additionalContext`
- **Per-platform git config templates**: `stow-deploy` now auto-deploys `config/git/local.linux` to by @brettdavies in [#21](https://github.com/brettdavies/dotfiles/pull/21)
- **Headless server adoption**: OpenClaw completions, EDITOR/VISUAL, printer aliases, tmux titles/pane
- **Cross-platform guards**: Obsidian path (macOS-only), hbash alias (Linuxbrew fallback), printer aliases
- **Lint fixes**: SC2155 in profile, MD013 line-length in solution doc and plan
- Change `setup_gogcli.sh` to reference stow-managed wrapper instead of printing manual shell profile instructions by @brettdavies in [#27](https://github.com/brettdavies/dotfiles/pull/27)

**Full Changelog**: [2026.03.18...2026.04.01](https://github.com/brettdavies/dotfiles/compare/2026.03.18...2026.04.01)

## [2026.03.18] - 2026-03-18

### Fixed

- Release workflow fixes and action SHA pinning (#24)

## [2026.03.13] - 2026-03-13

### Fixed

- Cross-platform hardening, per-platform git templates, and compound docs (#22)

## [2026.03.12.1] - 2026-03-12

### Fixed

- Force Node.js 24 for GitHub Actions (#20)

## [2026.03.12] - 2026-03-12

### Added

- Initial dotfiles repository with GNU Stow
- Script library with sync, verification, and dry-run
- Git-crypt, iCloud sync, and config reorganization
- Claude Code configuration and project documentation
- Tool, shell, and SSH configuration updates
- Cross-platform deployment to Ubuntu server
- Repo-local enforcement, stow-deploy, and cross-platform SSH auth (#6)
- Auto-configure core.hooksPath in stow-deploy (#7)
- CalVer changelog automation with git-cliff (#17)

### Changed

- Modular library architecture with BATS tests and shell features
- Restructure as configuration store, remove shell CLI
- Zero-disk secret loading with op inject
- Branch workflow enforcement and documentation

### Documentation

- Compound solution for deployment hardening (sentinel, binary detection, auto hooks) (#10)

### Fixed

- Cross-platform git signing and Claude Code hook guards
- Portable binary detection in git hooks (#8)
- Portable binary detection, sentinel fix, and auto hooks (#9)
- Use git-cliff action output for release body (#19)

### Release

- Deployment automation, testing, and shell performance (PRs #3-#14)

