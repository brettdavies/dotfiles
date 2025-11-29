#!/usr/bin/env bash
# GNU Stow checking and installation

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_STOW_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_STOW_LOADED=1

# Source common utilities
_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPS_DIR/common.sh"

# Note: check_simple_dependency function is provided by the packages.sh loader
# If it's not available, the script will fail (no fallbacks)

# Function to install GNU Stow
# Returns: 0 on success, 1 on failure
install_stow() {
    install_package stow || die "Failed to install GNU Stow" 1
}

# Check for GNU Stow
check_stow() {
    check_simple_dependency "GNU Stow" "stow" "install_stow"
}
