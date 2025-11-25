#!/usr/bin/env bash
# Minimal loader - loads only core utilities and argument parsing
# For simple scripts that only need basic output and argument parsing
# Sources: core/constants.sh, core/detect-os.sh, util/output.sh, util/args.sh

# Prevent re-sourcing
if [ -n "${LIB_MINIMAL_LOADED:-}" ]; then
    return 0
fi
export LIB_MINIMAL_LOADED=1

# Get the lib directory (parent of loaders directory)
# Allow override via _LIB_DIR for testing frameworks that modify BASH_SOURCE
if [ -z "${_LIB_DIR:-}" ]; then
    # Try to find our directory from BASH_SOURCE
    # BASH_SOURCE[0] in bash points to this file when sourced
    # But some test frameworks (BATS) may modify this, so try multiple approaches
    _source_file="${BASH_SOURCE[0]:-}"
    if [ -n "$_source_file" ] && [[ "$_source_file" == */loaders/* ]]; then
        _LOADER_DIR="$(cd "$(dirname "$_source_file")" && pwd)"
        _LIB_DIR="${_LOADER_DIR%/loaders}"
    elif [ -n "${LIB_DIR:-}" ]; then
        # Test helper sets LIB_DIR
        _LIB_DIR="$LIB_DIR"
    else
        # Last resort: try relative to current script if it looks like a loader path
        _LOADER_DIR="$(cd "$(dirname "${0:-./}")" && pwd)"
        if [[ "$_LOADER_DIR" == */loaders ]]; then
            _LIB_DIR="${_LOADER_DIR%/loaders}"
        else
            echo "Error: Cannot determine lib directory (BASH_SOURCE=$_source_file)" >&2
            return 1
        fi
    fi
    unset _source_file
fi

# Verify the path exists
if [ ! -d "$_LIB_DIR/core" ]; then
    echo "Error: Cannot find lib directory at $_LIB_DIR" >&2
    return 1
fi

# Source core layer (no dependencies)
source "$_LIB_DIR/core/constants.sh"
source "$_LIB_DIR/core/detect-os.sh"

# Source util layer (depends on core)
source "$_LIB_DIR/util/output.sh"
source "$_LIB_DIR/util/args.sh"

# Note: Don't unset _LIB_DIR - parent loaders may need it

