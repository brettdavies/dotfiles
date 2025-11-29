#!/usr/bin/env bash
# Generate Brewfile from packages.yaml
# Run this after updating packages.yaml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_YAML="$SCRIPT_DIR/packages.yaml"
BREWFILE="$SCRIPT_DIR/Brewfile"

# Source core libraries for logging and error handling
LIB_DIR="$SCRIPT_DIR/../../scripts/lib"
if [ -f "$LIB_DIR/loaders/packages.sh" ]; then
    # Set STOW_DIR if not already set (needed by package functions)
    export STOW_DIR="${STOW_DIR:-$SCRIPT_DIR/..}"
    source "$LIB_DIR/loaders/packages.sh"
else
    # Fallback if packages.sh not found
    echo "Warning: loaders/packages.sh not found at $LIB_DIR/loaders/packages.sh" >&2
    # Note: Cannot log here since logging functions aren't available yet
fi

if [ ! -f "$PACKAGES_YAML" ]; then
    if command -v die &> /dev/null; then
        die "packages.yaml not found at $PACKAGES_YAML" 1
    else
        echo "Error: packages.yaml not found at $PACKAGES_YAML" >&2
        exit 1
    fi
fi

# Check for yq, install if missing (macOS only)
if ! command -v yq &> /dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &> /dev/null; then
        if command -v log_info &> /dev/null; then
            log_info "yq not found. Installing..."
        fi
        echo "yq not found. Installing..."
        brew install yq || {
            if command -v die &> /dev/null; then
                die "Failed to install yq via Homebrew" 1
            else
                echo "Error: Failed to install yq via Homebrew" >&2
                exit 1
            fi
        }
    else
        if command -v die &> /dev/null; then
            die "yq is required to generate Brewfile. Install with: brew install yq (macOS) or from https://github.com/mikefarah/yq" 1
        else
            echo "Error: yq is required to generate Brewfile" >&2 && echo "Install with: brew install yq (macOS) or from https://github.com/mikefarah/yq" >&2
            exit 1
        fi
    fi
fi

echo "# Essential packages for dotfiles setup" > "$BREWFILE"
echo "# Generated from packages.yaml - DO NOT EDIT MANUALLY" >> "$BREWFILE"
echo "# Run ./stow/brew/generate-brewfile.sh after updating packages.yaml" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# Extract unique taps
echo "# Required taps" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.value.taps != null) | .value.taps[]' "$PACKAGES_YAML" | sort -u | while read tap; do
    echo "tap \"$tap\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# Helper function to get version string for a package
