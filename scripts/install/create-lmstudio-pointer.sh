#!/usr/bin/env bash
# Create .lmstudio-home-pointer if LM Studio is installed

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/standard.sh"

# Parse arguments
parse_common_args "$@"

# Setup trap handlers for cleanup and error handling
# Initialize temporary directory for this script execution
init_temp_dir "create-lmstudio-pointer.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Main execution
if command -v lms &> /dev/null || [ -d ~/.lmstudio ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Checking .lmstudio-home-pointer...${NC}"
        log_info "[DRY RUN] Checking .lmstudio-home-pointer"
        if command -v lms &> /dev/null; then
            verbose_detected "LM Studio" "'lms' command"
        elif [ -d ~/.lmstudio ]; then
            verbose_detected "LM Studio" "~/.lmstudio directory"
        fi
        if [ ! -f ~/.lmstudio-home-pointer ]; then
            verbose_would_create "~/.lmstudio-home-pointer"
            if [ "$VERBOSE" = true ]; then
                echo -e "${YELLOW}  → Would point to: $HOME/.lmstudio${NC}"
            fi
            echo -e "${YELLOW}[DRY RUN] Would create .lmstudio-home-pointer pointing to $HOME/.lmstudio${NC}"
            log_info "[DRY RUN] Would create .lmstudio-home-pointer pointing to $HOME/.lmstudio"
        else
            verbose_already_exists ".lmstudio-home-pointer"
            echo -e "${GREEN}[DRY RUN] .lmstudio-home-pointer already exists${NC}"
            log_info "[DRY RUN] .lmstudio-home-pointer already exists"
        fi
    else
        echo "  - Creating .lmstudio-home-pointer"
        log_info "Creating .lmstudio-home-pointer"
        if [ ! -f ~/.lmstudio-home-pointer ]; then
            echo "$HOME/.lmstudio" > ~/.lmstudio-home-pointer
            log_info "Created .lmstudio-home-pointer"
        else
            log_info ".lmstudio-home-pointer already exists, skipping"
        fi
    fi
fi

