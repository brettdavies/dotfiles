#!/usr/bin/env bash
# Check and install required dependencies (stow, shells, oh-my-zsh)

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/standard.sh"

# Parse arguments
parse_common_args "$@"

¬# Setup trap handlers for cleanup and error handling
# Initialize temporary directory for this script execution
init_temp_dir "check-dependencies.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Function to ensure Homebrew paths are in PATH (macOS only)
# This must be done early so we can find Homebrew-installed bash
ensure_homebrew_path() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi
    
    # Check for Homebrew in standard locations and add to PATH if found
    if [ -d "/opt/homebrew/bin" ]; then
        # Apple Silicon Macs
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
    elif [ -d "/usr/local/bin" ]; then
        # Legacy Homebrew location (Intel Macs)
        export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
    fi
}

# Function to get bash version from a bash executable
# Parameters: $1 - path to bash executable (default: "bash")
# Returns: version string (e.g., "5.2.0") or empty string if not found
get_bash_version() {
    local bash_path="${1:-bash}"
    if ! command -v "$bash_path" &> /dev/null; then
        echo ""
        return
    fi
    
    # Extract version from "GNU bash, version X.Y.Z" output
    local version_output
    version_output=$("$bash_path" --version 2>/dev/null | head -n1)
    
    # Match version pattern (e.g., "5.2.0" or "5.2")
    if [[ "$version_output" =~ version[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Function to compare version strings
# Parameters: $1 - version to check, $2 - minimum version (e.g., "5.2")
# Returns: 0 if version >= minimum, 1 otherwise
version_ge() {
    local version="$1"
    local min_version="$2"
    
    # Split versions into arrays
    IFS='.' read -ra version_parts <<< "$version"
    IFS='.' read -ra min_parts <<< "$min_version"
    
    # Compare major version
    if [ "${version_parts[0]}" -gt "${min_parts[0]}" ]; then
        return 0
    elif [ "${version_parts[0]}" -lt "${min_parts[0]}" ]; then
        return 1
    fi
    
    # Major version equal, check minor
    if [ "${version_parts[1]:-0}" -gt "${min_parts[1]:-0}" ]; then
        return 0
    elif [ "${version_parts[1]:-0}" -lt "${min_parts[1]:-0}" ]; then
        return 1
    fi
    
    # Minor version equal, check patch if both have it
    if [ -n "${version_parts[2]:-}" ] && [ -n "${min_parts[2]:-}" ]; then
        if [ "${version_parts[2]}" -ge "${min_parts[2]}" ]; then
            return 0
        else
            return 1
        fi
    fi
    
    # If we get here, versions are equal at the compared level
    return 0
}

# Function to check bash version and install/upgrade if needed
# Requires bash 5.2+ for standardization
check_bash_version() {
    local min_version="5.2"
    local bash_path=""
    local current_version=""
    
    # Ensure Homebrew paths are in PATH first (macOS)
    ensure_homebrew_path
    
    # Find bash executable
    if [[ "$OS" == "macos" ]]; then
        # On macOS, prefer Homebrew bash if available
        if command -v brew &> /dev/null; then
            # Check Homebrew bash first
            local brew_bash
            brew_bash="$(brew --prefix)/bin/bash"
            if [ -x "$brew_bash" ]; then
                bash_path="$brew_bash"
                current_version=$(get_bash_version "$bash_path")
            fi
        fi
        
        # If Homebrew bash not found or version check failed, check system bash
        if [ -z "$current_version" ]; then
            bash_path="/bin/bash"
            current_version=$(get_bash_version "$bash_path")
        fi
    else
        # On Linux, use system bash
        bash_path="bash"
        current_version=$(get_bash_version "$bash_path")
    fi
    
    # Check if we have a valid version
    if [ -z "$current_version" ]; then
        if [ "$DRY_RUN" = true ]; then
            verbose_missing "bash" "version check failed"
            return 1
        else
            warn "Could not determine bash version"
            return 1
        fi
    fi
    
    # Check if version meets minimum requirement
    if version_ge "$current_version" "$min_version"; then
        if [ "$VERBOSE" = true ]; then
            verbose_found "bash" "version $current_version (>= $min_version)"
        elif [ "$DRY_RUN" != true ]; then
            log_info "bash version $current_version found (meets requirement >= $min_version)"
        fi
        return 0
    fi
    
    # Version is too old, need to install/upgrade
    if [ "$DRY_RUN" = true ]; then
        verbose_missing "bash" "version $current_version (requires >= $min_version)"
        return 1
    fi
    
    # Install/upgrade bash
    log_info "bash version $current_version found, but requires >= $min_version. Installing/upgrading..."
    
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &> /dev/null; then
            err "Homebrew not found. Please install Homebrew first, or install bash 5.2+ manually" 1
            return 1
        fi
        brew install bash || die "Failed to install/upgrade bash via Homebrew" 1
        
        # Verify the new version
        local new_bash
        new_bash="$(brew --prefix)/bin/bash"
        local new_version
        new_version=$(get_bash_version "$new_bash")
        if [ -n "$new_version" ] && version_ge "$new_version" "$min_version"; then
            log_info "bash upgraded to version $new_version"
        else
            warn "bash was installed but version check failed. Please verify manually."
        fi
    else
        # On Linux, install via package manager
        install_package bash || die "Failed to install/upgrade bash" 1
        
        # Verify the new version
        local new_version
        new_version=$(get_bash_version "bash")
        if [ -n "$new_version" ] && version_ge "$new_version" "$min_version"; then
            log_info "bash upgraded to version $new_version"
        else
            warn "bash was installed but version check failed. Please verify manually."
        fi
    fi
    
    return 0
}

# Function to install package using system package manager
install_package() {
    local package=$1
    
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install "$package"
        else
            err "Homebrew not found. Please install $package manually" 1
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
            err "Package manager not found. Please install $package manually" 1
            return 1
        fi
    else
        err "Unsupported OS. Please install $package manually" 1
        return 1
    fi
}

# Check for GNU Stow
check_stow() {
    if ! command -v stow &> /dev/null; then
        if [ "$DRY_RUN" = true ]; then
            verbose_missing "GNU Stow"
            return 1  # Missing
        else
            log_info "GNU Stow not found. Installing..."
            install_package stow || die "Failed to install GNU Stow" 1
        fi
    else
        if [ "$VERBOSE" = true ]; then
            verbose_found "GNU Stow"
        elif [ "$DRY_RUN" != true ]; then
            log_info "GNU Stow found"
        fi
        return 0  # Found
    fi
}

# Check for required shells
check_shells() {
    local missing_zsh=false
    local missing_bash=false
    
    if [[ "$OS" == "macos" ]]; then
        # macOS usually has zsh pre-installed, but check anyway
        if ! command -v zsh &> /dev/null; then
            missing_zsh=true
            if [ "$DRY_RUN" = true ]; then
                verbose_missing "zsh"
            else
                warn "zsh not found on macOS (unusual)"
                read -p "Install zsh? (y/N) " -n 1 -r
                echo
                log_info "User prompt: Install zsh? (response: $REPLY)"
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    install_package zsh || die "Failed to install zsh" 1
                else
                    warn "Skipping zsh installation. Shell configs may not work"
                fi
            fi
        else
            verbose_found "zsh"
        fi
    elif [[ "$OS" == "linux" ]]; then
        # On Linux, check for zsh (required for oh-my-zsh)
        if ! command -v zsh &> /dev/null; then
            missing_zsh=true
            if [ "$DRY_RUN" = true ]; then
                verbose_missing "zsh"
            else
                echo -e "${YELLOW}zsh not found. Required for oh-my-zsh.${NC}"
            log_warn "zsh not found. Required for oh-my-zsh"
                read -p "Install zsh? (Y/n) " -n 1 -r
                echo
            log_info "User prompt: Install zsh? (response: $REPLY)"
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    install_package zsh || exit 1
                else
                    echo -e "${YELLOW}Skipping zsh installation. oh-my-zsh and zsh configs will not be set up.${NC}"
                log_warn "Skipping zsh installation. oh-my-zsh and zsh configs will not be set up"
                fi
            fi
        else
            verbose_found "zsh"
        fi
        
        # bash is usually installed, but check
        if ! command -v bash &> /dev/null; then
            missing_bash=true
            if [ "$DRY_RUN" = true ]; then
                verbose_missing "bash"
            else
                warn "bash not found"
                read -p "Install bash? (Y/n) " -n 1 -r
                echo
                log_info "User prompt: Install bash? (response: $REPLY)"
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    install_package bash || die "Failed to install bash" 1
                else
                    warn "Skipping bash installation. Bash configs will not be set up"
                fi
            fi
        else
            verbose_found "bash"
        fi
    fi
    
    # Return count of missing shells
    local missing_count=0
    [ "$missing_zsh" = true ] && ((missing_count++))
    [ "$missing_bash" = true ] && ((missing_count++))
    return $missing_count
}

# Install oh-my-zsh if not present
check_oh_my_zsh() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        if command -v zsh &> /dev/null; then
            if [ "$DRY_RUN" = true ]; then
                verbose_missing "oh-my-zsh"
                return 1  # Missing
            else
                log_info "oh-my-zsh not found. Installing..."
                if command -v curl &> /dev/null; then
                    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || die "Failed to install oh-my-zsh" 1
                elif command -v wget &> /dev/null; then
                    sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" "" --unattended || die "Failed to install oh-my-zsh" 1
                else
                    die "curl or wget required to install oh-my-zsh" 1
                fi
            fi
        else
            if [ "$DRY_RUN" = true ]; then
                verbose_missing "oh-my-zsh" "cannot install (zsh not found)"
            else
                warn "zsh not installed. Skipping oh-my-zsh installation"
                warn "Install zsh first if you want oh-my-zsh"
            fi
            return 1  # Missing
        fi
    else
        if [ "$VERBOSE" = true ]; then
            verbose_found "oh-my-zsh"
        elif [ "$DRY_RUN" != true ]; then
            log_info "oh-my-zsh found"
        fi
        return 0  # Found
    fi
}

# Main execution
if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Checking dependencies..."
else
        log_info "Checking dependencies..."
fi

MISSING_COUNT=0

# Check bash version FIRST (must be 5.2+)
# This ensures all subsequent scripts can use modern bash features
if ! check_bash_version; then
    ((MISSING_COUNT++))
fi

# Check stow
if ! check_stow; then
    ((MISSING_COUNT++))
fi

# Check shells
check_shells
SHELL_MISSING=$?
MISSING_COUNT=$((MISSING_COUNT + SHELL_MISSING))

# Check oh-my-zsh
if ! check_oh_my_zsh; then
    ((MISSING_COUNT++))
fi

# Summary for dry-run
if [ "$DRY_RUN" = true ]; then
    if [ $MISSING_COUNT -eq 0 ]; then
        log_info "[DRY RUN] All dependencies satisfied"
    else
        log_info "[DRY RUN] Would install $MISSING_COUNT missing dependencies"
    fi
else
    if [ $MISSING_COUNT -eq 0 ]; then
        log_info "All dependencies satisfied"
    fi
fi

