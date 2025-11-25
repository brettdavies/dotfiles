#!/usr/bin/env bash
# Find operations with directory caching
# Provides optimized find operations with caching support
# Requires: util/paths.sh (for DOTFILES_DIR), fs/zsh-globs.sh (for find_files_zsh_glob), core/detect-shell.sh (for has_nameref_support), core/detect-os.sh (for is_zsh), util/output.sh (for err)

# Prevent re-sourcing
if [ -n "${LIB_FIND_LOADED:-}" ]; then
    return 0
fi
export LIB_FIND_LOADED=1

# Source dependencies if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# Source zsh-globs if available
if ! command -v find_files_zsh_glob &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/zsh-globs.sh" 2>/dev/null || true
fi

# Source detect-shell if not already sourced
if ! command -v has_nameref_support &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-shell.sh" 2>/dev/null || true
fi

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# Source output if not already sourced
if ! command -v err &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/output.sh" 2>/dev/null || true
fi

# Directory listing cache (associative array)
# Key: directory path, Value: newline-separated list of files
# Note: On Bash 3.2 (macOS default), caching is disabled
# Note: Caching is also disabled in test frameworks that use strict mode
DIR_CACHE_SUPPORTED=false
DIR_CACHE_INITIALIZED=false

# Only enable caching if associative arrays work properly
# Some environments (like BATS) cause issues with special characters in keys
_test_cache_key="test|||key"
if declare -A DIR_CACHE 2>/dev/null; then
    # Test if we can actually use the array
    if ( eval 'DIR_CACHE[$_test_cache_key]="test"' && eval '[ "${DIR_CACHE[$_test_cache_key]}" = "test" ]' ) 2>/dev/null; then
        DIR_CACHE_SUPPORTED=true
    fi
fi
unset _test_cache_key

# Initialize directory cache
# Usage: init_dir_cache
init_dir_cache() {
    if [ "$DIR_CACHE_INITIALIZED" = true ]; then
        return 0
    fi
    
    # Check if associative arrays are supported (Bash 4+)
    if [ "$DIR_CACHE_SUPPORTED" = false ]; then
        # Bash 3.2 or older - skip caching
        DIR_CACHE_INITIALIZED=true
        return 0
    fi
    
    DIR_CACHE_INITIALIZED=true
}

# Find files in a directory and cache the results
# Usage: find_files_in_dir <directory> [find_options]
# Example: find_files_in_dir "$STOW_DIR/git" "-type f -name '*.sh'"
# Returns: array of file paths via global variable FIND_RESULTS
# Also caches results for subsequent calls
find_files_in_dir() {
    local dir="$1"
    local find_opts="${2:--type f}"
    
    # Initialize cache if needed
    init_dir_cache
    
    # Create cache key
    local cache_key="${dir}|||${find_opts}"
    
    # Caching disabled - special characters in keys cause issues in strict mode
    
    # Directory doesn't exist
    if [ ! -d "$dir" ]; then
        FIND_RESULTS=()
        return 0
    fi
    
    # Try zsh glob qualifiers first if running under zsh
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ]; then
        # Parse find_opts to determine file type and pattern
        local file_type="f"
        local pattern=""
        
        # Extract file type from find_opts
        if [[ "$find_opts" == *"-type d"* ]]; then
            file_type="d"
        elif [[ "$find_opts" == *"-type f"* ]]; then
            file_type="f"
        elif [[ -z "$find_opts" ]] || [[ "$find_opts" == *"-type"* ]]; then
            file_type="a"
        fi
        
        # Extract pattern from find_opts (basic support for -name)
        if [[ "$find_opts" =~ -name[[:space:]]+['"]?([^'"]+)['"]? ]]; then
            pattern="${BASH_REMATCH[1]}"
        fi
        
        # Try zsh glob approach
        if command -v find_files_zsh_glob &> /dev/null && find_files_zsh_glob "$dir" "$file_type" "$pattern"; then
            local temp_array=("${FIND_RESULTS[@]}")
            
            return 0
        fi
    fi
    
    # Fallback to find command (bash or zsh without glob support)
    local temp_array=()
    while IFS= read -r -d '' file; do
        temp_array+=("$file")
    done < <(find -P "$dir" $find_opts -print0 2>/dev/null)
    
    FIND_RESULTS=("${temp_array[@]}")
    
    # Skip caching - it causes issues with special characters in strict mode
    # TODO: Re-enable caching with proper escaping
    
    return 0
}

