#!/usr/bin/env bash
# oh-my-zsh checking and installation

# Prevent re-sourcing
if [ -n "${DEPENDENCIES_OH_MY_ZSH_LOADED:-}" ]; then
    return 0
fi
export DEPENDENCIES_OH_MY_ZSH_LOADED=1

# Source common utilities
_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPS_DIR/common.sh"

# Function to install oh-my-zsh
# Returns: 0 on success, 1 on failure
install_oh_my_zsh() {
    if command -v curl &> /dev/null; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || die "Failed to install oh-my-zsh" 1
    elif command -v wget &> /dev/null; then
        sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" "" --unattended || die "Failed to install oh-my-zsh" 1
    else
        die "curl or wget required to install oh-my-zsh" 1
    fi
}

# Install oh-my-zsh if not present
check_oh_my_zsh() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        if command -v zsh &> /dev/null; then
            if [ "${DRY_RUN:-false}" = true ]; then
                verbose_missing "oh-my-zsh"
                return 1  # Missing
            else
                log_info "oh-my-zsh not found. Installing..."
                install_oh_my_zsh || return 1
            fi
        else
            if [ "${DRY_RUN:-false}" = true ]; then
                verbose_missing "oh-my-zsh" "cannot install (zsh not found)"
            else
                warn "zsh not installed. Skipping oh-my-zsh installation"
                warn "Install zsh first if you want oh-my-zsh"
            fi
            return 1  # Missing
        fi
    else
        if [ "${VERBOSE:-false}" = true ]; then
            verbose_found "oh-my-zsh"
        elif [ "${DRY_RUN:-false}" != true ]; then
            log_info "oh-my-zsh found"
        fi
        return 0  # Found
    fi
}

