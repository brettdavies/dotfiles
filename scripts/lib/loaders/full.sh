#!/usr/bin/env bash
# Full loader - loads everything
# For scripts that need all functionality (e.g., check-implementation.sh)

# Prevent re-sourcing
if [ -n "${LIB_FULL_LOADED:-}" ]; then
    return 0
fi
export LIB_FULL_LOADED=1

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

# Source core layer (shell detection)
source "$_LIB_DIR/core/detect-shell.sh"

# Source shell layer
source "$_LIB_DIR/shell/zsh-modules.sh"
source "$_LIB_DIR/shell/arrays.sh"
source "$_LIB_DIR/shell/strings.sh"

# Source filesystem layer
source "$_LIB_DIR/fs/file-ops.sh"
source "$_LIB_DIR/fs/find.sh"
source "$_LIB_DIR/fs/zsh-globs.sh"

# Source feature layer (remaining)
source "$_LIB_DIR/feature/validation.sh"
source "$_LIB_DIR/feature/rollback.sh"

# Source package management layer
source "$_LIB_DIR/pkg/cache.sh"
source "$_LIB_DIR/pkg/brew.sh"
source "$_LIB_DIR/pkg/extensions.sh"
source "$_LIB_DIR/pkg/version.sh"
source "$_LIB_DIR/pkg/version-constraints.sh"

# Source domain layer
source "$_LIB_DIR/domain/stow.sh"
source "$_LIB_DIR/domain/sync.sh"
source "$_LIB_DIR/domain/sync-backup.sh"
source "$_LIB_DIR/domain/sync-merge.sh"

# Clean up - this is the top-level loader so we can unset now
unset _LIB_DIR _LOADER_DIR 2>/dev/null || true

