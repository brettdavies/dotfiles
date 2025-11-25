#!/usr/bin/env bash
# Packages loader - loads standard + package management functions
# For scripts that need Homebrew/package management but not stow/sync/filesystem operations

# Prevent re-sourcing
if [ -n "${LIB_PACKAGES_LOADED:-}" ]; then
    return 0
fi
export LIB_PACKAGES_LOADED=1

# Get the lib directory (parent of loaders directory)
# Reuse _LIB_DIR if already set (e.g., by test helper)
if [ -z "${_LIB_DIR:-}" ]; then
    _source_file="${BASH_SOURCE[0]:-}"
    if [ -n "$_source_file" ] && [[ "$_source_file" == */loaders/* ]]; then
        _LOADER_DIR="$(cd "$(dirname "$_source_file")" && pwd)"
        _LIB_DIR="${_LOADER_DIR%/loaders}"
    elif [ -n "${LIB_DIR:-}" ]; then
        _LIB_DIR="$LIB_DIR"
    fi
    unset _source_file
fi

# Source standard loader first
source "$_LIB_DIR/loaders/standard.sh"

# Source package management layer
source "$_LIB_DIR/pkg/cache.sh"
source "$_LIB_DIR/pkg/brew.sh"
source "$_LIB_DIR/pkg/extensions.sh"
source "$_LIB_DIR/pkg/version.sh"
source "$_LIB_DIR/pkg/version-constraints.sh"

# Note: Don't unset _LIB_DIR - full.sh may need it

