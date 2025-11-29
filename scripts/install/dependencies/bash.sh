#!/usr/bin/env bash
# Bash version checking and installation
# Version requirement is read from packages.yaml (currently 5.3.0+ from target_version: "5.3^")

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_BASH_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_BASH_LOADED=1

# Source common utilities
_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPS_DIR/common.sh"

# Note: version_ge, validate_package_version, check_versioned_dependency, and
# get_package_version_constraints functions are provided by the packages.sh loader
# If they're not available, the script will fail (no fallbacks)

# Configuration
BASH_VERSION_PATTERN="version[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?)"

# Function to find bash executable path
# Returns: bash path via echo, empty string if not found
find_bash_executable() {
    if [[ "${OS:-}" == "macos" ]]; then
        # On macOS, prefer Homebrew bash if available
        if command -v brew &> /dev/null; then
            local brew_bash
            brew_bash="$(brew --prefix)/bin/bash"
            if [ -x "$brew_bash" ]; then
                echo "$brew_bash"
                return 0
            fi
        fi
        # Fall back to system bash
        echo "/bin/bash"
    else
        # On Linux, use system bash
        echo "bash"
    fi
}

# Function to install/upgrade bash
# Returns: 0 on success, 1 on failure
install_bash() {
    install_package bash || die "Failed to install/upgrade bash" 1
}

# Function to check bash version and install/upgrade if needed
# Version requirement is read from packages.yaml
check_bash_version() {
    # Ensure Homebrew paths are in PATH first (macOS)
    ensure_homebrew_path
    
    # Get version constraints from packages.yaml
    if ! get_package_version_constraints "bash" "brew"; then
        err "Failed to read bash version constraints from packages.yaml" 1
        return 1
    fi
    
    # Use min_version from packages.yaml (expanded from target_version if present)
    local bash_min_version="${PACKAGE_MIN_VERSION:-5.2}"
    
    local bash_path
    bash_path=$(find_bash_executable)
    
    check_versioned_dependency "bash" "$bash_min_version" "$bash_path" \
        "--version" "$BASH_VERSION_PATTERN" "install_bash" "" "find_bash_executable"
}
