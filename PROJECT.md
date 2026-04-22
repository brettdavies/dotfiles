# Dotfiles

> For setup instructions, see [README.md](README.md).

## Overview

Personal dotfiles configuration store for macOS and Linux. Manages shell configs, editor settings, git/ssh config,
secrets, and package lists using GNU Stow with git-crypt encryption.

## Quick Reference

| Field          | Value                                                       |
|----------------|-------------------------------------------------------------|
| **Status**     | Maintenance (config store)                                  |
| **Active CLI** | [dotfiles-cli](https://github.com/brettdavies/dotfiles-cli) |

## Technical Stack

| Category               | Technologies                     |
|------------------------|----------------------------------|
| **Symlink Management** | GNU Stow (`--dotfiles` mode)     |
| **Secrets**            | git-crypt (symmetric encryption) |
| **Package Management** | Homebrew Brewfile, oh-my-zsh     |
| **Shell**              | Zsh (Powerlevel10k), Bash        |
| **Automation**         | macOS LaunchAgent (iCloud sync)  |

## What This Repo Contains

- **32 stow packages** — shell/editor config (shell, zsh, bash, git, ssh, gh, github, claude, codex, cursor, opencode,
  tmux, tmuxinator, lazygit, micro, yazi, ghostty), package state (brew, bun, pip, local), secrets (secrets, ssh, caam),
  Linux-only daemons (obsidian, rclone, qmd, opendataloader-pdf, openclaw, rust, gogcli), and macOS-only (launchagent).
  See [README.md](README.md#stow-packages) for the full table.
- **16 shell environment fragments** — sourced automatically by `.profile` from `config/shell/`
- **Brewfile + Brewfile.optional** — declarative macOS package lists
- **git-crypt encrypted secrets** — API keys, SSH config, allowed signers
- **System-level units and AppArmor profiles** — NAS automount, Playwright userns profile (copy-deployed, not stow)
- **iCloud Drive sync** — rsync with hardlinks via LaunchAgent

## Key Design Decisions

- **Stow `--dotfiles` convention** — repo files use `dot-` prefix, stow converts to `.` prefix at symlink time
- **`config/shell/` auto-sourcing** — `.profile` globs `*.sh` from a non-stow directory, no manifest to maintain
- **Secrets in-repo** — encrypted at rest via git-crypt, auto-unlocked by git hooks on checkout/merge
- **Cross-platform** — `$OSTYPE` checks gate macOS-specific features (Homebrew, LaunchAgent, VS Code paths)

---

*For bootstrap steps, see [BOOTSTRAP.md](BOOTSTRAP.md).*
