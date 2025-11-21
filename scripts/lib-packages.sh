#!/bin/bash
# Package checking helper functions
# Provides functions for checking Homebrew packages, taps, casks, and IDE extensions
# Requires: lib-core.sh (for common variables)

# Source core library if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    source "$(dirname "$0")/lib-core.sh"
fi

# Get Cursor command path
# Usage: get_cursor_command
# Returns: cursor command path via echo, or empty string if not found
get_cursor_command() {
    if command -v cursor &> /dev/null; then
        echo "cursor"
    elif [ -f "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
        echo "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
    fi
}

# Check if a tap is installed
# Usage: is_tap_installed <tap_name>
# Returns: 0 if installed, 1 if not
is_tap_installed() {
    local tap="$1"
    command -v brew &> /dev/null && brew tap | grep -q "^$tap"
}

# Check if a Homebrew package is installed
# Usage: is_brew_package_installed <package_name>
# Returns: 0 if installed, 1 if not
is_brew_package_installed() {
    local pkg="$1"
    command -v brew &> /dev/null && brew list "$pkg" &>/dev/null 2>&1
}

# Check if a Homebrew cask is installed
# Usage: is_brew_cask_installed <cask_name>
# Returns: 0 if installed, 1 if not
is_brew_cask_installed() {
    local cask="$1"
    command -v brew &> /dev/null && brew list --cask "$cask" &>/dev/null 2>&1
}

# Check if a VS Code extension is installed
# Usage: is_vscode_extension_installed <extension_id>
# Returns: 0 if installed, 1 if not
is_vscode_extension_installed() {
    local ext="$1"
    if ! command -v code &> /dev/null; then
        return 1
    fi
    code --list-extensions 2>/dev/null | grep -q "^${ext}$"
}

# Check if a Cursor extension is installed
# Usage: is_cursor_extension_installed <extension_id> <cursor_cmd>
# Returns: 0 if installed, 1 if not
is_cursor_extension_installed() {
    local ext="$1"
    local cursor_cmd="$2"
    local installed_exts
    installed_exts=$("$cursor_cmd" --list-extensions 2>/dev/null || echo "")
    echo "$installed_exts" | grep -q "^${ext}$"
}

