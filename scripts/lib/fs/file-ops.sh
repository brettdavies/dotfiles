#!/usr/bin/env bash
# File operations
# Provides functions for file operations, permissions, and stat information
# Requires: util/paths.sh (for OS variable), core/detect-os.sh (for is_zsh), shell/zsh-modules.sh (for ZSH_STAT_LOADED, ZSH_FILES_LOADED), core/constants.sh (for PERM_SECRET_FILE, PERM_SECRET_DIR)

# Prevent re-sourcing
if [ -n "${LIB_FILE_OPS_LOADED:-}" ]; then
    return 0
fi
export LIB_FILE_OPS_LOADED=1

# Source dependencies if not already sourced
if [ -z "${OS:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# Source constants if not already sourced
if [ -z "${PERM_SECRET_FILE:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# ============================================================================
# File Stat Operations
# ============================================================================

# Get file permissions in a cross-platform way
# 
# Purpose: Retrieves file permissions as an octal string, working on both macOS and Linux
#   Uses zsh built-in zstat when available for better performance
# 
# Parameters:
#   $1 - File path (required)
# 
# Returns: Permissions as octal string (e.g., "600", "755") via echo
# 
# Side effects: None
# 
# Example:
#   PERMS=$(get_file_permissions ~/.secrets)
#   if [ "$PERMS" = "600" ]; then
#       echo "Permissions are correct"
#   fi
# 
# Note: Uses zstat (zsh) when available, otherwise stat -f on macOS and stat -c on Linux
get_file_permissions() {
    local file="$1"
    
    # Use zsh built-in zstat if available
    if is_zsh && [ -n "${ZSH_STAT_LOADED:-}" ]; then
        zstat -A perms +mode "$file" 2>/dev/null || return 1
        # Convert to octal (remove leading 0 if present, zstat returns decimal)
        printf "%o\n" "$perms" 2>/dev/null || return 1
        return 0
    fi
    
    # Fallback to external stat command
    stat -f "%OLp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null
}

# Get file stat information using zsh built-in or external stat
# 
# Purpose: Retrieves file stat information, using zsh built-in when available
# 
# Parameters:
#   $1 - File path (required)
#   $2 - Stat field to retrieve (e.g., "size", "mtime", "mode")
# 
# Returns: Stat field value via echo
# 
# Side effects: None
# 
# Example:
#   size=$(get_file_stat ~/.zshrc "size")
#   mtime=$(get_file_stat ~/.zshrc "mtime")
# 
# Note: Uses zstat (zsh) when available, otherwise external stat command
get_file_stat() {
    local file="$1"
    local field="${2:-size}"
    
    # Use zsh built-in zstat if available
    if is_zsh && [ -n "${ZSH_STAT_LOADED:-}" ]; then
        case "$field" in
            size)
                zstat -A size +size "$file" 2>/dev/null && echo -n "$size" || return 1
                ;;
            mtime|modtime)
                zstat -A mtime +mtime "$file" 2>/dev/null && echo -n "$mtime" || return 1
                ;;
            mode|perms|permissions)
                zstat -A mode +mode "$file" 2>/dev/null && printf "%o\n" "$mode" 2>/dev/null || return 1
                ;;
            *)
                # Try to get the field directly
                zstat -A value "+$field" "$file" 2>/dev/null && echo -n "$value" || return 1
                ;;
        esac
        return 0
    fi
    
    # Fallback to external stat command
    if [[ "${OS:-}" == "macos" ]]; then
        case "$field" in
            size)
                stat -f "%z" "$file" 2>/dev/null || return 1
                ;;
            mtime|modtime)
                stat -f "%m" "$file" 2>/dev/null || return 1
                ;;
            mode|perms|permissions)
                stat -f "%OLp" "$file" 2>/dev/null || return 1
                ;;
            *)
                # Try generic stat format
                stat -f "%$field" "$file" 2>/dev/null || return 1
                ;;
        esac
    else
        # Linux
        case "$field" in
            size)
                stat -c "%s" "$file" 2>/dev/null || return 1
                ;;
            mtime|modtime)
                stat -c "%Y" "$file" 2>/dev/null || return 1
                ;;
            mode|perms|permissions)
                stat -c "%a" "$file" 2>/dev/null || return 1
                ;;
            *)
                # Try generic stat format
                stat -c "%$field" "$file" 2>/dev/null || return 1
                ;;
        esac
    fi
}

