# Central package and tool cache directory
# This file configures environment variables for package manager and tool cache locations
# All caches are stored under XDG_CACHE_HOME (XDG Base Directory Specification) for easy management and cleanup

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
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
export PIPX_HOME="$XDG_CACHE_HOME/pipx"
export UV_CACHE_DIR="$XDG_CACHE_HOME/uv"
# Note: uvx (uv's tool runner) uses the same UV_CACHE_DIR

# Node.js package managers
# Note: npm cache is configured via npm config, not environment variable
# The cache directory will be set if npm is available
# npx uses the same cache location as npm, so it will use $XDG_CACHE_HOME/npm/_npx
if command -v npm &> /dev/null; then
    npm config set cache "$XDG_CACHE_HOME/npm" 2>/dev/null || true
fi
export YARN_CACHE_FOLDER="$XDG_CACHE_HOME/yarn"
export PNPM_HOME="$XDG_CACHE_HOME/pnpm"
export BUN_INSTALL="$XDG_CACHE_HOME/bun"

# Rust package managers
export CARGO_HOME="$XDG_CACHE_HOME/cargo"
export RUSTUP_HOME="$XDG_CACHE_HOME/rustup"

# Go cache
export GOCACHE="$XDG_CACHE_HOME/go-build"
export GOPATH="$XDG_CACHE_HOME/go"

# ============================================================================
# Testing and Browser Automation Tools
# ============================================================================

export CYPRESS_CACHE_FOLDER="$XDG_CACHE_HOME/cypress"
export PLAYWRIGHT_BROWSERS_PATH="$XDG_CACHE_HOME/playwright"
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

# Rust caches
[ ! -d "$CARGO_HOME" ] && mkdir -p "$CARGO_HOME"
[ ! -d "$RUSTUP_HOME" ] && mkdir -p "$RUSTUP_HOME"

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
