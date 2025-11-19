#!/bin/bash
# Create .lmstudio-home-pointer if LM Studio is installed

set -e

# Source shared library
source "$(dirname "$0")/lib.sh"

# Main execution
if command -v lms &> /dev/null || [ -d ~/.lmstudio ]; then
    echo "  - Creating .lmstudio-home-pointer"
    if [ ! -f ~/.lmstudio-home-pointer ]; then
        echo "$HOME/.lmstudio" > ~/.lmstudio-home-pointer
        echo -e "${GREEN}    Created .lmstudio-home-pointer${NC}"
    else
        echo -e "${YELLOW}    .lmstudio-home-pointer already exists, skipping${NC}"
    fi
fi

