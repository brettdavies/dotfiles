#!/usr/bin/env bash
# Version constraints and YAML parsing
# Provides functions for parsing version constraints from YAML files
# Requires: util/paths.sh (for STOW_DIR), pkg/version.sh (for version_ge, version_le, version_lt)

# Prevent re-sourcing
if [ -n "${LIB_PKG_VERSION_CONSTRAINTS_LOADED:-}" ]; then
    return 0
fi
export LIB_PKG_VERSION_CONSTRAINTS_LOADED=1

# Source paths if not already sourced
if [ -z "${STOW_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# ============================================================================
# Target version parsing and expansion functions
# ============================================================================

# Parse target_version string to extract base version and check for caret syntax
# Parameters: $1 - target_version string (e.g., "5.2^", "1.6.0")
# Sets global variables: TARGET_VERSION_BASE, TARGET_VERSION_HAS_CARET
parse_target_version() {
    local target_version="$1"
    
    TARGET_VERSION_BASE=""
    TARGET_VERSION_HAS_CARET=false
    
    if [ -z "$target_version" ]; then
        return 1
    fi
    
    # Check if version contains caret
    if [[ "$target_version" =~ \^$ ]]; then
        TARGET_VERSION_HAS_CARET=true
        # Remove caret to get base version
        TARGET_VERSION_BASE="${target_version%^}"
    else
        TARGET_VERSION_BASE="$target_version"
    fi
    
    return 0
}

# Expand target_version with caret syntax to min/max version constraints
# Parameters: $1 - target_version string (e.g., "5.2^")
# Sets global variables: EXPANDED_MIN_VERSION, EXPANDED_MAX_VERSION
# Returns: 0 on success, 1 on failure
expand_target_version() {
    local target_version="$1"
    local base_version
    local has_caret=false
    
    EXPANDED_MIN_VERSION=""
    EXPANDED_MAX_VERSION=""
    
    if [ -z "$target_version" ]; then
        return 1
    fi
    
    # Parse the target version
    if ! parse_target_version "$target_version"; then
        return 1
    fi
    
    base_version="$TARGET_VERSION_BASE"
    has_caret="$TARGET_VERSION_HAS_CARET"
    
    if [ "$has_caret" = true ]; then
        # Expand caret syntax: "X.Y^" means >=X.Y.0, <X.(Y+1).0
        # Split version into parts
        IFS='.' read -ra version_parts <<< "$base_version"
        local major="${version_parts[0]}"
        local minor="${version_parts[1]:-0}"
        
        # Set min version to X.Y.0
        EXPANDED_MIN_VERSION="${major}.${minor}.0"
        
        # Set max version to X.(Y+1).0 (exclusive, so we use < comparison)
        # We'll use a high patch number for the max to represent <X.(Y+1).0
        local next_minor=$((minor + 1))
        EXPANDED_MAX_VERSION="${major}.${next_minor}.0"
    else
        # No caret, treat as exact version (min and max are the same)
        EXPANDED_MIN_VERSION="$base_version"
        EXPANDED_MAX_VERSION="$base_version"
    fi
    
    return 0
}

# Get version constraints for a package from packages.yaml
# Parameters: $1 - package key, $2 - platform (brew, linux, etc.)
# Sets global variables: PACKAGE_MIN_VERSION, PACKAGE_MAX_VERSION, and PACKAGE_MAX_VERSION_EXCLUSIVE
get_package_version_constraints() {
    local package_key="$1"
    local platform="${2:-}"
    local packages_yaml="${STOW_DIR:-}/brew/packages.yaml"
    
    PACKAGE_MIN_VERSION=""
    PACKAGE_MAX_VERSION=""
    PACKAGE_MAX_VERSION_EXCLUSIVE=false
    
    if [ ! -f "$packages_yaml" ]; then
        return 1
    fi
    
    if ! command -v yq &> /dev/null; then
        return 1
    fi
    
    # Determine if this is a package or cask
    local is_cask=false
    if yq -e ".casks.\"$package_key\"" "$packages_yaml" &>/dev/null; then
        is_cask=true
    fi
    
    local base_path
    if [ "$is_cask" = true ]; then
        base_path=".casks.\"$package_key\""
    else
        base_path=".packages.\"$package_key\""
    fi
    
    # Get target_version first (takes precedence over min/max)
    local target_version=""
    local brew_target_version=""
    
    # Get platform-specific constraints first, then fall back to package-level
    if [ -n "$platform" ] && [ "$platform" = "brew" ]; then
        # Check for brew-specific target_version first
        brew_target_version=$(yq -r "$base_path.brew_target_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        
        # Also check if brew is an object with target_version field
        if [ -z "$brew_target_version" ] || [ "$brew_target_version" = "null" ]; then
            brew_target_version=$(yq -r "$base_path.brew.target_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        fi
        
        # Use brew_target_version if available, otherwise fall back to package-level target_version
        if [ -n "$brew_target_version" ] && [ "$brew_target_version" != "null" ]; then
            target_version="$brew_target_version"
        else
            target_version=$(yq -r "$base_path.target_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        fi
        
        # If target_version is set, expand it and use as min/max (overriding any explicit min/max)
        if [ -n "$target_version" ] && [ "$target_version" != "null" ]; then
            if expand_target_version "$target_version"; then
                PACKAGE_MIN_VERSION="$EXPANDED_MIN_VERSION"
                PACKAGE_MAX_VERSION="$EXPANDED_MAX_VERSION"
                # If target_version had caret, max is exclusive
                if [ "$TARGET_VERSION_HAS_CARET" = true ]; then
                    PACKAGE_MAX_VERSION_EXCLUSIVE=true
                fi
                return 0
            fi
        fi
        
        # No target_version, check for brew-specific min/max constraints
        PACKAGE_MIN_VERSION=$(yq -r "$base_path.brew_min_version // $base_path.min_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        PACKAGE_MAX_VERSION=$(yq -r "$base_path.brew_max_version // $base_path.max_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        
        # Also check if brew is an object with version fields
        if [ -z "$PACKAGE_MIN_VERSION" ] || [ "$PACKAGE_MIN_VERSION" = "null" ]; then
            PACKAGE_MIN_VERSION=$(yq -r "$base_path.brew.min_version // $base_path.min_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        fi
        if [ -z "$PACKAGE_MAX_VERSION" ] || [ "$PACKAGE_MAX_VERSION" = "null" ]; then
            PACKAGE_MAX_VERSION=$(yq -r "$base_path.brew.max_version // $base_path.max_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        fi
    else
        # Use package-level constraints
        target_version=$(yq -r "$base_path.target_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        
        # If target_version is set, expand it and use as min/max
        if [ -n "$target_version" ] && [ "$target_version" != "null" ]; then
            if expand_target_version "$target_version"; then
                PACKAGE_MIN_VERSION="$EXPANDED_MIN_VERSION"
                PACKAGE_MAX_VERSION="$EXPANDED_MAX_VERSION"
                # If target_version had caret, max is exclusive
                if [ "$TARGET_VERSION_HAS_CARET" = true ]; then
                    PACKAGE_MAX_VERSION_EXCLUSIVE=true
                fi
                return 0
            fi
        fi
        
        # No target_version, use package-level min/max
        PACKAGE_MIN_VERSION=$(yq -r "$base_path.min_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
        PACKAGE_MAX_VERSION=$(yq -r "$base_path.max_version // \"\"" "$packages_yaml" 2>/dev/null || echo "")
    fi
    
    # Clean up null values
    if [ "$PACKAGE_MIN_VERSION" = "null" ] || [ -z "$PACKAGE_MIN_VERSION" ]; then
        PACKAGE_MIN_VERSION=""
    fi
    if [ "$PACKAGE_MAX_VERSION" = "null" ] || [ -z "$PACKAGE_MAX_VERSION" ]; then
        PACKAGE_MAX_VERSION=""
    fi
    
    return 0
}

