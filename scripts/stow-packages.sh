#!/bin/bash
# Stow all dotfiles packages to create symlinks
#
# Uses stow --dotfiles for all packages except VS Code (see exception in code).
# The --dotfiles option converts dot-* prefixes to .* prefixes automatically.

set -e

# Source shared library
source "$(dirname "$0")/lib.sh"

# Function to remove existing files/directories that would conflict with symlinks
# This is a prerequisite step before stow can create symlinks safely
# Stow will fail if target files/directories already exist and aren't symlinks
# This function handles the --dotfiles transformation (dot-* -> .*)
remove_conflicting_files() {
    local package=$1
    local target=$2
    
    # Find all files in the package directory
    if [ ! -d "$package" ]; then
        return 0  # Package doesn't exist, nothing to remove
    fi
    
        # Find files in package directory, but don't follow symlinks (-P flag)
        # This ensures we only process actual files in the repo, not symlinks
        find -P "$package" -type f | while read -r file; do
            # Get relative path from package directory
            rel_path="${file#$package/}"
            
            # Apply --dotfiles transformation: convert dot-* prefixes to .* prefixes
            # This matches what stow --dotfiles does
            transformed_path=$(echo "$rel_path" | sed 's|dot-|.|g')
            
            # Construct target path with transformed path
            # Expand ~ to $HOME if present, and ensure absolute path
            if [[ "$target" == "~" ]]; then
                target_file="$HOME/$transformed_path"
            else
                target_file="$target/$transformed_path"
            fi
        
        # Safety check: Only process files in the home directory, never in the repo
        # Verify STOW_DIR is set (should be set by lib.sh)
        if [[ -z "$STOW_DIR" ]]; then
            echo "    ERROR: STOW_DIR not set! Skipping to prevent accidental deletion."
            continue
        fi
        
        # Skip if target is not in HOME or if it's in STOW_DIR (the repo)
        if [[ ! "$target_file" =~ ^"$HOME"/ ]] || [[ "$target_file" =~ ^"$STOW_DIR"/ ]]; then
            continue
        fi
        
        # If target exists, check what to do
        if [ -e "$target_file" ]; then
            if [ -L "$target_file" ]; then
                # Already a symlink, skip it - stow will handle it or report if there's an issue
                continue
            else
                # Regular file or directory, remove it to make way for symlink
                # Check: ensure target_file is not the same as source file (using realpath to handle symlinks)
                if [[ "$(realpath "$file" 2>/dev/null || echo "$file")" == "$(realpath "$target_file" 2>/dev/null || echo "$target_file")" ]]; then
                    # Target is already a symlink pointing to source, skip it
                    echo "    SKIP: Already symlinked: ${target_file#$HOME/}"
                    continue
                fi
                echo "    Removing existing: ${target_file#$HOME/}"
                rm -rf "$target_file"
            fi
        fi
    done
}

# Function to stow a package with dotfiles support
# Uses stow's --dotfiles option which converts dot-* prefixes to .* prefixes
# This allows us to keep files visible in the stow directory (with dot- prefix)
# while creating proper hidden dotfiles (with . prefix) in the home directory
# Outputs any messages from remove_conflicting_files to stdout
stow_package() {
    local package=$1
    
    if [ ! -d "$STOW_DIR/$package" ]; then
        return 0  # Package doesn't exist
    fi
    
    # Remove conflicting files first (output goes to stdout)
    remove_conflicting_files "$STOW_DIR/$package" "$HOME"
    
    # Use stow with --dotfiles option to handle dot-* prefixes
    cd "$STOW_DIR"
    stow --dotfiles -t "$HOME" "$package" 2>/dev/null || true
}

# Main execution
echo -e "${GREEN}Creating symlinks...${NC}"

# Shell configs
output_zsh=$(stow_package zsh 2>&1)
output_bash=$(stow_package bash 2>&1)
if [ -n "${output_zsh// }" ] || [ -n "${output_bash// }" ]; then
    echo "  - Shell configs (zsh, bash)"
    [ -n "${output_zsh// }" ] && echo "$output_zsh"
    [ -n "${output_bash// }" ] && echo "$output_bash"
fi

# Git configs
output=$(stow_package git 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Git configs"
    echo "$output"
fi

# SSH config
output=$(stow_package ssh 2>&1)
if [ -n "${output// }" ]; then
    echo "  - SSH config"
    echo "$output"
fi

# Terminal configs
output=$(stow_package ghostty 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Terminal configs (ghostty)"
    echo "$output"
fi

# GitHub CLI configs
output=$(stow_package gh 2>&1)
if [ -n "${output// }" ]; then
    echo "  - GitHub CLI configs"
    echo "$output"
fi

# oh-my-zsh customizations
output=$(stow_package oh-my-zsh 2>&1)
if [ -n "${output// }" ]; then
    echo "  - oh-my-zsh customizations"
    echo "$output"
fi

# Local bin configs
output=$(stow_package local 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Local bin configs"
    echo "$output"
fi

# Claude IDE configs
output=$(stow_package claude 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Claude IDE configs"
    echo "$output"
fi

# Codex configs
output=$(stow_package codex 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Codex configs"
    echo "$output"
fi

# Cursor configs
output=$(stow_package cursor 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Cursor configs"
    echo "$output"
fi

# OpenCode configs
output=$(stow_package opencode 2>&1)
if [ -n "${output// }" ]; then
    echo "  - OpenCode configs"
    echo "$output"
fi

# Telemetry settings
output=$(stow_package telemetry 2>&1)
if [ -n "${output// }" ]; then
    echo "  - Telemetry settings"
    echo "$output"
fi

# VS Code settings (macOS specific)
# EXCEPTION: Uses regular stow (not --dotfiles) because:
# 1. VS Code settings are in a non-standard location (~/Library/Application Support/Code/User)
# 2. Files don't need dot prefix restoration (they're not dotfiles)
# 3. We stow from inside the vscode directory to target the correct path structure
if [[ "$OS" == "macos" ]]; then
    echo "  - VS Code settings"
    VS_CODE_DIR="$HOME/Library/Application Support/Code/User"
    if [ ! -d "$VS_CODE_DIR" ]; then
        mkdir -p "$VS_CODE_DIR"
    fi
    # Remove conflicting files
    if [ -d "$STOW_DIR/vscode" ]; then
        find "$STOW_DIR/vscode" -type f | while read -r file; do
            rel_path="${file#$STOW_DIR/vscode/}"
            target_file="$VS_CODE_DIR/$rel_path"
            if [ -e "$target_file" ] && [ ! -L "$target_file" ]; then
                echo "    Removing existing: ${target_file#$HOME/}"
                rm -rf "$target_file"
            fi
        done
        # Stow from vscode directory, targeting Library/Application Support/Code/User
        cd "$STOW_DIR/vscode"
        stow -t "$VS_CODE_DIR" . 2>/dev/null || true
        cd "$STOW_DIR"
    else
        echo "    (VS Code config directory not found, skipping)"
    fi
fi

