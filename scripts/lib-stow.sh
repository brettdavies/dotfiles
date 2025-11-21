#!/bin/bash
# Stow and symlink helper functions
# Provides functions for checking symlinks and transforming dotfiles paths
# Requires: lib-core.sh (for DOTFILES_DIR, STOW_DIR variables)

# Source core library if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    source "$(dirname "$0")/lib-core.sh"
fi

# Check if a directory is a symlink pointing to the expected location
# Usage: check_dir_symlink <target_dir> <expected_source>
# Returns: 0 if correctly symlinked, 1 otherwise
check_dir_symlink() {
    local target_dir="$1"
    local expected_source="$2"
    
    if [ -L "$target_dir" ]; then
        local actual_source=$(readlink "$target_dir")
        # Resolve relative symlinks
        if [[ "$actual_source" != /* ]]; then
            local base_dir
            base_dir="$(cd "$(dirname "$target_dir")" && pwd)" || return 1
            actual_source="$base_dir/$actual_source"
        fi
        # Normalize paths
        local actual_dir expected_dir
        actual_dir="$(cd "$(dirname "$actual_source")" && pwd)" || return 1
        expected_dir="$(cd "$(dirname "$expected_source")" && pwd)" || return 1
        actual_source="$actual_dir/$(basename "$actual_source")"
        expected_source="$expected_dir/$(basename "$expected_source")"
        
        if [ "$actual_source" == "$expected_source" ]; then
            return 0  # Directory is correctly symlinked
        else
            return 1  # Directory symlink points to wrong location
        fi
    fi
    return 1  # Not a symlink
}

# Check if any parent directory of a target file is symlinked to the stow directory
# This handles the case where entire directories are symlinked (e.g., ~/.config/git -> stow/git/dot-config/git)
# Usage: is_parent_dir_symlinked <target_file> <package_name>
# Returns: 0 if parent is symlinked, 1 otherwise
# Sets global variable PARENT_SYMLINKED_DIR if found
is_parent_dir_symlinked() {
    local target_file="$1"
    local package="$2"
    local target_dir=$(dirname "$target_file")
    
    PARENT_SYMLINKED_DIR=""
    
    # Walk up the directory tree from target to HOME
    local check_dir="$target_dir"
    while [[ "$check_dir" != "$HOME" ]] && [[ "$check_dir" != "/" ]]; do
        # Check if this directory should be symlinked (exists in stow package)
        local dir_rel_path="${check_dir#$HOME/}"
        local dir_in_stow=$(echo "$dir_rel_path" | sed 's|\.|dot-|g')
        local expected_stow_dir="$STOW_DIR/$package/$dir_in_stow"
        
        # Check if directory exists in stow and if target is symlinked to it
        if [ -d "$expected_stow_dir" ]; then
            if check_dir_symlink "$check_dir" "$expected_stow_dir"; then
                PARENT_SYMLINKED_DIR="$check_dir"
                return 0  # Found a parent directory that's correctly symlinked
            fi
        fi
        
        check_dir=$(dirname "$check_dir")
    done
    
    return 1  # No parent directory is symlinked
}

# Transform dotfiles path (dot-* -> .*)
# Usage: transform_dotfiles_path <relative_path>
# Returns: transformed path via echo
transform_dotfiles_path() {
    local rel_path="$1"
    echo "$rel_path" | sed 's|dot-|.|g'
}

# Normalize a path (resolve symlinks and make absolute)
# Usage: normalize_path <path>
# Returns: normalized absolute path via echo
normalize_path() {
    local path="$1"
    local base_dir
    local normalized
    
    # If it's a relative path, resolve it
    if [[ "$path" != /* ]]; then
        base_dir="$(cd "$(dirname "$path")" && pwd)" || return 1
        path="$base_dir/$(basename "$path")"
    fi
    
    # Normalize the path
    normalized="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")" || return 1
    echo "$normalized"
}