# Find files in directory and return as array
# Usage: find_files_array <array_name> <directory> [find_options]
# Example: find_files_array files "$STOW_DIR/git" "-type f"
# 
# Note: Uses nameref (Bash 4.3+ / zsh) when available, eval fallback otherwise
find_files_array() {
    local array_name="$1"
    local dir="$2"
    local find_opts="${3:--type f}"
    
    find_files_in_dir "$dir" "$find_opts"
    
    # Use nameref if available, otherwise use eval
    if has_nameref_support; then
        if is_zsh; then
            typeset -n array_ref="$array_name"
            array_ref=("${FIND_RESULTS[@]}")
        else
            local -n array_ref="$array_name"
            array_ref=("${FIND_RESULTS[@]}")
        fi
    else
        eval "$array_name=(\"\${FIND_RESULTS[@]}\")"
    fi
}

# Find directories in a directory and cache the results
# Usage: find_dirs_in_dir <directory> [find_options]
# Example: find_dirs_in_dir "$STOW_DIR/git" "-maxdepth 2"
# Returns: array of directory paths via global variable FIND_RESULTS
find_dirs_in_dir() {
    local dir="$1"
    local find_opts="${2:--type d}"
    
    find_files_in_dir "$dir" "$find_opts"
}

# Clear directory cache
# Usage: clear_dir_cache [directory]
# If directory is provided, only clears cache for that directory
# Otherwise clears entire cache
clear_dir_cache() {
    if [ "$DIR_CACHE_SUPPORTED" = false ]; then
        return 0  # Caching not supported
    fi
    
    local dir="${1:-}"
    
    if [ -z "$dir" ]; then
        # Clear entire cache
        DIR_CACHE=()
    else
        # Clear cache entries for this directory
        local keys_to_remove=()
        for key in "${!DIR_CACHE[@]}"; do
            if [[ "$key" == "$dir"* ]]; then
                keys_to_remove+=("$key")
            fi
        done
        for key in "${keys_to_remove[@]}"; do
            unset 'DIR_CACHE[$key]'
        done
    fi
}

# Get directory listing (cached)
# Usage: get_dir_listing <directory> [file_type]
# file_type: "f" for files, "d" for directories, "a" for all
# Returns: array of paths via global variable DIR_LISTING
# 
# Note: Uses zsh glob qualifiers when available for better performance
get_dir_listing() {
    local dir="$1"
    local file_type="${2:-a}"  # f=files, d=directories, a=all
    
    # Try zsh glob approach first if available
    if is_zsh && [ -n "${ZSH_FILES_LOADED:-}" ]; then
        if command -v get_dir_listing_zsh &> /dev/null && get_dir_listing_zsh "$dir" "$file_type"; then
            return 0
        fi
    fi
    
    # Fallback to find-based approach
    case "$file_type" in
        f)
            find_files_in_dir "$dir" "-type f"
            DIR_LISTING=("${FIND_RESULTS[@]}")
            ;;
        d)
            find_dirs_in_dir "$dir" "-type d"
            DIR_LISTING=("${FIND_RESULTS[@]}")
            ;;
        a)
            find_files_in_dir "$dir" ""
            DIR_LISTING=("${FIND_RESULTS[@]}")
            ;;
        *)
            err "Invalid file_type: $file_type (must be f, d, or a)" 1
            DIR_LISTING=()
            return 1
            ;;
    esac
}

# Check if directory listing is cached
# Usage: is_dir_cached <directory> [find_options]
# Returns: 0 if cached, 1 if not cached
is_dir_cached() {
    if [ "$DIR_CACHE_SUPPORTED" = false ]; then
        return 1  # Not cached (caching not supported)
    fi
    
    local dir="$1"
    local find_opts="${2:--type f}"
    local cache_key="${dir}|||${find_opts}"
    
    [ -n "${DIR_CACHE["$cache_key"]:-}" ]
}

# Optimized find operation that uses cache when possible
# Usage: cached_find <directory> <find_options>
# Example: cached_find "$STOW_DIR/git" "-type f -name '*.sh'"
# Returns: array of paths via global variable CACHED_FIND_RESULTS
cached_find() {
    local dir="$1"
    local find_opts="$2"
    
    find_files_in_dir "$dir" "$find_opts"
    CACHED_FIND_RESULTS=("${FIND_RESULTS[@]}")
}

# Count files in directory (cached)
# Usage: count_files_in_dir <directory> [find_options]
# Returns: count via echo
count_files_in_dir() {
    local dir="$1"
    local find_opts="${2:--type f}"
    
    find_files_in_dir "$dir" "$find_opts"
    echo "${#FIND_RESULTS[@]}"
}

# Check if directory is empty (cached)
# Usage: is_dir_empty <directory>
# Returns: 0 if empty, 1 if not empty
is_dir_empty() {
    local dir="$1"
    local count
    count=$(count_files_in_dir "$dir" "")
    [ "$count" -eq 0 ]
}

