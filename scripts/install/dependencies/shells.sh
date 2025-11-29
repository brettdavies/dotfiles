#!/usr/bin/env bash
# Shell checking and installation (zsh, bash)

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_SHELLS_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_SHELLS_LOADED=1

# Source common utilities
_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPS_DIR/common.sh"

# Function to install zsh
# Returns: 0 on success, 1 on failure
install_zsh() {
    install_package zsh || die "Failed to install zsh" 1
}

# Function to install bash shell (not version-specific)
# Returns: 0 on success, 1 on failure
install_bash_shell() {
    install_package bash || die "Failed to install bash" 1
}

# Function to check and optionally install zsh
# Returns: 0 if present or installed, 1 if missing
check_zsh() {
    if ! command -v zsh &> /dev/null; then
        if [ "${DRY_RUN:-false}" = true ]; then
            verbose_missing "zsh"
            return 1
        fi
        
        if [[ "${OS:-}" == "macos" ]]; then
            warn "zsh not found on macOS (unusual)"
            read -p "Install zsh? (y/N) " -n 1 -r
            echo
            log_info "User prompt: Install zsh? (response: $REPLY)"
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_zsh || return 1
            else
                warn "Skipping zsh installation. Shell configs may not work"
                return 1
            fi
        else
            # Linux
            echo -e "${YELLOW}zsh not found. Required for oh-my-zsh.${NC}"
            log_warn "zsh not found. Required for oh-my-zsh"
            read -p "Install zsh? (Y/n) " -n 1 -r
            echo
            log_info "User prompt: Install zsh? (response: $REPLY)"
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_zsh || return 1
            else
                echo -e "${YELLOW}Skipping zsh installation. oh-my-zsh and zsh configs will not be set up.${NC}"
                log_warn "Skipping zsh installation. oh-my-zsh and zsh configs will not be set up"
                return 1
            fi
        fi
    else
        verbose_found "zsh"
        return 0
    fi
}

# Function to check and optionally install bash shell
# Returns: 0 if present or installed, 1 if missing
check_bash_shell() {
    if ! command -v bash &> /dev/null; then
        if [ "${DRY_RUN:-false}" = true ]; then
            verbose_missing "bash"
            return 1
        fi
        
        warn "bash not found"
        read -p "Install bash? (Y/n) " -n 1 -r
        echo
        log_info "User prompt: Install bash? (response: $REPLY)"
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            install_bash_shell || return 1
        else
            warn "Skipping bash installation. Bash configs will not be set up"
            return 1
        fi
    else
        verbose_found "bash"
        return 0
    fi
}

# Check for required shells
check_shells() {
    local missing_zsh=false
    local missing_bash=false
    
    if [[ "${OS:-}" == "macos" ]]; then
        # macOS usually has zsh pre-installed, but check anyway
        if ! check_zsh; then
            missing_zsh=true
        fi
    elif [[ "${OS:-}" == "linux" ]]; then
        # On Linux, check for zsh (required for oh-my-zsh)
        if ! check_zsh; then
            missing_zsh=true
        fi
        
        # bash is usually installed, but check
        if ! check_bash_shell; then
            missing_bash=true
        fi
    fi
    
    # Return count of missing shells
    local missing_count=0
    [ "$missing_zsh" = true ] && ((missing_count++))
    [ "$missing_bash" = true ] && ((missing_count++))
    return $missing_count
}

