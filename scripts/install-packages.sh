#!/bin/bash
# Install packages from Brewfile (optional)
# On macOS: Uses Homebrew
# On Linux: Uses system package manager (apt/yum/dnf/apk)
#
# NOTE: This script contains one exception where manual symlinks are created
# (oh-my-zsh plugins/themes from brew packages). See comments in code for details.

set -euo pipefail

# Source shared libraries
source "$(dirname "$0")/lib-core.sh"
source "$(dirname "$0")/lib-packages.sh"

# Parse arguments
parse_common_args "$@"

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

# Check if a tap is installed
# Returns: 0 if installed, 1 if not
check_tap_installed() {
    local tap="$1"
    brew tap | grep -q "^$tap"
}

# Check if a package is installed
# Returns: 0 if installed, 1 if not
check_package_installed() {
    local pkg="$1"
    brew list "$pkg" &>/dev/null 2>&1
}

# Check if a cask is installed
# Returns: 0 if installed, 1 if not
check_cask_installed() {
    local cask="$1"
    brew list --cask "$cask" &>/dev/null 2>&1
}

# Check if a VS Code extension is installed
# Returns: 0 if installed, 1 if not
check_vscode_extension_installed() {
    local ext="$1"
    if ! command -v code &> /dev/null; then
        return 1
    fi
    code --list-extensions 2>/dev/null | grep -q "^${ext}$"
}

# Check tap status and return result
# Returns: "installed" or "missing" via echo (to stdout)
# Verbose output goes to fd 3 (stderr)
check_tap_status() {
    local tap="$1"
    if check_tap_installed "$tap"; then
        verbose_installed "Tap" "$tap" >&3
        echo "installed"
    else
        verbose_would_install "Tap" "$tap" >&3
        echo "missing"
    fi
}

# Check package status and return result
# Returns: "installed" or "missing" via echo (to stdout)
# Verbose output goes to fd 3 (stderr)
check_package_status() {
    local pkg="$1"
    
    # Handle tap/package format
    if [[ "$pkg" =~ / ]]; then
        local tap="${pkg%%/*}"
        if ! check_tap_installed "$tap/"; then
            verbose_would_install "Package" "$pkg (tap not installed)" >&3
            echo "missing"
            return
        fi
    fi
    
    if check_package_installed "$pkg"; then
        verbose_installed "Package" "$pkg" >&3
        echo "installed"
    else
        verbose_would_install "Package" "$pkg" >&3
        echo "missing"
    fi
}

# Check cask status and return result
# Returns: "installed" or "missing" via echo (to stdout)
# Verbose output goes to fd 3 (stderr)
check_cask_status() {
    local cask="$1"
    if check_cask_installed "$cask"; then
        verbose_installed "Cask" "$cask" >&3
        echo "installed"
    else
        verbose_would_install "Cask" "$cask" >&3
        echo "missing"
    fi
}

# Check VS Code extension status and return result
# Returns: "installed" or "missing" via echo (to stdout)
# Verbose output goes to fd 3 (stderr)
check_vscode_extension_status() {
    local ext="$1"
    if check_vscode_extension_installed "$ext"; then
        verbose_installed "VS Code extension" "$ext" >&3
        echo "installed"
    else
        if command -v code &> /dev/null; then
            verbose_would_install "VS Code extension" "$ext" >&3
        else
            verbose_would_install "VS Code extension" "$ext (code command not found)" >&3
        fi
        echo "missing"
    fi
}

