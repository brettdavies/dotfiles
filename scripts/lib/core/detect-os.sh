#!/usr/bin/env bash
# OS detection library
# Provides functions for detecting operating system
# Requires: core/detect-shell.sh (for is_bash_4_plus)

# Prevent re-sourcing
if [ -n "${LIB_DETECT_OS_LOADED:-}" ]; then
    return 0
fi
export LIB_DETECT_OS_LOADED=1

# Source detect-shell if not already sourced (for is_bash_4_plus)
if ! command -v is_bash_4_plus &> /dev/null; then
    # Save and restore _SOURCE_DIR to avoid breaking parent loaders
    _SAVED_SOURCE_DIR="${_SOURCE_DIR:-}"
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/detect-shell.sh" 2>/dev/null || true
    if [ -n "$_SAVED_SOURCE_DIR" ]; then
        _SOURCE_DIR="$_SAVED_SOURCE_DIR"
    fi
    unset _SAVED_SOURCE_DIR
fi

# ============================================================================
# OS Detection
# ============================================================================

# Detect the operating system
# 
# Purpose: Identifies the current OS (macOS, Linux, or unknown) for cross-platform compatibility
# 
# Parameters: None
# 
# Returns: 
#   - "macos" for macOS/Darwin systems
#   - "linux" for Linux systems (GNU or musl)
#   - "unknown" for unrecognized systems
#   Echoes result to stdout (use with command substitution)
# 
# Side effects: None
# 
# Example:
#   OS=$(detect_os)
#   if [ "$OS" = "macos" ]; then
#       echo "Running on macOS"
#   fi
# 
# Uses Bash 4+ features for case conversion (with fallback for Bash 3.2)
detect_os() {
    # Convert to lowercase (Bash 4+), with fallback for older Bash
    local os_type
    if command -v is_bash_4_plus &> /dev/null && is_bash_4_plus; then
        os_type="${OSTYPE,,}"
    else
        # Fallback for Bash 3.2
        os_type=$(echo "$OSTYPE" | tr '[:upper:]' '[:lower:]')
    fi
    
    if [[ "$os_type" == "darwin"* ]]; then
        echo -n "macos"
    elif [[ "$os_type" == "linux-gnu"* ]] || [[ "$os_type" == "linux-musl"* ]]; then
        echo -n "linux"
    else
        echo -n "unknown"
    fi
}

# Detect if running under zsh
# 
# Purpose: Determines if the current shell is zsh for shell-specific optimizations
# 
# Parameters: None
# 
# Returns: 0 (true) if zsh, 1 (false) otherwise
# 
# Side effects: None
# 
# Example:
#   if is_zsh; then
#       echo "Running under zsh"
#   fi
is_zsh() {
    [ -n "${ZSH_VERSION:-}" ]
}

