#!/usr/bin/env bash
# Verbose output helpers library
# Provides standardized verbose output functions for consistent formatting
# Requires: core/constants.sh (for colors), util/args.sh (for VERBOSE flag)

# Prevent re-sourcing
if [ -n "${LIB_VERBOSE_LOADED:-}" ]; then
    return 0
fi
export LIB_VERBOSE_LOADED=1

# Source constants if not already sourced
if [ -z "${RED:-}" ] || [ -z "${GREEN:-}" ] || [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# Ensure VERBOSE variable exists (default to false if not set)
: "${VERBOSE:=false}"

# ============================================================================
# Standardized verbose output helpers
# These functions provide consistent formatting across all scripts
# ============================================================================

# Print verbose "found" status
# 
# Purpose: Displays a "found" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item name (required)
#   $2 - Additional information (optional)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_found "GNU Stow"
#   verbose_found "GNU Stow" "version 2.3.1"
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
# 
# Purpose: Displays a "not found" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item name (required)
#   $2 - Additional information (optional, default: "would install")
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_missing "GNU Stow"
#   verbose_missing "GNU Stow" "cannot install (missing dependencies)"
verbose_missing() {
    local item="$1"
    local info="${2:-would install}"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → $item: not found ($info)${NC}"
    fi
}

# Print verbose "installed" status
# 
# Purpose: Displays an "installed" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item type (required, e.g., "Package", "Extension")
#   $2 - Item name (required)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_installed "Package" "zsh"
#   verbose_installed "Extension" "vscode.vim"
verbose_installed() {
    local type="$1"
    local name="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → $type: $name (installed)${NC}"
    fi
}

# Print verbose "would install" status
# 
# Purpose: Displays a "would install" message when verbose mode is enabled (typically in dry-run mode)
# 
# Parameters:
#   $1 - Item type (required, e.g., "Package", "Extension")
#   $2 - Item name (required)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_would_install "Package" "zsh"
#   verbose_would_install "Extension" "vscode.vim"
verbose_would_install() {
    local type="$1"
    local name="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → $type: $name (would install)${NC}"
    fi
}

# Print verbose "would create" status
# 
# Purpose: Displays a "would create" message when verbose mode is enabled (typically in dry-run mode)
# 
# Parameters:
#   $1 - Item path (required)
#   $2 - Target information (optional)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_would_create "~/.secrets"
#   verbose_would_create "~/.secrets" "with 600 permissions"
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
# 
# Purpose: Displays an "already set up" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item path (required)
#   $2 - Additional information (optional)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_already_setup ".zshrc"
#   verbose_already_setup ".zshrc" "correctly symlinked"
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
# 
# Purpose: Displays a conflict warning message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item path (required)
#   $2 - Reason for conflict (required)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_conflict ".zshrc" "exists (not a symlink) - would be removed"
verbose_conflict() {
    local item="$1"
    local reason="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "    ${YELLOW}⚠ Conflict: $item $reason${NC}"
    fi
}

# Print verbose "already exists" status
# 
# Purpose: Displays an "already exists" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item path (required)
#   $2 - Additional information (optional)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_already_exists ".secrets"
#   verbose_already_exists ".secrets" "permissions: 600"
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
# 
# Purpose: Displays a "would update" message when verbose mode is enabled (typically in dry-run mode)
# 
# Parameters:
#   $1 - Item path (required)
#   $2 - Change description (required)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_would_update ".secrets" "permissions: 644 -> 600"
verbose_would_update() {
    local item="$1"
    local change="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}  → Would update: $item ($change)${NC}"
    fi
}

# Print verbose "detected via" status
# 
# Purpose: Displays a "detected via" message when verbose mode is enabled
# 
# Parameters:
#   $1 - Item name (required)
#   $2 - Detection method (required)
# 
# Returns: Nothing
# 
# Side effects: Prints to stdout if VERBOSE is true
# 
# Example:
#   verbose_detected "LM Studio" "'lms' command"
#   verbose_detected "LM Studio" "~/.lmstudio directory"
verbose_detected() {
    local item="$1"
    local method="$2"
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → $item detected via $method${NC}"
    fi
}

