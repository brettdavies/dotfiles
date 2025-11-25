#!/usr/bin/env bash
# Standard loader - loads common features for most install scripts
# Sources: minimal + paths, traps, temp, logging, verbose, progress

# Prevent re-sourcing
if [ -n "${LIB_STANDARD_LOADED:-}" ]; then
    return 0
fi
export LIB_STANDARD_LOADED=1

# Get the lib directory (parent of loaders directory)
# Reuse _LIB_DIR if already set (e.g., by test helper or parent loader)
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

# Source minimal loader first
source "$_LIB_DIR/loaders/minimal.sh"

# Source core layer (shell detection - provides Bash feature flags)
source "$_LIB_DIR/core/detect-shell.sh"

# Source additional util layer
source "$_LIB_DIR/util/paths.sh"
source "$_LIB_DIR/util/timestamp.sh"

# Source feature layer
source "$_LIB_DIR/feature/traps.sh"
source "$_LIB_DIR/feature/temp.sh"
source "$_LIB_DIR/feature/logging.sh"
source "$_LIB_DIR/feature/verbose.sh"
source "$_LIB_DIR/feature/progress.sh"

# Note: Don't unset _LIB_DIR - full.sh cleans up

