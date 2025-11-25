#!/usr/bin/env bash
# Create .secrets file with proper permissions

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/standard.sh"
source "$SCRIPTS_DIR/lib/fs/file-ops.sh"

# Parse arguments
parse_common_args "$@"

# Setup trap handlers for cleanup and error handling
# Initialize temporary directory for this script execution
init_temp_dir "create-secrets.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Main execution
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] Checking .secrets file...${NC}"
    log_info "[DRY RUN] Checking .secrets file"
    if [ ! -f ~/.secrets ]; then
        verbose_would_create "~/.secrets"
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}  → Would set permissions: $PERM_SECRET_FILE${NC}"
        fi
        echo -e "${YELLOW}[DRY RUN] Would create .secrets file with $PERM_SECRET_FILE permissions${NC}"
        log_info "[DRY RUN] Would create .secrets file with $PERM_SECRET_FILE permissions"
    else
        PERMS=$(get_file_permissions ~/.secrets)
        verbose_already_exists ".secrets" "permissions: $PERMS"
        if [ "$PERMS" != "$PERM_SECRET_FILE" ]; then
            verbose_would_update ".secrets" "permissions: $PERMS -> $PERM_SECRET_FILE"
            echo -e "${YELLOW}[DRY RUN] Would update .secrets file permissions to $PERM_SECRET_FILE${NC}"
            log_info "[DRY RUN] Would update .secrets file permissions to $PERM_SECRET_FILE"
        else
            echo -e "${GREEN}[DRY RUN] .secrets file exists with correct permissions${NC}"
            log_info "[DRY RUN] .secrets file exists with correct permissions"
        fi
    fi
else
    echo "  - Creating .secrets file"
    log_info "Creating .secrets file"
    if [ ! -f ~/.secrets ]; then
        touch ~/.secrets
        log_info "Created empty .secrets file with $PERM_SECRET_FILE permissions"
        warn "Note: .secrets file should be managed separately on each machine"
    else
        log_info ".secrets file already exists, skipping"
    fi
    
    # Always enforce correct permissions (even if file pre-existed)
    # Use safe_chmod if available, otherwise fallback to chmod
    if command -v safe_chmod &> /dev/null; then
        safe_chmod "$PERM_SECRET_FILE" ~/.secrets || chmod "$PERM_SECRET_FILE" ~/.secrets
    else
        chmod "$PERM_SECRET_FILE" ~/.secrets
    fi
fi
