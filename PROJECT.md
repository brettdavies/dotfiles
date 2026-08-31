# Dotfiles

> For setup instructions, see [README.md](README.md).

## Overview

Personal dotfiles configuration store for macOS and Linux. Manages shell configs, editor settings, git/ssh config,
secrets, and package lists using GNU Stow with git-crypt encryption.

## Philosophy

Config-only, but built to fleet-grade standards: every flow is automated, idempotent, and safe to run unattended across
many hosts. This repo is as much a reflection of how I work as it is the configuration it carries.

- **Automation over toil** — nothing manual survives twice; deploys are scriptable end-to-end with no human in the loop.
  "A manual step does not scale" ([CONCEPTS.md](CONCEPTS.md)).
- **Fail fast, fail safe** — preconditions run before any mutation, destructive steps stage aside to avoid data-loss
  windows, and headless and interactive paths diverge explicitly. Failure modes are designed for, not discovered.
- **Single source of truth** — shared config and package order live in one place; cross-package symlinks share files
  instead of copying them.
- **Documentation is part of the system** — brainstorm → plan → ship docs, a [CONCEPTS.md](CONCEPTS.md) glossary, and a
  `docs/solutions/` corpus capture decisions so they are not re-solved later.
- **Opinions enforced by tooling** — Conventional Commits, a present-state doc policy, and a 200-line refactor trigger
  are gated by hooks and CI, not left to memory.
- **AI tooling as infrastructure** — local LLM and agent services (Ollama, qmd) are versioned, hardened, and deployed
  like any other daemon.

## Quick Reference

| Field      | Value                      |
| ---------- | -------------------------- |
| **Status** | Maintenance (config store) |

## Technical Stack

| Category               | Technologies                                                         |
| ---------------------- | -------------------------------------------------------------------- |
| **Symlink Management** | GNU Stow (`--dotfiles` mode)                                         |
| **Secrets**            | git-crypt (symmetric encryption)                                     |
| **Package Management** | Homebrew Brewfile, oh-my-zsh                                         |
| **Shell**              | Zsh (Powerlevel10k), Bash                                            |
| **Automation**         | macOS LaunchAgent (iCloud sync), Linux systemd user units            |
| **Testing**            | bats-core suites                                                     |
| **CI / Release**       | GitHub Actions (shellcheck, bats); CalVer tags + git-cliff changelog |
| **Supply Chain**       | Minimum-release-age gates (brew, uv, bun, cargo); SHA-pinned Actions |

## What This Repo Contains

- **33 stow packages** — shell/editor config (shell, zsh, bash, git, ssh, gh, github, claude, codex, cursor, opencode,
  tmux, tmuxinator, lazygit, micro, yazi, ghostty), package state (brew, bun, pip, local), secrets (secrets, ssh, caam),
  Linux-only daemons (obsidian, rclone, qmd, opendataloader-pdf, rust, caddy, codex-proxy, ollama), and macOS-only
  (launchagent). See [README.md](README.md#stow-packages) for the full table.
- **20 shell environment fragments** — sourced automatically by `.profile` from `config/shell/`
- **Brewfile + Brewfile.optional** — declarative macOS package lists
- **git-crypt encrypted secrets** — API keys, SSH config, allowed signers
- **System-level units and AppArmor profiles** — NAS automount, Playwright userns profile (copy-deployed, not stow)
- **iCloud Drive sync** — rsync with hardlinks via LaunchAgent

## Key Design Decisions

- **Stow `--dotfiles` convention** — repo files use `dot-` prefix, stow converts to `.` prefix at symlink time
- **`config/shell/` auto-sourcing** — `.profile` globs `*.sh` from a non-stow directory, no manifest to maintain
- **Secrets in-repo** — encrypted at rest via git-crypt, auto-unlocked by git hooks on checkout/merge
- **Cross-platform** — `$OSTYPE` checks gate macOS-specific features (Homebrew, LaunchAgent, Cursor paths)

## Engineering Practices

- **Tested** — bats-core suites cover `stow-deploy`, git hooks, shell config, supply-chain gates, and the CLI wrappers
- **Linted and CI-mirrored** — shellcheck and bats run as required GitHub Actions checks, and the pre-push hook runs the
  same checks locally so failures surface before the push
- **Fail-fast deploy** — `stow-deploy` runs preconditions (git-crypt unlock, disk space, dirty tree, stow version) and
  returns distinct exit codes for automation
- **Release automation** — squash-merge to `main` computes a CalVer tag and generates the changelog with git-cliff;
  branch protection is version-controlled in `.github/rulesets/`
- **Single source of truth** — package order, shell environment, and PR templates each have one authoritative location;
  cross-package symlinks share files without duplication
- **Supply-chain safety** — minimum-release-age gates apply across brew, uv, bun, and cargo; GitHub Actions are pinned
  to commit SHAs
- **Documented domain** — [CONCEPTS.md](CONCEPTS.md) defines project vocabulary; `docs/plans/` and `docs/brainstorms/`
  hold design context

---

*For bootstrap steps, see [BOOTSTRAP.md](BOOTSTRAP.md).*
