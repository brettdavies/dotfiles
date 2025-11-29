#!/usr/bin/env bash
# yq version checking and installation
# Requires yq v4.0+ for generate-brewfile.sh compatibility

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_YQ_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_YQ_LOADED=1

# Source common utilities
_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPS_DIR/common.sh"

# Note: version_ge, validate_package_version, check_versioned_dependency, and
# get_package_version_constraints functions are provided by the packages.sh loader
# If they're not available, the script will fail (no fallbacks)

# Configuration
YQ_VERSION_PATTERN="version[[:space:]]+v?([0-9]+\.[0-9]+(\.[0-9]+)?)"

# Function to install yq
# Returns: 0 on success, 1 on failure
install_yq() {
    install_package yq || die "Failed to install yq" 1
}

# Function to upgrade yq
# Returns: 0 on success, 1 on failure
upgrade_yq() {
    if [[ "${OS:-}" == "macos" ]]; then
        # On macOS, use brew upgrade (fallback to install if not installed)
        if ! command -v brew &> /dev/null; then
            err "Homebrew not found. Please install Homebrew first, or install yq v4.0+ manually" 1
            return 1
        fi
        brew upgrade yq || brew install yq || die "Failed to install/upgrade yq via Homebrew" 1
    else
        # On Linux, try upgrade via package manager, fallback to install
        install_package yq || die "Failed to upgrade yq" 1
    fi
}

# Function to check yq version and install/upgrade if needed
# Version requirement is read from packages.yaml
check_yq_version() {
    # Ensure Homebrew paths are in PATH first (macOS)
    ensure_homebrew_path
    
    # Get version constraints from packages.yaml
    if ! get_package_version_constraints "yq" "brew"; then
        err "Failed to read yq version constraints from packages.yaml" 1
        return 1
    fi
    
    # Use min_version from packages.yaml
    local yq_min_version="${PACKAGE_MIN_VERSION:-4.0}"
    
    check_versioned_dependency "yq" "$yq_min_version" "yq" \
        "--version" "$YQ_VERSION_PATTERN" "install_yq" "upgrade_yq"
}