# Returns package@version if target_version or min_version exists, otherwise just package
# Priority: brew_target_version > target_version > brew_min_version > min_version
# When target_version contains "^", queries Homebrew for available versions
get_brew_package_with_version() {
    local pkg_entry="$1"
    local brew_name
    local target_version
    local min_version
    local version_to_use=""
    
    # Get brew name - handle both string and object forms
    # Try string first, then object.name, using yq v4 compatible syntax
    brew_name=$(echo "$pkg_entry" | yq eval -r '.value.brew | (select(type == "!!str") // .name // "")' 2>/dev/null || echo "$pkg_entry" | yq eval -r '.value.brew.name // .value.brew // ""')
    [ -z "$brew_name" ] && return 1
    
    # Check for target_version first (highest priority)
    # Check brew_target_version first, then target_version
    # Use fallback pattern compatible with yq v4
    target_version=$(echo "$pkg_entry" | yq eval -r '.value.brew.target_version // .value.target_version // .value.brew_target_version // ""')
    
    # If target_version is set and contains caret, query Homebrew
    if [ -n "$target_version" ] && [ "$target_version" != "null" ]; then
        # Check if it contains caret
        if [[ "$target_version" =~ \^$ ]]; then
            # Check if required functions are available
            if ! command -v query_brew_versions &> /dev/null || ! command -v expand_target_version &> /dev/null || ! command -v find_matching_version &> /dev/null; then
                # Functions not available, fallback to base version without caret
                version_to_use="${target_version%^}"
                if command -v log_warn &> /dev/null; then
                    log_warn "Version querying functions not available for $brew_name, using base version: $version_to_use"
                fi
                echo "Warning: Version querying functions not available for $brew_name, using base version: $version_to_use" >&2
            else
                # Query Homebrew for available versions
                local available_versions
                available_versions=$(query_brew_versions "$brew_name" "package" 2>/dev/null || echo "")
                
                if [ -n "$available_versions" ]; then
                    # Expand target_version to get min/max constraints
                    if expand_target_version "$target_version"; then
                        # Find matching version
                        local matched_version
                        matched_version=$(find_matching_version "$available_versions" "$EXPANDED_MIN_VERSION" "$EXPANDED_MAX_VERSION" 2>/dev/null || echo "")
                        
                        if [ -n "$matched_version" ]; then
                            version_to_use="$matched_version"
                        else
                            # Fallback: use latest available version
                            version_to_use=$(echo "$available_versions" | head -n1)
                            if command -v log_warn &> /dev/null; then
                                log_warn "No version matching $target_version found for $brew_name, using latest: $version_to_use"
                            fi
                            echo "Warning: No version matching $target_version found for $brew_name, using latest: $version_to_use" >&2
                        fi
                    else
                        # Expansion failed, use base version without caret
                        version_to_use="${target_version%^}"
                        if command -v log_warn &> /dev/null; then
                            log_warn "Failed to expand target_version $target_version for $brew_name, using base version: $version_to_use"
                        fi
                        echo "Warning: Failed to expand target_version $target_version for $brew_name, using base version: $version_to_use" >&2
                    fi
                else
                    # Query failed, fallback to base version without caret
                    version_to_use="${target_version%^}"
                    if command -v log_warn &> /dev/null; then
                        log_warn "Failed to query versions for $brew_name, using base version: $version_to_use"
                    fi
                    echo "Warning: Failed to query versions for $brew_name, using base version: $version_to_use" >&2
                fi
            fi
        else
            # No caret, use target_version as-is
            version_to_use="$target_version"
        fi
    else
        # No target_version, check for min_version (fallback)
        min_version=$(echo "$pkg_entry" | yq eval -r '.value.brew.min_version // .value.min_version // .value.brew_min_version // ""')
        
        if [ -n "$min_version" ] && [ "$min_version" != "null" ]; then
            version_to_use="$min_version"
        fi
    fi
    
    if [ -n "$version_to_use" ]; then
        echo "${brew_name}@${version_to_use}"
    else
        echo "$brew_name"
    fi
}

# oh-my-zsh theme
echo "# oh-my-zsh theme" >> "$BREWFILE"
yq eval -o=json -I=0 '.packages | to_entries[] | select(.value.linux.git != null and .value.linux.type == "theme")' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# oh-my-zsh plugins
echo "# oh-my-zsh plugins" >> "$BREWFILE"
yq eval -o=json -I=0 '.packages | to_entries[] | select(.value.linux.git != null and .value.linux.type == "plugin")' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# Development tools
echo "# Development tools" >> "$BREWFILE"
yq eval -o=json -I=0 '.packages | to_entries[] | select(.key == "node" or .key == "bun" or .key == "uv" or .key == "gh" or .key == "libpq")' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# Code quality & utilities
echo "# Code quality & utilities" >> "$BREWFILE"
yq eval -o=json -I=0 '.packages | to_entries[] | select(.value.linux.pkg != null and .key != "node" and .key != "bun" and .key != "uv" and .key != "gh" and .key != "libpq" and (.value.linux.git == null))' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
yq eval -o=json -I=0 '.packages | to_entries[] | select((.value.linux.pip != null or .value.linux.installer != null) and .value.macos_only != true and .key != "node" and .key != "bun" and .key != "uv" and .key != "gh" and (.value.linux.git == null))' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# macOS-specific utilities
echo "# macOS-specific utilities" >> "$BREWFILE"
yq eval -o=json -I=0 '.packages | to_entries[] | select(.value.macos_only == true)' "$PACKAGES_YAML" | while read -r pkg_entry; do
    brew_pkg=$(get_brew_package_with_version "$pkg_entry")
    [ -n "$brew_pkg" ] && echo "brew \"$brew_pkg\"" >> "$BREWFILE"
done
echo "" >> "$BREWFILE"

