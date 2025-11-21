#!/bin/bash
# Test dotfiles installation in a Docker container
#
# This script is designed to run inside a Docker container to test the
# dotfiles installation process. It installs prerequisites, runs the
# installation script, and verifies that key components are set up correctly.
#
# Usage:
#   docker run -v /path/to/dotfiles:/root/dotfiles <image> /root/dotfiles/scripts/test-in-docker.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -e

# Source shared libraries
source "$(dirname "$0")/lib-core.sh"

echo -e "${GREEN}=== Testing dotfiles install script ===${NC}"
echo ""

# Install prerequisites (curl/wget for oh-my-zsh installer)
echo -e "${YELLOW}Installing prerequisites...${NC}"
if command -v apk &> /dev/null; then
    # Alpine Linux
    apk add --no-cache git curl bash > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Prerequisites installed (Alpine)${NC}"
elif command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update > /dev/null 2>&1
    apt-get install -y git curl bash > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Prerequisites installed (Debian/Ubuntu)${NC}"
else
    echo -e "${YELLOW}  ⚠ Unknown package manager, skipping prerequisite installation${NC}"
fi

# Test the install script (non-interactive mode - answer yes to shell installations)
cd /root/dotfiles
echo ""
echo -e "${GREEN}Running install.sh (non-interactive)...${NC}"
printf "y\ny\nn\n" | bash install.sh || true

echo ""
echo -e "${GREEN}=== Test Results ===${NC}"
echo ""

# Use check-implementation.sh to verify installation
# This script checks:
# - Dependencies (stow, shells, oh-my-zsh)
# - All stow package symlinks
# - .secrets file
# - Skips macOS-specific checks (Homebrew, VS Code, Cursor) on Linux
echo -e "${YELLOW}Running comprehensive implementation check...${NC}"
echo ""

# Run check-implementation.sh and capture exit code
if bash "$SCRIPTS_DIR/check-implementation.sh" --quiet; then
    echo ""
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi

