#!/usr/bin/env bash
# Homebrew package checking functions
# Provides functions for checking Homebrew packages, casks, and taps
# Requires: pkg/cache.sh (for caching functions), pkg/extensions.sh (for get_cursor_command)

# Prevent re-sourcing
if [ -n "${LIB_PKG_BREW_LOADED:-}" ]; then
    return 0
fi
export LIB_PKG_BREW_LOADED=1

# Source cache if not already sourced
if ! command -v get_cached_package_status &> /dev/null || ! command -v update_package_cache &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/cache.sh" 2>/dev/null || true
fi

# ============================================================================
# Homebrew Package Checking
# ============================================================================

# Check if a tap is installed (uses cache if available)
# Usage: is_tap_installed <tap_name>
# Returns: 0 if installed, 1 if not
is_tap_installed() {
    local tap="$1"
    local cached_status
    
    # Try cache first
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        cached_status=$(get_cached_package_status "$tap" "tap")
        if [ "$cached_status" = "installed" ]; then
            return 0
        elif [ "$cached_status" = "missing" ]; then
            return 1
        fi
    fi
    
    # Fallback to actual check
    if command -v brew &> /dev/null; then
        if brew tap | grep -q "^$tap"; then
            # Update cache
            update_package_cache "$tap" "installed" "tap"
            return 0
        else
            # Update cache
            update_package_cache "$tap" "missing" "tap"
            return 1
        fi
    fi
    
    return 1
}

# Check if a Homebrew package is installed (uses cache if available)
# Usage: is_brew_package_installed <package_name>
# Returns: 0 if installed, 1 if not
is_brew_package_installed() {
    local pkg="$1"
    local cached_status
    
    # Try cache first
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        cached_status=$(get_cached_package_status "$pkg" "package")
        if [ "$cached_status" = "installed" ]; then
            return 0
        elif [ "$cached_status" = "missing" ]; then
            return 1
        fi
    fi
    
    # Fallback to actual check
    if command -v brew &> /dev/null; then
        if brew list "$pkg" &>/dev/null 2>&1; then
            # Update cache
            update_package_cache "$pkg" "installed" "package"
            return 0
        else
            # Update cache
            update_package_cache "$pkg" "missing" "package"
            return 1
        fi
    fi
    
    return 1
}

# Check if a Homebrew cask is installed (uses cache if available)
# Usage: is_brew_cask_installed <cask_name>
# Returns: 0 if installed, 1 if not
is_brew_cask_installed() {
    local cask="$1"
    local cached_status
    
    # Try cache first
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        cached_status=$(get_cached_package_status "$cask" "cask")
        if [ "$cached_status" = "installed" ]; then
            return 0
        elif [ "$cached_status" = "missing" ]; then
            return 1
        fi
    fi
    
    # Fallback to actual check
    if command -v brew &> /dev/null; then
        if brew list --cask "$cask" &>/dev/null 2>&1; then
            # Update cache
            update_package_cache "$cask" "installed" "cask"
            return 0
        else
            # Update cache
            update_package_cache "$cask" "missing" "cask"
            return 1
        fi
    fi
    
    return 1
}

