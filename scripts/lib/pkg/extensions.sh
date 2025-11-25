#!/usr/bin/env bash
# IDE extension checking functions
# Provides functions for checking VS Code and Cursor extensions
# Requires: pkg/cache.sh (for caching functions)

# Prevent re-sourcing
if [ -n "${LIB_PKG_EXTENSIONS_LOADED:-}" ]; then
    return 0
fi
export LIB_PKG_EXTENSIONS_LOADED=1

# Source cache if not already sourced
if ! command -v get_cached_package_status &> /dev/null || ! command -v update_package_cache &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/cache.sh" 2>/dev/null || true
fi

# ============================================================================
# IDE Extension Checking
# ============================================================================

# Get Cursor command path
# Usage: get_cursor_command
# Returns: cursor command path via echo, or empty string if not found
get_cursor_command() {
    if command -v cursor &> /dev/null; then
        echo "cursor"
    elif [ -f "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
        echo "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
    fi
}

# Check if a VS Code extension is installed (uses cache if available)
# Usage: is_vscode_extension_installed <extension_id>
# Returns: 0 if installed, 1 if not
is_vscode_extension_installed() {
    local ext="$1"
    local cached_status
    
    if ! command -v code &> /dev/null; then
        return 1
    fi
    
    # Try cache first
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        cached_status=$(get_cached_package_status "$ext" "vscode_ext")
        if [ "$cached_status" = "installed" ]; then
            return 0
        elif [ "$cached_status" = "missing" ]; then
            return 1
        fi
    fi
    
    # Fallback to actual check
    if code --list-extensions 2>/dev/null | grep -q "^${ext}$"; then
        # Update cache
        update_package_cache "$ext" "installed" "vscode_ext"
        return 0
    else
        # Update cache
        update_package_cache "$ext" "missing" "vscode_ext"
        return 1
    fi
}

# Check if a Cursor extension is installed (uses cache if available)
# Usage: is_cursor_extension_installed <extension_id> <cursor_cmd>
# Returns: 0 if installed, 1 if not
is_cursor_extension_installed() {
    local ext="$1"
    local cursor_cmd="$2"
    local cached_status
    
    if [ -z "$cursor_cmd" ]; then
        return 1
    fi
    
    # Try cache first
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        cached_status=$(get_cached_package_status "$ext" "cursor_ext")
        if [ "$cached_status" = "installed" ]; then
            return 0
        elif [ "$cached_status" = "missing" ]; then
            return 1
        fi
    fi
    
    # Fallback to actual check
    local installed_exts
    installed_exts=$("$cursor_cmd" --list-extensions 2>/dev/null || echo "")
    if echo "$installed_exts" | grep -q "^${ext}$"; then
        # Update cache
        update_package_cache "$ext" "installed" "cursor_ext"
        return 0
    else
        # Update cache
        update_package_cache "$ext" "missing" "cursor_ext"
        return 1
    fi
}

