#!/bin/bash
# Create .secrets file with proper permissions

set -e

# Source shared library
source "$(dirname "$0")/lib.sh"

# Main execution
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
