#!/bin/bash
# Create .secrets file with proper permissions

set -euo pipefail

# Source shared libraries
source "$(dirname "$0")/lib-core.sh"
source "$(dirname "$0")/lib-file.sh"

# Parse arguments
parse_common_args "$@"

# Main execution
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] Checking .secrets file...${NC}"
    if [ ! -f ~/.secrets ]; then
        verbose_would_create "~/.secrets"
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}  → Would set permissions: 600${NC}"
        fi
        echo -e "${YELLOW}[DRY RUN] Would create .secrets file with 600 permissions${NC}"
    else
        PERMS=$(get_file_permissions ~/.secrets)
        verbose_already_exists ".secrets" "permissions: $PERMS"
        if [ "$PERMS" != "600" ]; then
            verbose_would_update ".secrets" "permissions: $PERMS -> 600"
            echo -e "${YELLOW}[DRY RUN] Would update .secrets file permissions to 600${NC}"
        else
            echo -e "${GREEN}[DRY RUN] .secrets file exists with correct permissions${NC}"
        fi
    fi
else
    echo "  - Creating .secrets file"
    if [ ! -f ~/.secrets ]; then
        touch ~/.secrets
        echo -e "${GREEN}    Created empty .secrets file with 600 permissions${NC}"
        echo -e "${RED}    Note: .secrets file should be managed separately on each machine.${NC}"
    else
        echo -e "${YELLOW}    .secrets file already exists, skipping${NC}"
    fi
    
    # Always enforce correct permissions (even if file pre-existed)
    chmod 600 ~/.secrets
fi
