#!/usr/bin/env bash
# Setup git-crypt for transparent encryption/decryption

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/standard.sh"

# Parse arguments
parse_common_args "$@"

# Setup trap handlers for cleanup and error handling
init_temp_dir "setup-git-crypt.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Get the dotfiles directory (parent of scripts directory)
DOTFILES_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Check if repository uses git-crypt
repo_uses_git_crypt() {
    if [ -f "$DOTFILES_DIR/.gitattributes" ]; then
        if grep -q "filter=git-crypt" "$DOTFILES_DIR/.gitattributes" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Install git hooks for automatic unlock
install_git_hooks() {
    local hooks_dir="$DOTFILES_DIR/.git/hooks"
    local repo_hooks_dir="$DOTFILES_DIR/scripts/git-hooks"
    
    if [ ! -d "$hooks_dir" ]; then
        log_warn "Git hooks directory not found: $hooks_dir"
        return 1
    fi
    
    if [ ! -d "$repo_hooks_dir" ]; then
        log_warn "Repository hooks directory not found: $repo_hooks_dir"
        return 1
    fi
    
    # Install post-checkout hook
    local source_hook="$repo_hooks_dir/post-checkout"
    local target_hook="$hooks_dir/post-checkout"
    
    if [ "$DRY_RUN" = true ]; then
        verbose_would_create "$target_hook"
        log_info "[DRY RUN] Would install post-checkout hook from $source_hook"
    else
        if [ -f "$source_hook" ]; then
            cp "$source_hook" "$target_hook"
            chmod +x "$target_hook"
            log_info "Installed post-checkout hook from repository"
        else
            log_warn "Source hook not found: $source_hook"
        fi
    fi
    
    # Install post-merge hook
    source_hook="$repo_hooks_dir/post-merge"
    target_hook="$hooks_dir/post-merge"
    
    if [ "$DRY_RUN" = true ]; then
        verbose_would_create "$target_hook"
        log_info "[DRY RUN] Would install post-merge hook from $source_hook"
    else
        if [ -f "$source_hook" ]; then
            cp "$source_hook" "$target_hook"
            chmod +x "$target_hook"
            log_info "Installed post-merge hook from repository"
        else
            log_warn "Source hook not found: $source_hook"
        fi
    fi
}

# Main execution
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] Checking git-crypt setup...${NC}"
    log_info "[DRY RUN] Checking git-crypt setup"
else
    echo "  - Setting up git-crypt"
    log_info "Setting up git-crypt"
fi

# Check if repository uses git-crypt
if ! repo_uses_git_crypt; then
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → Repository does not use git-crypt, skipping${NC}"
    fi
    log_info "Repository does not use git-crypt, skipping setup"
    exit 0
fi

# Check if git-crypt is installed
if ! command -v git-crypt &> /dev/null; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}  → Would install git-crypt${NC}"
        log_info "[DRY RUN] Would install git-crypt"
    else
        echo -e "${YELLOW}  → Installing git-crypt...${NC}"
        log_info "Installing git-crypt"
        
        if [[ "$OS" == "macos" ]]; then
            if command -v brew &> /dev/null; then
                brew install git-crypt
                log_info "Installed git-crypt via Homebrew"
            else
                log_error "Homebrew not found, cannot install git-crypt"
                warn "Please install git-crypt manually: brew install git-crypt"
                exit 1
            fi
        else
            # Linux - try common package managers
            if command -v apt-get &> /dev/null; then
                sudo apt-get install -y git-crypt
                log_info "Installed git-crypt via apt-get"
            elif command -v yum &> /dev/null; then
                sudo yum install -y git-crypt
                log_info "Installed git-crypt via yum"
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y git-crypt
                log_info "Installed git-crypt via dnf"
            else
                log_error "No supported package manager found"
                warn "Please install git-crypt manually for your Linux distribution"
                exit 1
            fi
        fi
    fi
else
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}  → git-crypt is installed${NC}"
    fi
    log_info "git-crypt is installed"
fi

# Install git hooks
if [ "$DRY_RUN" = true ]; then
    verbose_would_create ".git/hooks/post-checkout"
    verbose_would_create ".git/hooks/post-merge"
    log_info "[DRY RUN] Would install git hooks"
else
    install_git_hooks
fi

# Check if key file exists and attempt unlock
KEY_FILE="$HOME/.config/git-crypt/key"
if [ ! -f "$KEY_FILE" ]; then
    echo -e "${YELLOW}  ⚠ git-crypt key not found at $KEY_FILE${NC}"
    log_warn "git-crypt key not found at $KEY_FILE"
    echo -e "${YELLOW}  → Please copy your git-crypt key file to this location, then run:${NC}"
    echo -e "${YELLOW}     git-crypt unlock $KEY_FILE${NC}"
    log_info "Key file not found, user needs to unlock manually"
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}  → Would attempt to unlock git-crypt${NC}"
        log_info "[DRY RUN] Would attempt to unlock git-crypt"
    else
        # Check if already unlocked
        if git-crypt status 2>/dev/null | grep -q "not unlocked"; then
            echo -e "${GREEN}  → Unlocking git-crypt...${NC}"
            log_info "Unlocking git-crypt"
            if git-crypt unlock "$KEY_FILE" 2>/dev/null; then
                echo -e "${GREEN}  ✓ git-crypt unlocked successfully${NC}"
                log_info "git-crypt unlocked successfully"
            else
                echo -e "${RED}  ✗ Failed to unlock git-crypt${NC}"
                log_error "Failed to unlock git-crypt"
                warn "Please unlock manually: git-crypt unlock $KEY_FILE"
            fi
        else
            if [ "$VERBOSE" = true ]; then
                echo -e "${GREEN}  → git-crypt is already unlocked${NC}"
            fi
            log_info "git-crypt is already unlocked"
        fi
    fi
fi