# Parse and check a single Brewfile line
# Returns: "tap:installed", "tap:missing", "package:installed", etc. via echo (to stdout)
# Verbose output goes to fd 3 (stderr)
parse_brewfile_line() {
    local line="$1"
    
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && return 0
    [[ -z "${line// }" ]] && return 0
    
    if [[ "$line" =~ ^tap[[:space:]]+\"(.*)\" ]]; then
        local tap="${BASH_REMATCH[1]}"
        [[ -n "$tap" ]] && echo "tap:$(check_tap_status "$tap" 2>&3)"
    elif [[ "$line" =~ ^brew[[:space:]]+\"(.*)\" ]]; then
        local pkg="${BASH_REMATCH[1]}"
        [[ -n "$pkg" ]] && echo "package:$(check_package_status "$pkg" 2>&3)"
    elif [[ "$line" =~ ^cask[[:space:]]+\"(.*)\" ]]; then
        local cask="${BASH_REMATCH[1]}"
        [[ -n "$cask" ]] && echo "cask:$(check_cask_status "$cask" 2>&3)"
    elif [[ "$line" =~ ^vscode[[:space:]]+\"(.*)\" ]]; then
        local ext="${BASH_REMATCH[1]}"
        [[ -n "$ext" ]] && echo "extension:$(check_vscode_extension_status "$ext" 2>&3)"
    fi
}

# Check Cursor extensions status
# Returns: count of missing extensions via echo (to stdout)
# Verbose output goes to original stderr (fd 3) to avoid interfering with return value
check_cursor_extensions() {
    local missing_count=0
    local cursor_ext_file="$STOW_DIR/cursor/extensions.txt"
    [ ! -f "$cursor_ext_file" ] && echo "0" && return 0
    
    local cursor_cmd
    cursor_cmd=$(get_cursor_command)
    [ -z "$cursor_cmd" ] && echo "0" && return 0
    
    local installed_exts
    installed_exts=$("$cursor_cmd" --list-extensions 2>/dev/null || echo "")
    
    while IFS= read -r extension || [ -n "$extension" ]; do
        [[ "$extension" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${extension// }" ]] && continue
        
        extension=$(echo "$extension" | xargs)
        [[ -z "$extension" ]] && continue
        
        if echo "$installed_exts" | grep -q "^${extension}$"; then
            verbose_installed "Cursor extension" "$extension" >&3
        else
            ((missing_count++))
            verbose_would_install "Cursor extension" "$extension" >&3
        fi
    done < "$cursor_ext_file"
    
    echo "$missing_count"
}

# Check package status from Brewfile (for dry-run)
check_brewfile_packages() {
    local installed_count=0
    local missing_count=0
    local installed_taps=0
    local missing_taps=0
    local installed_casks=0
    local missing_casks=0
    local installed_exts=0
    local missing_exts=0
    
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}Homebrew not found${NC}"
        return 0
    fi
    
    # Save stderr to fd 3, redirect verbose output there
    exec 3>&2
    
    # Parse Brewfile
    while IFS= read -r line || [ -n "$line" ]; do
        local result
        result=$(parse_brewfile_line "$line" 2>&3)
        [[ -z "$result" ]] && continue
        
        case "$result" in
            tap:installed) ((installed_taps++)) ;;
            tap:missing) ((missing_taps++)) ;;
            package:installed) ((installed_count++)) ;;
            package:missing) ((missing_count++)) ;;
            cask:installed) ((installed_casks++)) ;;
            cask:missing) ((missing_casks++)) ;;
            extension:installed) ((installed_exts++)) ;;
            extension:missing) ((missing_exts++)) ;;
        esac
    done < "$STOW_DIR/brew/Brewfile"
    
    # Check Cursor extensions separately
    # Note: verbose output from check_cursor_extensions goes to fd 3 (stderr)
    local cursor_missing
    cursor_missing=$(check_cursor_extensions 2>&3)
    missing_exts=$((missing_exts + cursor_missing))
    
    # Close fd 3
    exec 3>&-
    
    # Summary
    local total_installed=$((installed_taps + installed_count + installed_casks + installed_exts))
    local total_missing=$((missing_taps + missing_count + missing_casks + missing_exts))
    
    echo -e "${GREEN}[DRY RUN] $total_installed packages already installed, $total_missing packages would be installed${NC}"
    if [ "$VERBOSE" != true ]; then
        echo -e "${GREEN}  (Use --verbose to see details)${NC}"
    fi
}

# Install packages on macOS
install_macos_packages() {
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    if ! command -v brew &> /dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${RED}[DRY RUN] Homebrew not found${NC}"
        else
            echo -e "${RED}Homebrew not found, skipping package installation${NC}"
        fi
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Checking packages from Brewfile...${NC}"
        check_brewfile_packages
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
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Linux package installation would be attempted${NC}"
        echo -e "${YELLOW}[DRY RUN] Note: Linux package mapping from Brewfile is approximate${NC}"
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

