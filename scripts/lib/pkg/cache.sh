#!/usr/bin/env bash
# Package status caching infrastructure
# Provides associative array caching for package status
# Requires: core/detect-os.sh (for is_zsh), feature/logging.sh (for log_debug), shell/arrays.sh (for readarray)

# Prevent re-sourcing
if [ -n "${LIB_PKG_CACHE_LOADED:-}" ]; then
    return 0
fi
export LIB_PKG_CACHE_LOADED=1

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# Source logging if available (for log_debug)
if ! command -v log_debug &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../feature/logging.sh" 2>/dev/null || true
fi

# ============================================================================
# Package status caching (associative arrays)
# ============================================================================

# Cache initialization flag
PACKAGE_CACHE_INITIALIZED=false

# Associative arrays for caching (Bash 4+ or zsh)
# For Bash 3.2 compatibility, we'll check and use alternative approach if needed
# Use zsh-specific typeset -A if running under zsh for better performance
if command -v is_zsh >/dev/null 2>&1 && is_zsh; then
    # Zsh uses typeset -A for associative arrays
    typeset -A TAP_CACHE
    typeset -A PACKAGE_CACHE
    typeset -A CASK_CACHE
    typeset -A VSCODE_EXT_CACHE
    typeset -A CURSOR_EXT_CACHE
elif declare -A PACKAGE_CACHE 2>/dev/null; then
    # Bash 4+ uses declare -A
    declare -A TAP_CACHE 2>/dev/null || true
    declare -A CASK_CACHE 2>/dev/null || true
    declare -A VSCODE_EXT_CACHE 2>/dev/null || true
    declare -A CURSOR_EXT_CACHE 2>/dev/null || true
else
    # Bash 3.2 or earlier - associative arrays not supported
    # Cache will be disabled
    PACKAGE_CACHE_INITIALIZED=false
fi

