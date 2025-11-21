#!/bin/bash
# Core library for dotfiles installation scripts
# Provides colors, OS detection, common variables, argument parsing, and verbose output
# This file should be sourced by all scripts

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

# Parse common command-line arguments (--dry-run, --verbose, --sync-local, --merge)
# Sets global variables DRY_RUN, VERBOSE, SYNC_LOCAL, SYNC_MERGE
# Usage: parse_common_args "$@"
parse_common_args() {
    DRY_RUN=false
    VERBOSE=false
    SYNC_LOCAL=false
    SYNC_MERGE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --sync-local)
                SYNC_LOCAL=true
                shift
                ;;
            --merge)
                SYNC_MERGE=true
                shift
                ;;
            *)
                # Unknown argument, ignore (might be from parent script or script-specific)
                shift
                ;;
        esac
    done
}

# ============================================================================
# Standardized verbose output helpers
# These functions provide consistent formatting across all scripts
# ============================================================================

# Print verbose "found" status
# Usage: verbose_found <item_name> [additional_info]
# Example: verbose_found "GNU Stow" -> "  → GNU Stow: found"
verbose_found() {
    local item="$1"
    local info="${2:-}"
    if [ "$VERBOSE" = true ]; then
        if [ -n "$info" ]; then
            echo -e "${GREEN}  → $item: found ($info)${NC}"
        else
            echo -e "${GREEN}  → $item: found${NC}"
        fi
    fi
}

# Print verbose "not found (would install)" status
# Usage: verbose_missing <item_name> [additional_info]
# Example: verbose_missing "GNU Stow" -> "  → GNU Stow: not found (would install)"
verbose_missing() {
    local item="$1"
    local info="${2:-would install}"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → $item: not found ($info)${NC}"
    fi
}

# Print verbose "installed" status
# Usage: verbose_installed <item_type> <item_name>
# Example: verbose_installed "Package" "zsh" -> "  → Package: zsh (installed)"
verbose_installed() {
    local type="$1"
    local name="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → $type: $name (installed)${NC}"
    fi
}

# Print verbose "would install" status
# Usage: verbose_would_install <item_type> <item_name>
# Example: verbose_would_install "Package" "zsh" -> "  → Package: zsh (would install)"
verbose_would_install() {
    local type="$1"
    local name="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → $type: $name (would install)${NC}"
    fi
}

# Print verbose "would create" status
# Usage: verbose_would_create <item_path> [target_info]
# Example: verbose_would_create "~/.secrets" -> "  → Would create: ~/.secrets"
verbose_would_create() {
    local item="$1"
    local target="${2:-}"
    if [ "$VERBOSE" = true ]; then
        if [ -n "$target" ]; then
            echo -e "${YELLOW}  → Would create: $item -> $target${NC}"
        else
            echo -e "${YELLOW}  → Would create: $item${NC}"
        fi
    fi
}

# Print verbose "already set up" status
# Usage: verbose_already_setup <item_path> [additional_info]
# Example: verbose_already_setup ".zshrc" -> "    ✓ Already set up: .zshrc"
verbose_already_setup() {
    local item="$1"
    local info="${2:-}"
    if [ "$VERBOSE" = true ]; then
        if [ -n "$info" ]; then
            echo -e "    ${GREEN}✓ Already set up: $item ($info)${NC}"
        else
            echo -e "    ${GREEN}✓ Already set up: $item${NC}"
        fi
    fi
}

# Print verbose conflict warning
# Usage: verbose_conflict <item_path> <reason>
# Example: verbose_conflict ".zshrc" "exists (not a symlink) - would be removed"
verbose_conflict() {
    local item="$1"
    local reason="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "    ${YELLOW}⚠ Conflict: $item $reason${NC}"
    fi
}

# Print verbose "already exists" status
# Usage: verbose_already_exists <item_path> [additional_info]
# Example: verbose_already_exists ".secrets" "permissions: 600"
verbose_already_exists() {
    local item="$1"
    local info="${2:-}"
    if [ "$VERBOSE" = true ]; then
        if [ -n "$info" ]; then
            echo -e "${GREEN}  → $item already exists ($info)${NC}"
        else
            echo -e "${GREEN}  → $item already exists${NC}"
        fi
    fi
}

# Print verbose "would update" status
# Usage: verbose_would_update <item_path> <change_description>
# Example: verbose_would_update ".secrets" "permissions: 644 -> 600"
verbose_would_update() {
    local item="$1"
    local change="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → Would update: $item ($change)${NC}"
    fi
}

# Print verbose "detected via" status
# Usage: verbose_detected <item_name> <detection_method>
# Example: verbose_detected "LM Studio" "'lms' command"
verbose_detected() {
    local item="$1"
    local method="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → $item detected via $method${NC}"
    fi
}

