# Changelog

All notable changes to this project will be documented in this file.

## Pre-automation History

### Added

- Cross-platform dotfiles deployment (macOS + headless Ubuntu)
  with GNU Stow, git-crypt, and SSH-based authentication
- Shell environment chain (.profile -> .zshenv -> .zshrc/.bashrc)
  with platform-aware PATH, Homebrew, and secret loading
- Automated conflict resolution via stow-deploy wrapper script

### Changed

- Optimized zsh interactive startup from ~440ms to ~190ms