# Check if associative arrays are supported
# Uses zsh typeset -A or Bash declare -A
check_assoc_array_support() {
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh always supports associative arrays
        return 0
    fi
    # Test if declare -A works (Bash 4+)
    local test_array
    if declare -A test_array 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Initialize package status cache
# Usage: init_package_cache
# Populates cache with current package status
init_package_cache() {
    if [ "$PACKAGE_CACHE_INITIALIZED" = true ]; then
        return 0  # Already initialized
    fi
    
    if ! check_assoc_array_support; then
        if command -v log_debug &> /dev/null; then
            log_debug "Associative arrays not supported, skipping cache initialization"
        fi
        PACKAGE_CACHE_INITIALIZED=false
        return 0
    fi
    
    if command -v log_debug &> /dev/null; then
        log_debug "Initializing package status cache..."
    fi
    
    # Only initialize if brew is available
    if ! command -v brew &> /dev/null; then
        if command -v log_debug &> /dev/null; then
            log_debug "Homebrew not found, skipping cache initialization"
        fi
        PACKAGE_CACHE_INITIALIZED=true
        return 0
    fi
    
    # Cache all installed packages
    local packages_array
    if command -v readarray &> /dev/null; then
        readarray -t packages_array < <(brew list --formula 2>/dev/null || echo "")
    else
        # Fallback for systems without readarray
        packages_array=()
        while IFS= read -r line; do
            [ -n "$line" ] && packages_array+=("$line")
        done < <(brew list --formula 2>/dev/null || echo "")
    fi
    for pkg in "${packages_array[@]}"; do
        [ -n "$pkg" ] && { eval 'PACKAGE_CACHE[$pkg]="installed"' 2>/dev/null || :; }
    done
    
    # Cache all installed casks
    local casks_array
    if command -v readarray &> /dev/null; then
        readarray -t casks_array < <(brew list --cask 2>/dev/null || echo "")
    else
        casks_array=()
        while IFS= read -r line; do
            [ -n "$line" ] && casks_array+=("$line")
        done < <(brew list --cask 2>/dev/null || echo "")
    fi
    for cask in "${casks_array[@]}"; do
        [ -n "$cask" ] && { eval 'CASK_CACHE[$cask]="installed"' 2>/dev/null || :; }
    done
    
    # Cache all taps
    local taps_array
    if command -v readarray &> /dev/null; then
        readarray -t taps_array < <(brew tap 2>/dev/null || echo "")
    else
        taps_array=()
        while IFS= read -r line; do
            [ -n "$line" ] && taps_array+=("$line")
        done < <(brew tap 2>/dev/null || echo "")
    fi
    for tap in "${taps_array[@]}"; do
        [ -n "$tap" ] && { eval 'TAP_CACHE[$tap]="installed"' 2>/dev/null || :; }
    done
    
    # Cache VS Code extensions
    if command -v code &> /dev/null; then
        local vscode_exts_array
        if command -v readarray &> /dev/null; then
            readarray -t vscode_exts_array < <(code --list-extensions 2>/dev/null || echo "")
        else
            vscode_exts_array=()
            while IFS= read -r line; do
                [ -n "$line" ] && vscode_exts_array+=("$line")
            done < <(code --list-extensions 2>/dev/null || echo "")
        fi
        for ext in "${vscode_exts_array[@]}"; do
            [ -n "$ext" ] && { eval 'VSCODE_EXT_CACHE[$ext]="installed"' 2>/dev/null || :; }
        done
    fi
    
    # Cache Cursor extensions
    # Source extensions.sh if available to get get_cursor_command
    if [ -z "${LIB_PKG_EXTENSIONS_LOADED:-}" ]; then
        _PKG_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$_PKG_SOURCE_DIR/extensions.sh" 2>/dev/null || true
        unset _PKG_SOURCE_DIR
    fi
    if command -v get_cursor_command &> /dev/null; then
        local cursor_cmd
        cursor_cmd=$(get_cursor_command)
        if [ -n "$cursor_cmd" ]; then
            local cursor_exts_array
            if command -v readarray &> /dev/null; then
                readarray -t cursor_exts_array < <("$cursor_cmd" --list-extensions 2>/dev/null || echo "")
            else
                cursor_exts_array=()
                while IFS= read -r line; do
                    [ -n "$line" ] && cursor_exts_array+=("$line")
                done < <("$cursor_cmd" --list-extensions 2>/dev/null || echo "")
            fi
            for ext in "${cursor_exts_array[@]}"; do
                [ -n "$ext" ] && { eval 'CURSOR_EXT_CACHE[$ext]="installed"' 2>/dev/null || :; }
            done
        fi
    fi
    
    PACKAGE_CACHE_INITIALIZED=true
    if command -v log_debug &> /dev/null; then
        log_debug "Package cache initialized"
    fi
}

# Get cached package status
# Usage: get_cached_package_status <package_name> <cache_type>
# Returns: "installed" or "missing" via echo
# cache_type: "package", "cask", "tap", "vscode_ext", "cursor_ext"
get_cached_package_status() {
    local name="$1"
    local cache_type="$2"
    
    if [ "$PACKAGE_CACHE_INITIALIZED" != true ]; then
        echo -n "unknown"
        return 0
    fi
    
    # Check if associative arrays are supported
    if ! check_assoc_array_support; then
        echo -n "unknown"
        return 0
    fi
    
    local result=""
    case "$cache_type" in
        "package")
            result=$(eval 'echo "${PACKAGE_CACHE[$name]:-}"' 2>/dev/null) || result=""
            ;;
        "cask")
            result=$(eval 'echo "${CASK_CACHE[$name]:-}"' 2>/dev/null) || result=""
            ;;
        "tap")
            result=$(eval 'echo "${TAP_CACHE[$name]:-}"' 2>/dev/null) || result=""
            ;;
        "vscode_ext")
            result=$(eval 'echo "${VSCODE_EXT_CACHE[$name]:-}"' 2>/dev/null) || result=""
            ;;
        "cursor_ext")
            result=$(eval 'echo "${CURSOR_EXT_CACHE[$name]:-}"' 2>/dev/null) || result=""
            ;;
        *)
            echo -n "unknown"
            return 0
            ;;
    esac
    
    if [ -n "$result" ]; then
        echo -n "$result"
    else
        echo -n "missing"
    fi
}

# Update package cache for a specific item
# Usage: update_package_cache <package_name> <status> <cache_type>
# status: "installed" or "missing"
# cache_type: "package", "cask", "tap", "vscode_ext", "cursor_ext"
update_package_cache() {
    local name="$1"
    local status="$2"
    local cache_type="$3"
    
    if ! check_assoc_array_support; then
        return 0  # Skip if not supported
    fi
    
    case "$cache_type" in
        "package")
            eval 'PACKAGE_CACHE[$name]=$status' 2>/dev/null || true
            ;;
        "cask")
            eval 'CASK_CACHE[$name]=$status' 2>/dev/null || true
            ;;
        "tap")
            eval 'TAP_CACHE[$name]=$status' 2>/dev/null || true
            ;;
        "vscode_ext")
            eval 'VSCODE_EXT_CACHE[$name]=$status' 2>/dev/null || true
            ;;
        "cursor_ext")
            eval 'CURSOR_EXT_CACHE[$name]=$status' 2>/dev/null || true
            ;;
    esac
}

