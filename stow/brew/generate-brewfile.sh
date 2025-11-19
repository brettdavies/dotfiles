#!/bin/bash
# Generate Brewfile from packages.yaml
# Run this after updating packages.yaml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_YAML="$SCRIPT_DIR/packages.yaml"
BREWFILE="$SCRIPT_DIR/Brewfile"

if [ ! -f "$PACKAGES_YAML" ]; then
    echo "Error: packages.yaml not found at $PACKAGES_YAML"
    exit 1
fi

# Check for yq, install if missing (macOS only)
if ! command -v yq &> /dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &> /dev/null; then
        echo "yq not found. Installing..."
        brew install yq
    else
        echo "Error: yq is required to generate Brewfile"
        echo "Install with: brew install yq (macOS) or from https://github.com/mikefarah/yq"
        exit 1
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

# oh-my-zsh theme
echo "# oh-my-zsh theme" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.value.linux.git != null and .value.linux.type == "theme") | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# oh-my-zsh plugins
echo "# oh-my-zsh plugins" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.value.linux.git != null and .value.linux.type == "plugin") | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# Development tools
echo "# Development tools" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.key == "bun" or .key == "uv" or .key == "gh" or .key == "libpq") | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# Code quality & utilities
echo "# Code quality & utilities" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.value.linux.pkg != null and .key != "bun" and .key != "uv" and .key != "gh" and .key != "libpq" and (.value.linux.git == null)) | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select((.value.linux.pip != null or .value.linux.installer != null) and .value.macos_only != true and .key != "bun" and .key != "uv" and .key != "gh" and (.value.linux.git == null)) | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# macOS-specific utilities
echo "# macOS-specific utilities" >> "$BREWFILE"
yq -r '.packages | to_entries[] | select(.value.macos_only == true) | "brew \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# macOS casks
echo "# macOS casks" >> "$BREWFILE"
yq -r '.casks | to_entries[] | select(.value.macos_only == true) | "cask \"\(.value.brew)\""' "$PACKAGES_YAML" >> "$BREWFILE"
echo "" >> "$BREWFILE"

# VS Code extensions
echo "# VS Code extensions (essential)" >> "$BREWFILE"
yq -r '.vscode_extensions[] | "vscode \"\(.)\""' "$PACKAGES_YAML" >> "$BREWFILE"

echo "✓ Brewfile generated from packages.yaml"