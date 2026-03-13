# Changelog

All notable changes to this project will be documented in this file.

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

