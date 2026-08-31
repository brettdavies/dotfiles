# shellcheck shell=bash
# Central package and tool cache directory
# This file configures environment variables for package manager and tool cache locations
# Caches are stored under XDG_CACHE_HOME (XDG Base Directory Specification) for easy management and cleanup
#
# Some entries below relocate an install root rather than a cache (PIPX_HOME, PNPM_HOME, BUN_INSTALL,
# GOPATH). An install root only relocates safely when every launcher agrees on it, and contexts that
# never source this chain — systemd user units, cron, git hooks, GUI-launched processes — resolve the
# stock path regardless of what is set here. Deleting a relocated cache costs a re-download; a
# relocated install root that only half the machine can see is a split toolchain.

# Set XDG_CACHE_HOME according to XDG Base Directory Specification
# Defaults to ~/.cache if not already set, allowing users to override if needed
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Create the cache directory if it doesn't exist
[ ! -d "$XDG_CACHE_HOME" ] && mkdir -p "$XDG_CACHE_HOME"

# ============================================================================
# System/OS Package Managers
# ============================================================================

# Homebrew cache (macOS only)
if [[ "$OSTYPE" == "darwin"* ]]; then
  export HOMEBREW_CACHE="$XDG_CACHE_HOME/homebrew"
fi

# ============================================================================
# Language Package Managers
# ============================================================================

# Python package managers and tools
export POETRY_CACHE_DIR="$XDG_CACHE_HOME/pypoetry"
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip" # also set in stow/pip/dot-config/pip/pip.conf
export PIPX_HOME="$XDG_CACHE_HOME/pipx"
export UV_CACHE_DIR="$XDG_CACHE_HOME/uv"
# Note: uvx (uv's tool runner) uses the same UV_CACHE_DIR

# Node.js package managers
# npm cache set via env var (belt-and-suspenders: also in ~/.npmrc via `npm config set cache`)
# NPM_CONFIG_CACHE env var avoids slow `npm config set` on every shell start (~105ms)
# npx uses the same cache location as npm ($XDG_CACHE_HOME/npm/_npx)
export NPM_CONFIG_CACHE="$XDG_CACHE_HOME/npm"
export YARN_CACHE_FOLDER="$XDG_CACHE_HOME/yarn"
export PNPM_HOME="$XDG_CACHE_HOME/pnpm"
export BUN_INSTALL="$XDG_CACHE_HOME/bun"

# Rust is absent by design. CARGO_HOME and RUSTUP_HOME are install roots, not caches: rustup-init
# writes to the stock ~/.cargo and ~/.rustup, and the systemd timer, git hooks and agent tool calls
# all read them there. Setting them here would apply to interactive shells only, leaving one host
# with two toolchain sets and two binary directories. Cargo's own caches (registry/, git/) sit
# inside ~/.cargo and are pruned with `cargo cache`, not by relocation.

# Go cache
export GOCACHE="$XDG_CACHE_HOME/go-build"
export GOPATH="$XDG_CACHE_HOME/go"

# ============================================================================
# Testing and Browser Automation Tools
# ============================================================================

export CYPRESS_CACHE_FOLDER="$XDG_CACHE_HOME/cypress"
export PLAYWRIGHT_BROWSERS_PATH="$XDG_CACHE_HOME/playwright"
# Browsers are dotfiles-provisioned into the shared cache above via
# scripts/playwright-browsers-deploy.sh (curl + unzip). This skips Playwright's
# auto-download during `bun install` (its postinstall), where Node/libuv's
# io_uring extractor deadlocks on this kernel. It does NOT stop an explicit
# `playwright install`; the provisioned markers do that. A browser missing from
# the dotfiles set fails fast ("Executable doesn't exist") instead of wedging;
# the fix is a dotfiles bump.
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PUPPETEER_CACHE_DIR="$XDG_CACHE_HOME/puppeteer"

# ============================================================================
# Platform and Runtime Tools
# ============================================================================

export DENO_DIR="$XDG_CACHE_HOME/deno"
export FIREBASE_CACHE_DIR="$XDG_CACHE_HOME/firebase"

# ============================================================================
# Notes: Tools Configured Elsewhere or Not Configurable
# ============================================================================

# Hugging Face cache
# Note: Hugging Face cache is configured in ~/.models.sh

# PyTorch cache
# Note: PyTorch cache is configured in ~/.models.sh

# MLX and mlx-lm cache
# Note: MLX and mlx-lm use Hugging Face's cache system for model storage
# Models are downloaded and cached via HF_HOME/HUGGINGFACE_HUB_CACHE (configured in ~/.models.sh)
# MLX doesn't have separate cache environment variables; it uses HuggingFace's infrastructure

# Prisma ORM cache
# Note: Prisma doesn't have an official environment variable for cache location
# The cache is typically at ~/.cache/prisma, but we can't easily redirect it

# ============================================================================
# Create Cache Directories
# ============================================================================

# System/OS caches
if [[ "$OSTYPE" == "darwin"* ]]; then
  [ ! -d "$HOMEBREW_CACHE" ] && mkdir -p "$HOMEBREW_CACHE"
fi

# Python caches
[ ! -d "$POETRY_CACHE_DIR" ] && mkdir -p "$POETRY_CACHE_DIR"
[ ! -d "$PIP_CACHE_DIR" ] && mkdir -p "$PIP_CACHE_DIR"
[ ! -d "$PIPX_HOME" ] && mkdir -p "$PIPX_HOME"
[ ! -d "$UV_CACHE_DIR" ] && mkdir -p "$UV_CACHE_DIR"

# Node.js caches
[ ! -d "$XDG_CACHE_HOME/npm" ] && mkdir -p "$XDG_CACHE_HOME/npm"
[ ! -d "$YARN_CACHE_FOLDER" ] && mkdir -p "$YARN_CACHE_FOLDER"
[ ! -d "$PNPM_HOME" ] && mkdir -p "$PNPM_HOME"
[ ! -d "$BUN_INSTALL" ] && mkdir -p "$BUN_INSTALL"

# Go caches
[ ! -d "$GOCACHE" ] && mkdir -p "$GOCACHE"
[ ! -d "$GOPATH" ] && mkdir -p "$GOPATH"

# Testing and browser automation caches
[ ! -d "$CYPRESS_CACHE_FOLDER" ] && mkdir -p "$CYPRESS_CACHE_FOLDER"
[ ! -d "$PLAYWRIGHT_BROWSERS_PATH" ] && mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
[ ! -d "$PUPPETEER_CACHE_DIR" ] && mkdir -p "$PUPPETEER_CACHE_DIR"

# Platform and runtime caches
[ ! -d "$DENO_DIR" ] && mkdir -p "$DENO_DIR"
[ ! -d "$FIREBASE_CACHE_DIR" ] && mkdir -p "$FIREBASE_CACHE_DIR"

# Each line above is a `[ ! -d X ] && mkdir -p X` short-circuit, so the file's exit status is
# whichever the last one evaluated to — non-zero once that directory exists. Callers that source
# the chain under `set -e` abort on it, so end on an unconditional success.
:
