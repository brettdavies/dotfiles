#!/usr/bin/env bash
# Install packages from Brewfile (optional)
# On macOS: Uses Homebrew
# On Linux: Uses system package manager (apt/yum/dnf/apk)
#
# NOTE: This script contains one exception where manual symlinks are created
# (oh-my-zsh plugins/themes from brew packages). See comments in code for details.

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/packages.sh"

# Parse arguments
parse_common_args "$@"

# Setup trap handlers for cleanup and error handling
# Initialize temporary directory for this script execution
init_temp_dir "install-packages.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Initialize package status cache for performance
init_package_cache

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
        err "No supported package manager found" 1
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
    
    # Extract package name (remove version pinning, e.g., "package@1.0.0" -> "package")
    local pkg_name="${pkg%%@*}"
    
    # Handle tap/package format
    if [[ "$pkg_name" =~ / ]]; then
        local tap="${pkg_name%%/*}"
        if ! check_tap_installed "$tap/"; then
            verbose_would_install "Package" "$pkg (tap not installed)" >&3
            echo "missing"
            return
        fi
    fi
    
    if check_package_installed "$pkg_name"; then
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
    
    # Extract cask name (remove version pinning, e.g., "cask@1.0.0" -> "cask")
    local cask_name="${cask%%@*}"
    
    if check_cask_installed "$cask_name"; then
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

# Validate installed package version against constraints from packages.yaml
# Parameters: $1 - package/cask name, $2 - platform (brew, linux, etc.)
# Outputs validation messages to stderr
validate_installed_package_version() {
    local pkg_name="$1"
    local platform="${2:-brew}"
    
    # Get version constraints from packages.yaml
    get_package_version_constraints "$pkg_name" "$platform" || return 0
    
    # If no constraints, nothing to validate
    if [ -z "$PACKAGE_MIN_VERSION" ] && [ -z "$PACKAGE_MAX_VERSION" ]; then
        return 0
    fi
    
    # Get installed version
    local installed_version
    if [ "$platform" = "brew" ]; then
        # Try as package first, then as cask
        installed_version=$(get_brew_package_version "$pkg_name" 2>/dev/null || get_brew_cask_version "$pkg_name" 2>/dev/null || echo "")
    fi
    
    if [ -z "$installed_version" ]; then
        # Package not installed, can't validate
        return 0
    fi
    
    # Validate version (use exclusive max if it came from caret expansion)
    local max_exclusive="false"
    if [ "${PACKAGE_MAX_VERSION_EXCLUSIVE:-false}" = "true" ]; then
        max_exclusive="true"
    fi
    if ! validate_package_version "$installed_version" "$PACKAGE_MIN_VERSION" "$PACKAGE_MAX_VERSION" "$max_exclusive"; then
        local constraint_msg=""
        if [ -n "$PACKAGE_MIN_VERSION" ] && [ -n "$PACKAGE_MAX_VERSION" ]; then
            constraint_msg=" (requires >= $PACKAGE_MIN_VERSION, <= $PACKAGE_MAX_VERSION)"
        elif [ -n "$PACKAGE_MIN_VERSION" ]; then
            constraint_msg=" (requires >= $PACKAGE_MIN_VERSION)"
        elif [ -n "$PACKAGE_MAX_VERSION" ]; then
            constraint_msg=" (requires <= $PACKAGE_MAX_VERSION)"
        fi
        log_warn "Package $pkg_name version $installed_version does not meet constraints$constraint_msg" >&3
        return 1
    fi
    
    return 0
}

# Validate all packages from packages.yaml after installation
validate_all_package_versions() {
    local packages_yaml="${STOW_DIR:-}/brew/packages.yaml"
    
    if [ ! -f "$packages_yaml" ] || ! command -v yq &> /dev/null; then
        return 0
    fi
    
    log_info "Validating package versions..."
    local validation_errors=0
    
    # Validate packages
    local package_keys
    readarray -t package_keys < <(yq -r '.packages | keys[]' "$packages_yaml" 2>/dev/null || true)
    
    for pkg_key in "${package_keys[@]}"; do
        # Skip if package doesn't have brew field
        local brew_name
        brew_name=$(yq -r ".packages.\"$pkg_key\".brew // empty" "$packages_yaml" 2>/dev/null || echo "")
        [ -z "$brew_name" ] && continue
        
        # Handle both string and object forms
        if [ "$brew_name" != "null" ] && [ -n "$brew_name" ]; then
            # Extract name if it's an object
            if yq -e ".packages.\"$pkg_key\".brew | type == \"object\"" "$packages_yaml" &>/dev/null; then
                brew_name=$(yq -r ".packages.\"$pkg_key\".brew.name // empty" "$packages_yaml" 2>/dev/null || echo "")
            fi
            
            if [ -n "$brew_name" ] && [ "$brew_name" != "null" ]; then
                if ! validate_installed_package_version "$pkg_key" "brew"; then
                    ((validation_errors++))
                fi
            fi
        fi
    done
    
    # Validate casks
    local cask_keys
    readarray -t cask_keys < <(yq -r '.casks | keys[]' "$packages_yaml" 2>/dev/null || true)
    
    for cask_key in "${cask_keys[@]}"; do
        local brew_name
        brew_name=$(yq -r ".casks.\"$cask_key\".brew // empty" "$packages_yaml" 2>/dev/null || echo "")
        [ -z "$brew_name" ] && continue
        
        # Handle both string and object forms
        if [ "$brew_name" != "null" ] && [ -n "$brew_name" ]; then
            if yq -e ".casks.\"$cask_key\".brew | type == \"object\"" "$packages_yaml" &>/dev/null; then
                brew_name=$(yq -r ".casks.\"$cask_key\".brew.name // empty" "$packages_yaml" 2>/dev/null || echo "")
            fi
            
            if [ -n "$brew_name" ] && [ "$brew_name" != "null" ]; then
                if ! validate_installed_package_version "$cask_key" "brew"; then
                    ((validation_errors++))
                fi
            fi
        fi
    done
    
    if [ "$validation_errors" -gt 0 ]; then
        log_warn "Found $validation_errors package(s) with version constraint violations"
        return 1
    else
        log_info "All package versions validated successfully"
        return 0
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
    
    local extensions_array
    readarray -t extensions_array < "$cursor_ext_file" 2>/dev/null || true
    for extension in "${extensions_array[@]}"; do
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
    done
    
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
        log_warn "Homebrew not found"
        return 0
    fi
    
    # Start progress tracking
    progress_start "Installing packages from Brewfile..."
    
    # Save stderr to fd 3, redirect verbose output there
    exec 3>&2
    
    # Parse Brewfile
    local brewfile_lines
    readarray -t brewfile_lines < "$STOW_DIR/brew/Brewfile" 2>/dev/null || true
    for line in "${brewfile_lines[@]}"; do
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
    done
    
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
    local total=$((total_installed + total_missing))
    
    # Update progress
    if [ "$total" -gt 0 ]; then
        local progress
        progress=$(calculate_progress "$total_installed" "$total")
        progress_update "$progress" "Checked $total_installed of $total packages"
    fi
    
    log_info "[DRY RUN] $total_installed packages already installed, $total_missing packages would be installed"
    if [ "$VERBOSE" != true ]; then
        echo "  (Use --verbose to see details)"
        log_info "(Use --verbose to see details)"
    fi
}

# Install packages on macOS
install_macos_packages() {
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    if ! command -v brew &> /dev/null; then
        if [ "$DRY_RUN" = true ]; then
            log_warn "[DRY RUN] Homebrew not found"
        else
            log_warn "Homebrew not found, skipping package installation"
        fi
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Checking packages from Brewfile..."
        check_brewfile_packages
        return 0
    fi
    
    echo ""
    read -p "Install packages from Brewfile? (y/N) " -n 1 -r
    echo
    log_info "User prompt: Install packages from Brewfile? (response: $REPLY)"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping package installation"
        return 0
    fi
    
    log_info "Installing packages via Homebrew..."
    progress_start "Installing packages from Brewfile..."
    brew bundle --file="$STOW_DIR/brew/Brewfile"
    progress_complete "Package installation complete"
    
    # Validate package versions after installation
    validate_all_package_versions || true
    
    # Ask about optional packages
    if [ -f "$STOW_DIR/brew/Brewfile.optional" ]; then
        echo ""
        read -p "Install optional packages from Brewfile.optional? (y/N) " -n 1 -r
        echo
        log_info "User prompt: Install optional packages from Brewfile.optional? (response: $REPLY)"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installing optional packages..."
            progress_start "Installing optional packages..."
            brew bundle --file="$STOW_DIR/brew/Brewfile.optional"
            progress_complete "Optional package installation complete"
        else
            log_info "Skipping optional package installation"
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
    log_info "Setting up oh-my-zsh plugin/theme symlinks"
    OH_MY_ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
    BREW_SHARE="$(brew --prefix)/share"
    
    # Create symlinks for plugins
    # Use safe_mkdir if available, otherwise fallback to mkdir
    if command -v safe_mkdir &> /dev/null; then
        safe_mkdir "$OH_MY_ZSH_CUSTOM/plugins" "-p" 2>/dev/null || true
    else
        mkdir -p "$OH_MY_ZSH_CUSTOM/plugins" 2>/dev/null || true
    fi
    for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
        if [ -d "$BREW_SHARE/$plugin" ]; then
            # Use safe_ln if available, otherwise fallback to ln
            if command -v safe_ln &> /dev/null; then
                safe_ln "-sf" "$BREW_SHARE/$plugin" "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
            else
                ln -sf "$BREW_SHARE/$plugin" "$OH_MY_ZSH_CUSTOM/plugins/$plugin" 2>/dev/null || true
            fi
            echo "    Linked plugin: $plugin"
            log_info "Linked plugin: $plugin"
        fi
    done
    
    # Create symlinks for themes
    # Use safe_mkdir if available, otherwise fallback to mkdir
    if command -v safe_mkdir &> /dev/null; then
        safe_mkdir "$OH_MY_ZSH_CUSTOM/themes" "-p" 2>/dev/null || true
    else
        mkdir -p "$OH_MY_ZSH_CUSTOM/themes" 2>/dev/null || true
    fi
    for theme in powerlevel10k; do
        if [ -d "$BREW_SHARE/$theme" ]; then
            # Use safe_ln if available, otherwise fallback to ln
            if command -v safe_ln &> /dev/null; then
                safe_ln "-sf" "$BREW_SHARE/$theme" "$OH_MY_ZSH_CUSTOM/themes/$theme" 2>/dev/null || true
            else
                ln -sf "$BREW_SHARE/$theme" "$OH_MY_ZSH_CUSTOM/themes/$theme" 2>/dev/null || true
            fi
            echo "    Linked theme: $theme"
            log_info "Linked theme: $theme"
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
            log_info "Installing Cursor extensions"
            local cursor_exts_array
            readarray -t cursor_exts_array < "$CURSOR_EXTENSIONS_FILE" 2>/dev/null || true
            for extension in "${cursor_exts_array[@]}"; do
                # Skip empty lines and comments
                if [[ -n "$extension" && ! "$extension" =~ ^[[:space:]]*# ]]; then
                    # Remove leading/trailing whitespace
                    extension=$(echo "$extension" | xargs)
                    if [[ -n "$extension" ]]; then
                        echo "    Installing: $extension"
                        log_info "Installing Cursor extension: $extension"
                        "$CURSOR_CMD" --install-extension "$extension" 2>/dev/null || true
                    fi
                fi
            done
        fi
    fi
}

# Install packages on Linux
install_linux_packages_from_brewfile() {
    if [ ! -f "$STOW_DIR/brew/Brewfile" ]; then
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Linux package installation would be attempted"
        log_info "[DRY RUN] Note: Linux package mapping from Brewfile is approximate"
        return 0
    fi
    
    echo ""
    read -p "Install packages from Brewfile? (y/N) " -n 1 -r
    echo
    log_info "User prompt: Install packages from Brewfile? (response: $REPLY)"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping package installation"
        return 0
    fi
    
    log_info "Installing packages via Linux package manager..."
    
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
        warn "GitHub CLI (gh) not found. Install manually from: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
    fi
    
    # Install bun (recommended: use official installer)
    if ! command -v bun &> /dev/null; then
        log_info "Installing bun..."
        curl -fsSL https://bun.sh/install | bash || true
    fi
    
    # Install uv (Python package installer)
    if ! command -v uv &> /dev/null; then
        log_info "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh || true
    fi
    
    # Install ast-grep (may need manual installation)
    if ! command -v ast-grep &> /dev/null; then
        warn "ast-grep not found. Install manually from: https://github.com/ast-grep/ast-grep"
    fi
    
    # Install oh-my-zsh plugins and themes via git
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo "  - Setting up oh-my-zsh plugins and themes"
        log_info "Setting up oh-my-zsh plugins and themes"
        OH_MY_ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
        # Use safe_mkdir if available, otherwise fallback to mkdir
        if command -v safe_mkdir &> /dev/null; then
            safe_mkdir "$OH_MY_ZSH_CUSTOM/plugins" "-p" 2>/dev/null || true
            safe_mkdir "$OH_MY_ZSH_CUSTOM/themes" "-p" 2>/dev/null || true
        else
            mkdir -p "$OH_MY_ZSH_CUSTOM/plugins" "$OH_MY_ZSH_CUSTOM/themes" 2>/dev/null || true
        fi
        
        # Install powerlevel10k theme
        if [ ! -d "$OH_MY_ZSH_CUSTOM/themes/powerlevel10k" ]; then
            git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$OH_MY_ZSH_CUSTOM/themes/powerlevel10k" 2>/dev/null || true
            echo "    Installed theme: powerlevel10k"
            log_info "Installed theme: powerlevel10k"
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
                log_info "Installed plugin: $plugin"
            fi
        done
    fi
    
    log_info "Linux package installation complete"
}

# Main execution
if [[ "$OS" == "macos" ]]; then
    install_macos_packages
elif [[ "$OS" == "linux" ]]; then
    install_linux_packages_from_brewfile
fi

