#!/bin/bash
# Install packages from Brewfile (optional)
# On macOS: Uses Homebrew
# On Linux: Uses system package manager (apt/yum/dnf/apk)
#
# NOTE: This script contains one exception where manual symlinks are created
# (oh-my-zsh plugins/themes from brew packages). See comments in code for details.

set -e

# Source shared library
source "$(dirname "$0")/lib.sh"

# Function to install packages based on package manager
install_packages_via_pm() {
    local packages=$1
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        if [ "$EUID" -eq 0 ]; then
            apt-get update && apt-get install -y $packages
        else
            sudo apt-get update && sudo apt-get install -y $packages
        fi
    elif command -v yum &> /dev/null; then
        # RHEL/CentOS
        if [ "$EUID" -eq 0 ]; then
            yum install -y $packages
        else
            sudo yum install -y $packages
        fi
    elif command -v dnf &> /dev/null; then
        # Fedora
        if [ "$EUID" -eq 0 ]; then
            dnf install -y $packages
        else
            sudo dnf install -y $packages
        fi
    elif command -v apk &> /dev/null; then
        # Alpine
        apk add --no-cache $packages
    else
        echo -e "${RED}No supported package manager found${NC}"
        return 1
    fi
}

# Install packages on macOS
install_macos_packages() {
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}Homebrew not found, skipping package installation${NC}"
        return 0
    fi
    
    echo ""
    read -p "Install packages from Brewfile? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Skipping package installation${NC}"
        return 0
    fi
    
    echo -e "${GREEN}Installing packages via Homebrew...${NC}"
    brew bundle --file="$STOW_DIR/brew/Brewfile"
    
    # Ask about optional packages
    if [ -f "$STOW_DIR/brew/Brewfile.optional" ]; then
        echo ""
        read -p "Install optional packages from Brewfile.optional? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Installing optional packages...${NC}"
            brew bundle --file="$STOW_DIR/brew/Brewfile.optional"
        fi
    fi
    
    # EXCEPTION: Manual symlink creation for oh-my-zsh plugins/themes from brew packages
    # These are external packages installed by Homebrew (not part of our stow structure),
    # so we manually create symlinks from $(brew --prefix)/share to ~/.oh-my-zsh/custom/
    # This is a valid exception because:
    # 1. These packages are installed by brew, not managed in our stow directory
    # 2. They need to be linked to oh-my-zsh's custom directory structure
    # 3. Stow cannot manage symlinks to external package locations
    echo "  - Setting up oh-my-zsh plugin/theme symlinks"
    OH_MY_ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
    BREW_SHARE="$(brew --prefix)/share"
    
    # Create symlinks for plugins
    mkdir -p "$OH_MY_ZSH_CUSTOM/plugins"
    for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
        if [ -d "$BREW_SHARE/$plugin" ]; then
            ln -sf "$BREW_SHARE/$plugin" "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
            echo "    Linked plugin: $plugin"
        fi
    done
    
    # Create symlinks for themes
    mkdir -p "$OH_MY_ZSH_CUSTOM/themes"
    for theme in powerlevel10k; do
        if [ -d "$BREW_SHARE/$theme" ]; then
            ln -sf "$BREW_SHARE/$theme" "$OH_MY_ZSH_CUSTOM/themes/$theme" 2>/dev/null || true
            echo "    Linked theme: $theme"
        fi
    done
    
    # Install Cursor extensions (if Cursor is installed and extensions.txt exists)
    if command -v cursor &> /dev/null || [ -f "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
        CURSOR_CMD=""
        if command -v cursor &> /dev/null; then
            CURSOR_CMD="cursor"
        elif [ -f "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
            CURSOR_CMD="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        fi
        
        CURSOR_EXTENSIONS_FILE="$STOW_DIR/cursor/extensions.txt"
        if [ -n "$CURSOR_CMD" ] && [ -f "$CURSOR_EXTENSIONS_FILE" ]; then
            echo "  - Installing Cursor extensions"
            while IFS= read -r extension || [ -n "$extension" ]; do
                # Skip empty lines and comments
                if [[ -n "$extension" && ! "$extension" =~ ^[[:space:]]*# ]]; then
                    # Remove leading/trailing whitespace
                    extension=$(echo "$extension" | xargs)
                    if [[ -n "$extension" ]]; then
                        echo "    Installing: $extension"
                        "$CURSOR_CMD" --install-extension "$extension" 2>/dev/null || true
                    fi
                fi
            done < "$CURSOR_EXTENSIONS_FILE"
        fi
    fi
}

# Install packages on Linux
install_linux_packages_from_brewfile() {
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    echo ""
    read -p "Install packages from Brewfile? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Skipping package installation${NC}"
        return 0
    fi
    
    echo -e "${GREEN}Installing packages via Linux package manager...${NC}"
    
    # Install basic utilities (available in most package managers)
    install_packages_via_pm "ripgrep jq tree wget coreutils" || true
    
    # Install PostgreSQL client (libpq equivalent)
    if command -v apt-get &> /dev/null; then
        install_packages_via_pm "postgresql-client libpq-dev" || true
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        install_packages_via_pm "postgresql postgresql-devel" || true
    elif command -v apk &> /dev/null; then
        install_packages_via_pm "postgresql-client postgresql-dev" || true
    fi
    
    # Install yamllint (Python-based, may need pip)
    if command -v pip3 &> /dev/null || command -v pip &> /dev/null; then
        pip3 install --user yamllint 2>/dev/null || pip install --user yamllint 2>/dev/null || true
    fi
    
    # Install GitHub CLI (gh) - may need manual installation or repo setup
    if ! command -v gh &> /dev/null; then
        echo -e "${YELLOW}GitHub CLI (gh) not found. Install manually from: https://github.com/cli/cli/blob/trunk/docs/install_linux.md${NC}"
    fi
    
    # Install bun (recommended: use official installer)
    if ! command -v bun &> /dev/null; then
        echo -e "${YELLOW}Installing bun...${NC}"
        curl -fsSL https://bun.sh/install | bash || true
    fi
    
    # Install uv (Python package installer)
    if ! command -v uv &> /dev/null; then
        echo -e "${YELLOW}Installing uv...${NC}"
        curl -LsSf https://astral.sh/uv/install.sh | sh || true
    fi
    
    # Install ast-grep (may need manual installation)
    if ! command -v ast-grep &> /dev/null; then
        echo -e "${YELLOW}ast-grep not found. Install manually from: https://github.com/ast-grep/ast-grep${NC}"
    fi
    
    # Install oh-my-zsh plugins and themes via git
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo "  - Setting up oh-my-zsh plugins and themes"
        OH_MY_ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
        mkdir -p "$OH_MY_ZSH_CUSTOM/plugins" "$OH_MY_ZSH_CUSTOM/themes"
        
        # Install powerlevel10k theme
        if [ ! -d "$OH_MY_ZSH_CUSTOM/themes/powerlevel10k" ]; then
            git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$OH_MY_ZSH_CUSTOM/themes/powerlevel10k" 2>/dev/null || true
            echo "    Installed theme: powerlevel10k"
        fi
        
        # Install plugins
        for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
            if [ ! -d "$OH_MY_ZSH_CUSTOM/plugins/$plugin" ]; then
                case $plugin in
                    zsh-autosuggestions)
                        git clone https://github.com/zsh-users/zsh-autosuggestions "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
                        ;;
                    zsh-syntax-highlighting)
                        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
                        ;;
                    zsh-completions)
                        git clone https://github.com/zsh-users/zsh-completions "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
                        ;;
                esac
                echo "    Installed plugin: $plugin"
            fi
        done
    fi
    
    echo -e "${GREEN}Linux package installation complete${NC}"
}

# Main execution
if [[ "$OS" == "macos" ]]; then
    install_macos_packages
elif [[ "$OS" == "linux" ]]; then
    install_linux_packages_from_brewfile
fi

