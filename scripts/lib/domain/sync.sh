#!/usr/bin/env bash
# Basic sync operations
# Provides functions for file comparison and diff operations
# Requires: util/paths.sh (for DOTFILES_DIR), util/output.sh (for err, warn), core/constants.sh (for colors)

# Prevent re-sourcing
if [ -n "${LIB_SYNC_LOADED:-}" ]; then
    return 0
fi
export LIB_SYNC_LOADED=1

# Source dependencies if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# Source constants if not already sourced
if [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# ============================================================================
# File Comparison and Diff Operations
# ============================================================================

# Detect if a file is binary
# Usage: is_binary_file <file_path>
# Returns: 0 if binary, 1 if text
is_binary_file() {
    local file="$1"
    
    # Check if file exists
    [ -f "$file" ] || return 1
    
    # Use file command if available
    if command -v file &> /dev/null; then
        local file_type
        file_type=$(file -b --mime-type "$file" 2>/dev/null || echo "")
        if [[ "$file_type" =~ ^(image|video|audio|application)/ ]] || [[ "$file_type" == "application/octet-stream" ]]; then
            return 0
        fi
        # Check for text types explicitly
        if [[ "$file_type" =~ ^text/ ]] || [[ "$file_type" == "application/json" ]] || [[ "$file_type" == "application/xml" ]]; then
            return 1
        fi
    fi
    
    # Fallback: check common binary extensions
    local ext="${file##*.}"
    case "$ext" in
        png|jpg|jpeg|gif|bmp|ico|svg|webp|pdf|zip|tar|gz|bz2|xz|exe|dll|so|dylib|bin|o|a|pyc|pyo|class|jar|war|ear|deb|rpm|dmg|pkg|app|ipa|apk)
            return 0
            ;;
    esac
    
    # Default to text file
    return 1
}

# Compare two files
# Usage: compare_files <file1> <file2>
# Returns: 0 if identical, 1 if different
compare_files() {
    local file1="$1"
    local file2="$2"
    
    # Both files must exist
    [ -f "$file1" ] && [ -f "$file2" ] || return 1
    
    # Use cmp for binary-safe comparison
    cmp -s "$file1" "$file2" 2>/dev/null
}

# Show diff between two files in git unified diff format
# Usage: show_file_diff <file1> <file2> [label1] [label2]
# Shows diff in git unified format (like git diff)
show_file_diff() {
    local file1="$1"
    local file2="$2"
    local label1="${3:-a/$file1}"
    local label2="${4:-b/$file2}"
    
    # Use git diff if available (produces better output)
    if command -v git &> /dev/null; then
        git diff --no-index --no-color -- "$file1" "$file2" 2>/dev/null | sed "1s|^---.*|--- $label1|; 2s|^+++.*|+++ $label2|" || true
    else
        # Fallback to diff -u
        diff -u --label "$label1" --label "$label2" "$file1" "$file2" 2>/dev/null || true
    fi
}

