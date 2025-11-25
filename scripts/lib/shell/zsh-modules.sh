#!/usr/bin/env bash
# Zsh module loading library
# Provides functions for loading zsh modules
# Requires: core/detect-os.sh (for is_zsh)

# Prevent re-sourcing
if [ -n "${LIB_ZSH_MODULES_LOADED:-}" ]; then
    return 0
fi
export LIB_ZSH_MODULES_LOADED=1

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# ============================================================================
# Zsh Module Loading
# ============================================================================

# Load zsh modules for enhanced functionality
# 
# Purpose: Conditionally loads zsh modules that provide built-in functionality
#   for better performance and features. Respects modules already loaded in .zshrc
# 
# Parameters: None
# 
# Returns: 0 on success, 1 if not running under zsh
# 
# Side effects: Loads zsh modules and sets export flags (only if not already set)
# 
# Example:
#   load_zsh_modules
#   if [ -n "${ZSH_FILES_LOADED:-}" ]; then
#       zf_mkdir -p "$dir"
#   fi
# 
# Modules loaded:
#   - zsh/files: Built-in file operations (zf_ln, zf_mkdir, zf_rm, zf_chmod)
#   - zsh/stat: Built-in stat command (zstat)
#   - zsh/datetime: Date/time functions (strftime, etc.)
#   - zsh/parameter: Advanced parameter expansion features
#   - zsh/mapfile: Enhanced mapfile (if available)
# 
# Note: Checks for existing ZSH_*_LOADED flags before loading to respect
#   modules already loaded in .zshrc (prevents conflicts and respects user config)
load_zsh_modules() {
    if ! is_zsh; then
        return 1
    fi
    
    # Load zsh/files module for built-in file operations
    # Check if already loaded (from .zshrc) before attempting to load
    if [ -z "${ZSH_FILES_LOADED:-}" ]; then
        # Use -F flag to load specific functions only
        if zmodload -F zsh/files b:zf_ln b:zf_mkdir b:zf_rm b:zf_chmod 2>/dev/null; then
            export ZSH_FILES_LOADED=1
        else
            # Try loading the entire module if selective loading fails
            if zmodload zsh/files 2>/dev/null; then
                export ZSH_FILES_LOADED=1
            fi
        fi
    fi
    
    # Load zsh/stat module for built-in stat command
    if [ -z "${ZSH_STAT_LOADED:-}" ]; then
        if zmodload zsh/stat 2>/dev/null; then
            export ZSH_STAT_LOADED=1
        fi
    fi
    
    # Load zsh/datetime module for date/time functions
    if [ -z "${ZSH_DATETIME_LOADED:-}" ]; then
        if zmodload zsh/datetime 2>/dev/null; then
            export ZSH_DATETIME_LOADED=1
        fi
    fi
    
    # Load zsh/parameter module for advanced parameter expansion
    if [ -z "${ZSH_PARAMETER_LOADED:-}" ]; then
        if zmodload zsh/parameter 2>/dev/null; then
            export ZSH_PARAMETER_LOADED=1
        fi
    fi
    
    # Try to load zsh/mapfile (may not be available in all zsh versions)
    if [ -z "${ZSH_MAPFILE_LOADED:-}" ]; then
        if zmodload zsh/mapfile 2>/dev/null; then
            export ZSH_MAPFILE_LOADED=1
        fi
    fi
    
    return 0
}

# Auto-load zsh modules when running under zsh
if is_zsh; then
    load_zsh_modules
fi

