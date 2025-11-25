#!/usr/bin/env bash
# Path and directory utilities library
# Provides functions for determining dotfiles directory and common path variables
# Requires: core/detect-os.sh (for detect_os)

# Prevent re-sourcing
if [ -n "${LIB_PATHS_LOADED:-}" ]; then
    return 0
fi
export LIB_PATHS_LOADED=1

# Source OS detection if not already sourced
if ! command -v detect_os &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# ============================================================================
# Path Utilities
# ============================================================================

# Get the root directory of the dotfiles repository
# 
# Purpose: Determines the absolute path to the dotfiles repository root
# 
# Parameters: None
# 
# Returns: Absolute path to dotfiles directory via echo
# 
# Side effects: None
# 
# Example:
#   DOTFILES_DIR=$(get_dotfiles_dir)
#   echo "Dotfiles are in: $DOTFILES_DIR"
# 
# Note: Assumes this file is in dotfiles/scripts/lib/util/, so it goes up three levels
get_dotfiles_dir() {
    # This file is in dotfiles/scripts/lib/util/
    # So we go up three levels from util/ to get dotfiles/
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo -n "$(cd "$script_dir/../../.." && pwd)"
}

# ============================================================================
# Common Variables Initialization
# ============================================================================

# Initialize common path variables
# These are set when this library is sourced
DOTFILES_DIR="$(get_dotfiles_dir)"
STOW_DIR="$DOTFILES_DIR/stow"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"
OS="$(detect_os)"

