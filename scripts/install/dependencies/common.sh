#!/usr/bin/env bash
# Common utilities for dependency checking
# Provides shared functions used by all dependency checkers
#
# Note: Version comparison functions (version_ge, version_le, version_lt) are provided
# by the packages.sh loader, which is loaded by the orchestrator (check-dependencies.sh).
# This file provides dependency-checker-specific utilities only.

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_COMMON_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_COMMON_LOADED=1

# Function to ensure Homebrew paths are in PATH (macOS only)
# This must be done early so we can find Homebrew-installed tools
ensure_homebrew_path() {
    if [[ "${OS:-}" != "macos" ]]; then
        return 0
    fi
    
    # Check for Homebrew in standard locations and add to PATH if found
    if [ -d "/opt/homebrew/bin" ]; then
        # Apple Silicon Macs
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
    elif [ -d "/usr/local/bin" ]; then
        # Legacy Homebrew location (Intel Macs)
        export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
    fi
}

# Function to install package using system package manager
# Parameters: $1 - package name
install_package() {
    local package=$1
    
    if [[ "${OS:-}" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install "$package"
        else
            err "Homebrew not found. Please install $package manually" 1
            return 1
        fi
    elif [[ "${OS:-}" == "linux" ]]; then
        if command -v apk &> /dev/null; then
            # Alpine Linux
            apk add --no-cache "$package"
        elif command -v apt-get &> /dev/null; then
            # Ubuntu/Debian
            if [ "$EUID" -eq 0 ]; then
                apt-get update && apt-get install -y "$package"
            else
                sudo apt-get update && sudo apt-get install -y "$package"
            fi
        elif command -v yum &> /dev/null; then
            # RHEL/CentOS
            if [ "$EUID" -eq 0 ]; then
                yum install -y "$package"
            else
                sudo yum install -y "$package"
            fi
        elif command -v dnf &> /dev/null; then
            # Fedora
            if [ "$EUID" -eq 0 ]; then
                dnf install -y "$package"
            else
                sudo dnf install -y "$package"
            fi
        else
            err "Package manager not found. Please install $package manually" 1
            return 1
        fi
    else
        err "Unsupported OS. Please install $package manually" 1
        return 1
    fi
}

