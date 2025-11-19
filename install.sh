#!/bin/bash
# Main dotfiles installation orchestrator
# Coordinates all installation steps

set -e

# Get the directory where this script is located
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"

# Source shared library
source "$SCRIPTS_DIR/lib.sh"

echo -e "${GREEN}Setting up dotfiles...${NC}"
echo -e "${GREEN}Detected OS: $OS${NC}"
echo ""

# Step 1: Check and install dependencies
"$SCRIPTS_DIR/check-dependencies.sh"

echo ""

# Step 2: Stow all packages
"$SCRIPTS_DIR/stow-packages.sh"

echo ""

# Step 3: Create .secrets file
"$SCRIPTS_DIR/create-secrets.sh"

echo ""

# Step 4: Create .lmstudio-home-pointer (if needed)
"$SCRIPTS_DIR/create-lmstudio-pointer.sh"

echo ""

# Step 5: Install packages from Brewfile (optional)
"$SCRIPTS_DIR/install-packages.sh"

echo ""
echo -e "${GREEN}✓ Dotfiles setup complete!${NC}"
echo ""
echo -e "${RED}Note: Do not commit secrets to this repository.${NC}"
