# Dotfiles-lib

> **Note:** This is a project overview card. For technical documentation and setup instructions, see [README.md](README.md).

## Overview

A production-grade personal dotfiles management system featuring 78,000+ lines of shell configuration and library code with enterprise-level architecture. Built with a modular 8-layer library system (core, util, feature, filesystem, shell, package, domain, loaders), comprehensive BATS test suite (29 test files, 2,250 LOC), git-crypt encryption for secrets, and cross-platform support for macOS and Linux. Demonstrates senior-level engineering practices applied to infrastructure tooling including dependency injection via loader pattern, package status caching for 10-100x faster checks, and three-way merge sync system.

## Quick Reference

| Field | Value |
|-------|-------|
| **Status** | Active |
| **Build Time** | ~3 weeks (Nov 6-28, 2025) |

## Technical Stack

| Category | Technologies |
|----------|--------------|
| **Languages** | Bash, Zsh, Shell Script |
| **Frameworks** | GNU Stow, BATS (Bash Automated Testing System) |
| **Infrastructure** | Docker (Alpine, Ubuntu), macOS LaunchAgent |
| **Security** | git-crypt (symmetric encryption) |
| **Key Patterns** | Modular library architecture, Loader pattern, Cross-platform compatibility, Package caching |

## Key Achievements

- Architected modular shell library system with 6,988 lines across 38 modules organized in 8 conceptual layers following Single Responsibility Principle
- Implemented comprehensive BATS test suite with 29 test files (2,250 LOC) and Docker-based cross-platform validation (Alpine, Ubuntu)
- Built three-way merge sync system using git HEAD as base, with binary detection, rollback capability, and dry-run preview
- Designed package status caching using associative arrays achieving 10-100x faster Homebrew/extension checks
- Integrated git-crypt transparent encryption for sensitive files with automatic unlock via git hooks
- Created iCloud Drive sync automation using rsync with hardlinks via macOS LaunchAgent
- Achieved cross-platform compatibility supporting Bash 3.2+ through 5.2+ and Zsh 5.0+ with intelligent feature detection

## Technical Highlights

- **Modular Library Architecture:** 8-layer system (core → util → feature → fs → shell → pkg → domain → loaders) with three loader tiers (minimal, standard, full) enabling dependency injection and selective loading based on script requirements
- **Comprehensive Testing:** 29 BATS test files with Docker-based cross-platform validation across Alpine and Ubuntu, test helper utilities, and organized structure mirroring library modules
- **Advanced Error Handling:** Comprehensive trap handlers for cleanup, SIGINT/SIGTERM handling, temporary directory auto-cleanup, and enhanced error context using FUNCNAME/funcfiletrace arrays

## Code Metrics

| Metric | Value |
|--------|-------|
| **Lines of Code** | ~78,000 total (6,988 library, 66,358 config, 2,250 tests) |
| **Primary Language** | Bash/Zsh (Shell Script) |
| **Test Coverage** | 29 BATS test files with Docker cross-platform validation |
| **Key Dependencies** | GNU Stow, git-crypt, BATS, Docker, rsync, diff3 |

---

*For detailed technical documentation, setup instructions, and contribution guidelines, please see [README.md](README.md).*
