#!/bin/bash
# Check and install required dependencies (stow, shells, oh-my-zsh)

set -e

# Source shared library
source "$(dirname "$0")/lib.sh"

# Function to install package using system package manager
install_package() {
    local package=$1
    
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install "$package"
        else
            echo -e "${RED}Error: Homebrew not found. Please install $package manually.${NC}"
            return 1
        fi
    elif [[ "$OS" == "linux" ]]; then
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
            echo -e "${RED}Error: Package manager not found. Please install $package manually.${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: Unsupported OS. Please install $package manually.${NC}"
        return 1
    fi
}

# Check for GNU Stow
check_stow() {
    if ! command -v stow &> /dev/null; then
        echo -e "${YELLOW}GNU Stow not found. Installing...${NC}"
        install_package stow || exit 1
    else
        echo -e "${GREEN}GNU Stow found${NC}"
    fi
}

# Check for required shells
check_shells() {
    if [[ "$OS" == "macos" ]]; then
        # macOS usually has zsh pre-installed, but check anyway
        if ! command -v zsh &> /dev/null; then
            echo -e "${YELLOW}zsh not found on macOS (unusual).${NC}"
            read -p "Install zsh? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_package zsh || exit 1
            else
                echo -e "${YELLOW}Skipping zsh installation. Shell configs may not work.${NC}"
            fi
        fi
    elif [[ "$OS" == "linux" ]]; then
        # On Linux, check for zsh (required for oh-my-zsh)
        if ! command -v zsh &> /dev/null; then
            echo -e "${YELLOW}zsh not found. Required for oh-my-zsh.${NC}"
            read -p "Install zsh? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_package zsh || exit 1
            else
                echo -e "${YELLOW}Skipping zsh installation. oh-my-zsh and zsh configs will not be set up.${NC}"
            fi
        fi
        
        # bash is usually installed, but check
        if ! command -v bash &> /dev/null; then
            echo -e "${YELLOW}bash not found.${NC}"
            read -p "Install bash? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_package bash || exit 1
            else
                echo -e "${YELLOW}Skipping bash installation. Bash configs will not be set up.${NC}"
            fi
        fi
    fi
}

# Install oh-my-zsh if not present
check_oh_my_zsh() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        if command -v zsh &> /dev/null; then
            echo -e "${YELLOW}oh-my-zsh not found. Installing...${NC}"
            if command -v curl &> /dev/null; then
                sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
            elif command -v wget &> /dev/null; then
                sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" "" --unattended
            else
                echo -e "${RED}Error: curl or wget required to install oh-my-zsh${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}zsh not installed. Skipping oh-my-zsh installation.${NC}"
            echo -e "${YELLOW}Install zsh first if you want oh-my-zsh.${NC}"
        fi
    else
        echo -e "${GREEN}oh-my-zsh found${NC}"
    fi
}

# Main execution
echo -e "${GREEN}Checking dependencies...${NC}"
check_stow
check_shells
check_oh_my_zsh