# macOS casks
echo "# macOS casks" >> "$BREWFILE"
yq eval -o=json -I=0 '.casks | to_entries[] | select(.value.macos_only == true)' "$PACKAGES_YAML" | while read -r pkg_entry; do
    # Handle both string and object forms of brew
    brew_name=$(echo "$pkg_entry" | yq eval -r '.value.brew | (select(type == "!!str") // .name // "")' 2>/dev/null || echo "$pkg_entry" | yq eval -r '.value.brew.name // .value.brew // ""')
    [ -z "$brew_name" ] && continue
    
    target_version=""
    min_version=""
    version_to_use=""
    
    # Check for target_version first (highest priority)
    target_version=$(echo "$pkg_entry" | yq eval -r '.value.brew.target_version // .value.target_version // .value.brew_target_version // ""')
    
    # If target_version is set and contains caret, query Homebrew
    if [ -n "$target_version" ] && [ "$target_version" != "null" ]; then
        # Check if it contains caret
        if [[ "$target_version" =~ \^$ ]]; then
            # Check if required functions are available
            if ! command -v query_brew_versions &> /dev/null || ! command -v expand_target_version &> /dev/null || ! command -v find_matching_version &> /dev/null; then
                # Functions not available, fallback to base version without caret
                version_to_use="${target_version%^}"
                if command -v log_warn &> /dev/null; then
                    log_warn "Version querying functions not available for cask $brew_name, using base version: $version_to_use"
                fi
                echo "Warning: Version querying functions not available for cask $brew_name, using base version: $version_to_use" >&2
            else
                # Query Homebrew for available cask versions
                local available_versions
                available_versions=$(query_brew_versions "$brew_name" "cask" 2>/dev/null || echo "")
                
                if [ -n "$available_versions" ]; then
                    # Expand target_version to get min/max constraints
                    if expand_target_version "$target_version"; then
                        # Find matching version
                        local matched_version
                        matched_version=$(find_matching_version "$available_versions" "$EXPANDED_MIN_VERSION" "$EXPANDED_MAX_VERSION" 2>/dev/null || echo "")
                        
                        if [ -n "$matched_version" ]; then
                            version_to_use="$matched_version"
                        else
                            # Fallback: use latest available version
                            version_to_use=$(echo "$available_versions" | head -n1)
                            if command -v log_warn &> /dev/null; then
                                log_warn "No version matching $target_version found for cask $brew_name, using latest: $version_to_use"
                            fi
                            echo "Warning: No version matching $target_version found for cask $brew_name, using latest: $version_to_use" >&2
                        fi
                    else
                        # Expansion failed, use base version without caret
                        version_to_use="${target_version%^}"
                        if command -v log_warn &> /dev/null; then
                            log_warn "Failed to expand target_version $target_version for cask $brew_name, using base version: $version_to_use"
                        fi
                        echo "Warning: Failed to expand target_version $target_version for cask $brew_name, using base version: $version_to_use" >&2
                    fi
                else
                    # Query failed, fallback to base version without caret
                    version_to_use="${target_version%^}"
                    if command -v log_warn &> /dev/null; then
                        log_warn "Failed to query versions for cask $brew_name, using base version: $version_to_use"
                    fi
                    echo "Warning: Failed to query versions for cask $brew_name, using base version: $version_to_use" >&2
                fi
            fi
        else
            # No caret, use target_version as-is
            version_to_use="$target_version"
        fi
    else
        # No target_version, check for min_version (fallback)
        min_version=$(echo "$pkg_entry" | yq eval -r '.value.brew.min_version // .value.min_version // .value.brew_min_version // ""')
        
        if [ -n "$min_version" ] && [ "$min_version" != "null" ]; then
            version_to_use="$min_version"
        fi
    fi
    
    if [ -n "$version_to_use" ]; then
        echo "cask \"${brew_name}@${version_to_use}\"" >> "$BREWFILE"
    else
        echo "cask \"$brew_name\"" >> "$BREWFILE"
    fi
done
echo "" >> "$BREWFILE"

# VS Code extensions
echo "# VS Code extensions (essential)" >> "$BREWFILE"
yq -r '.vscode_extensions[] | "vscode \"\(.)\""' "$PACKAGES_YAML" >> "$BREWFILE"

# Success message - use both log and echo
if command -v log_info &> /dev/null; then
    log_info "Brewfile generated from packages.yaml"
fi
echo "✓ Brewfile generated from packages.yaml"