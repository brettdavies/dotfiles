#!/bin/bash
# File operations helper functions
# Provides functions for file operations like getting permissions
# Requires: lib-core.sh (for common variables)

# Source core library if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    source "$(dirname "$0")/lib-core.sh"
fi

# Get file permissions in a cross-platform way
# Usage: get_file_permissions <file_path>
# Returns: permissions as octal string (e.g., "600")
get_file_permissions() {
    local file="$1"
    stat -f "%OLp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null
}

