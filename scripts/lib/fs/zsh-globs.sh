#!/usr/bin/env bash
# Zsh glob operations
# Provides zsh-specific glob-based file finding functions
# Requires: core/detect-os.sh (for is_zsh), shell/zsh-modules.sh (for ZSH_FILES_LOADED)

# Prevent re-sourcing
if [ -n "${LIB_ZSH_GLOBS_LOADED:-}" ]; then
    return 0
fi
export LIB_ZSH_GLOBS_LOADED=1

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# ============================================================================
# Zsh Glob Operations
# ============================================================================

# Find files using zsh glob qualifiers (zsh only)
# 
# Purpose: Uses zsh glob qualifiers for fast file finding
#   This is significantly faster than find for large directory trees
# 
# Parameters:
#   $1 - Directory to search
#   $2 - File type: "f" for files, "d" for directories, "a" for all, or find-style options
#   $3 - Pattern (optional, e.g., "*.sh")
# 
# Returns: Array of file paths via global variable FIND_RESULTS
# 
# Side effects: Sets FIND_RESULTS array
# 
# Example:
#   find_files_zsh_glob "$dir" "f" "*.sh"
#   echo "${FIND_RESULTS[@]}"
# 
# Note: Only works under zsh. Falls back to find for bash.
#   Glob qualifiers used:
#     (.) = regular files
#     (/) = directories
#     (@) = symlinks
#     (N) = null glob (don't error if no matches)
#     (Om) = sort by modification time (newest first)
#     (On) = sort by name
find_files_zsh_glob() {
    local dir="$1"
    local file_type="${2:-f}"  # f=files, d=directories, a=all
    local pattern="${3:-}"
    
    if ! is_zsh; then
        # Not zsh, return empty (caller should use find fallback)
        FIND_RESULTS=()
        return 1
    fi
    
    # Directory doesn't exist
    if [ ! -d "$dir" ]; then
        FIND_RESULTS=()
        return 0
    fi
    
    # Enable extended_glob locally for this function
    local old_extended_glob
    if [[ -o extended_glob ]]; then
        old_extended_glob=1
    else
        setopt extended_glob
        old_extended_glob=0
    fi
    
    # Build glob pattern
    local glob_pattern
    if [ -n "$pattern" ]; then
        glob_pattern="${dir}/**/${pattern}"
    else
        glob_pattern="${dir}/**/*"
    fi
    
    # Add qualifiers based on file type
    case "$file_type" in
        f|file)
            # Regular files only
            glob_pattern="${glob_pattern}(.)"
            ;;
        d|dir|directory)
            # Directories only
            glob_pattern="${glob_pattern}(/)"
            ;;
        a|all)
            # All files and directories (no qualifier)
            ;;
        *)
            # Try to parse find-style options (basic support)
            if [[ "$file_type" == *"-type f"* ]]; then
                glob_pattern="${glob_pattern}(.)"
            elif [[ "$file_type" == *"-type d"* ]]; then
                glob_pattern="${glob_pattern}(/)"
            fi
            ;;
    esac
    
    # Add null glob qualifier to avoid errors if no matches
    glob_pattern="${glob_pattern}(N)"
    
    # Execute glob and store results
    FIND_RESULTS=($~glob_pattern)
    
    # Restore extended_glob setting
    if [ "$old_extended_glob" -eq 0 ]; then
        unsetopt extended_glob
    fi
    
    return 0
}

# Get directory listing using zsh globs (zsh only)
# 
# Purpose: Uses zsh glob qualifiers for fast directory listing
# 
# Parameters:
#   $1 - Directory to list
#   $2 - File type: "f" for files, "d" for directories, "a" for all
# 
# Returns: Array of paths via global variable DIR_LISTING
# 
# Side effects: Sets DIR_LISTING array
# 
# Example:
#   get_dir_listing_zsh "$dir" "f"
#   echo "${DIR_LISTING[@]}"
# 
# Note: Only works under zsh. Falls back to get_dir_listing() for bash.
get_dir_listing_zsh() {
    local dir="$1"
    local file_type="${2:-a}"
    
    if ! is_zsh; then
        DIR_LISTING=()
        return 1
    fi
    
    # Enable extended_glob locally
    local old_extended_glob
    if [[ -o extended_glob ]]; then
        old_extended_glob=1
    else
        setopt extended_glob
        old_extended_glob=0
    fi
    
    # Build glob pattern based on file type
    local glob_pattern
    case "$file_type" in
        f|file)
            glob_pattern="${dir}/*(.)"  # Regular files only
            ;;
        d|dir|directory)
            glob_pattern="${dir}/*(/)"  # Directories only
            ;;
        a|all)
            glob_pattern="${dir}/*"     # All
            ;;
        *)
            DIR_LISTING=()
            if [ "$old_extended_glob" -eq 0 ]; then
                unsetopt extended_glob
            fi
            return 1
            ;;
    esac
    
    # Add null glob to avoid errors
    glob_pattern="${glob_pattern}(N)"
    
    # Execute glob
    DIR_LISTING=($~glob_pattern)
    
    # Restore extended_glob setting
    if [ "$old_extended_glob" -eq 0 ]; then
        unsetopt extended_glob
    fi
    
    return 0
}