# ============================================================================
# Zsh Built-in File Operations (when available)
# ============================================================================

# Create directory using zsh built-in or external mkdir
# 
# Purpose: Creates a directory, using zsh built-in zf_mkdir when available
# 
# Parameters:
#   $1 - Directory path (required)
#   $2 - Options (e.g., "-p" for parent directories)
# 
# Returns: 0 on success, 1 on failure
# 
# Side effects: Creates directory
# 
# Example:
#   safe_mkdir "$dir" "-p"
# 
# Note: Uses zf_mkdir (zsh) when available, otherwise external mkdir
safe_mkdir() {
    local dir="$1"
    local opts="${2:-}"
    
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ] && command -v zf_mkdir &> /dev/null; then
        # Use zsh built-in mkdir
        if [[ "$opts" == *"-p"* ]]; then
            zf_mkdir -p "$dir" 2>/dev/null || return 1
        else
            zf_mkdir "$dir" 2>/dev/null || return 1
        fi
        return 0
    fi
    
    # Fallback to external mkdir
    mkdir $opts "$dir" 2>/dev/null || return 1
}

# Create symlink using zsh built-in or external ln
# 
# Purpose: Creates a symlink, using zsh built-in zf_ln when available
# 
# Parameters:
#   $1 - Options (e.g., "-s" for symlink, "-f" for force)
#   $2 - Target path (required)
#   $3 - Link path (required)
# 
# Returns: 0 on success, 1 on failure
# 
# Side effects: Creates symlink
# 
# Example:
#   safe_ln -s "$target" "$link"
# 
# Note: Uses zf_ln (zsh) when available, otherwise external ln
safe_ln() {
    local opts="$1"
    local target="$2"
    local link="$3"
    
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ] && command -v zf_ln &> /dev/null; then
        # Use zsh built-in ln
        zf_ln $opts "$target" "$link" 2>/dev/null || return 1
        return 0
    fi
    
    # Fallback to external ln
    ln $opts "$target" "$link" 2>/dev/null || return 1
}

# Remove file using zsh built-in or external rm
# 
# Purpose: Removes a file, using zsh built-in zf_rm when available
# 
# Parameters:
#   $1 - File path (required)
#   $2 - Options (e.g., "-f" for force, "-r" for recursive)
# 
# Returns: 0 on success, 1 on failure
# 
# Side effects: Removes file
# 
# Example:
#   safe_rm "$file" "-f"
# 
# Note: Uses zf_rm (zsh) when available, otherwise external rm
safe_rm() {
    local file="$1"
    local opts="${2:-}"
    
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ] && command -v zf_rm &> /dev/null; then
        # Use zsh built-in rm
        zf_rm $opts "$file" 2>/dev/null || return 1
        return 0
    fi
    
    # Fallback to external rm
    rm $opts "$file" 2>/dev/null || return 1
}

# Change file permissions using zsh built-in or external chmod
# 
# Purpose: Changes file permissions, using zsh built-in zf_chmod when available
# 
# Parameters:
#   $1 - Permissions (e.g., "600", "755") (required)
#   $2 - File path (required)
# 
# Returns: 0 on success, 1 on failure
# 
# Side effects: Changes file permissions
# 
# Example:
#   safe_chmod "600" ~/.secrets
# 
# Note: Uses zf_chmod (zsh) when available, otherwise external chmod
safe_chmod() {
    local perms="$1"
    local file="$2"
    
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ] && command -v zf_chmod &> /dev/null; then
        # Use zsh built-in chmod
        zf_chmod "$perms" "$file" 2>/dev/null || return 1
        return 0
    fi
    
    # Fallback to external chmod
    chmod "$perms" "$file" 2>/dev/null || return 1
}

