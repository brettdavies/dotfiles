#!/usr/bin/env bash
# Temporary directory management
# Provides functions for creating and managing a single temporary directory per script execution
# Requires: util/output.sh (for err), core/constants.sh (for PERM_SECRET_DIR, PERM_SECRET_FILE), fs/file-ops.sh (for safe_chmod, safe_rm)

# Prevent re-sourcing
if [ -n "${LIB_TEMP_LOADED:-}" ]; then
    return 0
fi
export LIB_TEMP_LOADED=1

# Source dependencies if not already sourced
if ! command -v err &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/output.sh" 2>/dev/null || true
fi

# Source constants if not already sourced
if [ -z "${PERM_SECRET_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# Global temporary directory for this script execution
SCRIPT_TEMP_DIR=""

# Initialize temporary directory for script execution
# 
# Purpose: Creates a single temporary directory that will be cleaned up on exit
# 
# Parameters:
#   $1 - Template for temporary directory name (optional, default: "dotfiles.XXXXXX")
#        Must contain at least 6 X's for mktemp
# 
# Returns: Path to temporary directory via echo (stdout)
# 
# Side effects:
#   - Creates a temporary directory in the system temp location
#   - Sets secure permissions (700) on the directory
#   - Registers cleanup trap on EXIT
#   - Sets global SCRIPT_TEMP_DIR variable
# 
# Example:
#   TEMP_DIR=$(init_temp_dir "my-script.XXXXXX")
#   echo "Temp dir: $TEMP_DIR"
init_temp_dir() {
    local template="${1:-dotfiles.XXXXXX}"
    
    # If already initialized and directory exists, return existing directory
    if [ -n "${SCRIPT_TEMP_DIR:-}" ] && [ -d "$SCRIPT_TEMP_DIR" ]; then
        echo -n "$SCRIPT_TEMP_DIR"
        return 0
    fi
    
    # Clear SCRIPT_TEMP_DIR if it's set but directory doesn't exist
    if [ -n "${SCRIPT_TEMP_DIR:-}" ] && [ ! -d "$SCRIPT_TEMP_DIR" ]; then
        SCRIPT_TEMP_DIR=""
    fi
    
    # Create temp directory in system temp directory
    if ! SCRIPT_TEMP_DIR=$(mktemp -d -t "$template" 2>/dev/null); then
        # Fallback if mktemp -t fails (some systems)
        SCRIPT_TEMP_DIR=$(mktemp -d "/tmp/$template" 2>/dev/null)
    fi
    
    if [ -z "$SCRIPT_TEMP_DIR" ] || [ ! -d "$SCRIPT_TEMP_DIR" ]; then
        err "Failed to create temporary directory" 1 >&2
        return 1
    fi
    
    # Set secure permissions (use safe_chmod if available, otherwise fallback to chmod)
    if command -v safe_chmod &> /dev/null; then
        safe_chmod "$PERM_SECRET_DIR" "$SCRIPT_TEMP_DIR" 2>/dev/null || true
    else
        chmod "$PERM_SECRET_DIR" "$SCRIPT_TEMP_DIR" 2>/dev/null || true
    fi
    
    # Register cleanup on exit
    trap "cleanup_temp_dir" EXIT
    
    echo -n "$SCRIPT_TEMP_DIR"
}

# Get the current script temporary directory
# 
# Purpose: Returns the current temporary directory, creating it if it doesn't exist
# 
# Parameters: None
# 
# Returns: Path to temporary directory via echo (stdout)
# 
# Side effects: May call init_temp_dir() if directory doesn't exist
# 
# Example:
#   TEMP_DIR=$(get_temp_dir)
#   echo "Using temp dir: $TEMP_DIR"
get_temp_dir() {
    # If SCRIPT_TEMP_DIR is set and directory exists, return it
    if [ -n "${SCRIPT_TEMP_DIR:-}" ] && [ -d "$SCRIPT_TEMP_DIR" ]; then
        echo -n "$SCRIPT_TEMP_DIR"
        return 0
    fi
    
    # Otherwise, initialize a new temp directory
    init_temp_dir
}

# Create a temporary file in the script's temporary directory
# 
# Purpose: Creates a temporary file with secure permissions in the script's temp directory
# 
# Parameters:
#   $1 - Filename template (optional, default: "temp.XXXXXX")
#        Must contain at least 6 X's for mktemp
# 
# Returns: Path to temporary file via echo (stdout)
# 
# Side effects:
#   - Creates a temporary file in SCRIPT_TEMP_DIR
#   - Sets secure permissions (600) on the file
#   - File will be cleaned up when cleanup_temp_dir() is called
# 
# Example:
#   TEMP_FILE=$(create_temp_file "merge-base.XXXXXX")
#   echo "data" > "$TEMP_FILE"
create_temp_file() {
    local template="${1:-temp.XXXXXX}"
    local temp_dir
    temp_dir=$(get_temp_dir) || return 1
    
    local temp_file
    temp_file=$(mktemp "$temp_dir/$template" 2>/dev/null)
    
    if [ -z "$temp_file" ] || [ ! -f "$temp_file" ]; then
        err "Failed to create temporary file in $temp_dir" 1
        return 1
    fi
    
    # Set secure permissions (use safe_chmod if available, otherwise fallback to chmod)
    if command -v safe_chmod &> /dev/null; then
        safe_chmod "$PERM_SECRET_FILE" "$temp_file" 2>/dev/null || true
    else
        chmod "$PERM_SECRET_FILE" "$temp_file" 2>/dev/null || true
    fi
    
    echo -n "$temp_file"
}

# Create a temporary subdirectory in the script's temporary directory
# 
# Purpose: Creates a temporary subdirectory with secure permissions in the script's temp directory
# 
# Parameters:
#   $1 - Directory name template (optional, default: "subdir.XXXXXX")
#        Must contain at least 6 X's for mktemp
# 
# Returns: Path to temporary subdirectory via echo (stdout)
# 
# Side effects:
#   - Creates a temporary subdirectory in SCRIPT_TEMP_DIR
#   - Sets secure permissions (700) on the directory
#   - Directory will be cleaned up when cleanup_temp_dir() is called
# 
# Example:
#   TEMP_SUBDIR=$(create_temp_subdir "backups.XXXXXX")
#   cp file.txt "$TEMP_SUBDIR/"
create_temp_subdir() {
    local template="${1:-subdir.XXXXXX}"
    local temp_dir
    temp_dir=$(get_temp_dir) || return 1
    
    local temp_subdir
    temp_subdir=$(mktemp -d "$temp_dir/$template" 2>/dev/null)
    
    if [ -z "$temp_subdir" ] || [ ! -d "$temp_subdir" ]; then
        err "Failed to create temporary subdirectory in $temp_dir" 1
        return 1
    fi
    
    # Set secure permissions (use safe_chmod if available, otherwise fallback to chmod)
    if command -v safe_chmod &> /dev/null; then
        safe_chmod "$PERM_SECRET_DIR" "$temp_subdir" 2>/dev/null || true
    else
        chmod "$PERM_SECRET_DIR" "$temp_subdir" 2>/dev/null || true
    fi
    
    echo -n "$temp_subdir"
}

# Cleanup the script's temporary directory
# 
# Purpose: Removes the script's temporary directory and all its contents
# 
# Parameters: None
# 
# Returns: Nothing
# 
# Side effects:
#   - Removes SCRIPT_TEMP_DIR and all its contents
#   - Clears the SCRIPT_TEMP_DIR global variable
#   - Safe to call multiple times (idempotent)
# 
# Note: This is automatically called on exit via trap handler
# 
# Example:
#   cleanup_temp_dir  # Manual cleanup (usually not needed)
cleanup_temp_dir() {
    if [ -n "$SCRIPT_TEMP_DIR" ] && [ -d "$SCRIPT_TEMP_DIR" ]; then
        # Use safe_rm if available, otherwise fallback to rm
        if command -v safe_rm &> /dev/null; then
            safe_rm "$SCRIPT_TEMP_DIR" "-rf" 2>/dev/null || true
        else
            rm -rf "$SCRIPT_TEMP_DIR" 2>/dev/null || true
        fi
        SCRIPT_TEMP_DIR=""
    fi
}

