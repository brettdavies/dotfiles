#!/bin/bash
# Shared library for dotfiles installation scripts
# Provides common functions and variables

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -n "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ "$OSTYPE" == "linux-musl"* ]]; then
        echo -n "linux"
    else
        echo -n "unknown"
    fi
}

# Get the directory where the install script is located
get_dotfiles_dir() {
    # This assumes scripts are in dotfiles/scripts/
    # So we go up one level from scripts/ to get dotfiles/
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo -n "$(cd "$script_dir/.." && pwd)"
}

# Initialize common variables
DOTFILES_DIR="$(get_dotfiles_dir)"
STOW_DIR="$DOTFILES_DIR/stow"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"
OS="$(detect_os)"

