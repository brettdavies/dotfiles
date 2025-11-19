#!/bin/bash
# Simple test script for Docker

set -e

echo "=== Testing dotfiles install script ==="
echo ""

# Install prerequisites (curl/wget for oh-my-zsh installer)
if command -v apk &> /dev/null; then
    # Alpine Linux
    apk add --no-cache git curl bash > /dev/null 2>&1
elif command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update > /dev/null 2>&1
    apt-get install -y git curl bash > /dev/null 2>&1
else
    echo "Unknown package manager, skipping prerequisite installation"
fi

# Test the install script (non-interactive mode - answer yes to shell installations)
cd /root/dotfiles
echo "Running install.sh (non-interactive)..."
printf "y\ny\nn\n" | bash install.sh || true

echo ""
echo "=== Test Results ==="
echo ""
echo "Checking for symlinks:"
ls -la ~ | grep -E "^l.*\.(zshrc|gitconfig|bashrc|p10k)" || echo "No expected symlinks found"

echo ""
echo "Checking .secrets file:"
if [ -f ~/.secrets ]; then
    echo "✓ .secrets exists"
    ls -la ~/.secrets
else
    echo "✗ .secrets not found"
fi

echo ""
echo "Checking oh-my-zsh installation:"
if [ -d ~/.oh-my-zsh ]; then
    echo "✓ oh-my-zsh installed"
else
    echo "✗ oh-my-zsh not installed"
fi

echo ""
echo "Checking shells:"
command -v zsh && echo "✓ zsh installed" || echo "✗ zsh not installed"
command -v bash && echo "✓ bash installed" || echo "✗ bash not installed"

echo ""
echo "All symlinks in home directory:"
find ~ -maxdepth 1 -type l 2>/dev/null | head -10 || echo "No symlinks found"

