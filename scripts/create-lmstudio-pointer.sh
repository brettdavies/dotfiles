#!/bin/bash
# Create .lmstudio-home-pointer if LM Studio is installed

set -euo pipefail

# Source shared libraries
source "$(dirname "$0")/lib-core.sh"

# Parse arguments
parse_common_args "$@"

# Main execution
if command -v lms &> /dev/null || [ -d ~/.lmstudio ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Checking .lmstudio-home-pointer...${NC}"
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
        else
            verbose_already_exists ".lmstudio-home-pointer"
            echo -e "${GREEN}[DRY RUN] .lmstudio-home-pointer already exists${NC}"
        fi
    else
        echo "  - Creating .lmstudio-home-pointer"
        if [ ! -f ~/.lmstudio-home-pointer ]; then
            echo "$HOME/.lmstudio" > ~/.lmstudio-home-pointer
            echo -e "${GREEN}    Created .lmstudio-home-pointer${NC}"
        else
            echo -e "${YELLOW}    .lmstudio-home-pointer already exists, skipping${NC}"
        fi
    fi
fi

