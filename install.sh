#!/bin/bash
# Main dotfiles installation orchestrator
# Coordinates all installation steps
#
# Usage:
#   ./install.sh           # Run full installation
#   ./install.sh --dry-run # Show what would be done without making changes
#   ./install.sh --check   # Check current implementation status

set -euo pipefail

# Get the directory where this script is located
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"

# Source shared libraries
source "$SCRIPTS_DIR/lib-core.sh"

# Parse arguments
DRY_RUN=false
CHECK_ONLY=false
VERBOSE=false
SYNC_LOCAL=false
SYNC_MERGE=false
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            ARGS+=("--dry-run")
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            ARGS+=("--verbose")
            shift
            ;;
        --sync-local)
            SYNC_LOCAL=true
            ARGS+=("--sync-local")
            shift
            ;;
        --merge)
            SYNC_MERGE=true
            ARGS+=("--merge")
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $(basename "$0") [OPTIONS]

Install dotfiles on this system.

OPTIONS:
    --dry-run       Show what would be done without making changes
    --verbose, -v   Show detailed output
    --sync-local    Sync local changes back into dotfiles repo before installation
    --merge         When syncing, merge changes instead of overwriting (requires --sync-local)
    --check         Check current implementation status (no installation)
    -h, --help      Show this help message

EXAMPLES:
    $(basename "$0")                           # Run full installation
    $(basename "$0") --dry-run                 # Preview installation steps
    $(basename "$0") --dry-run --verbose       # Preview with detailed output
    $(basename "$0") --sync-local              # Sync local changes, then install
    $(basename "$0") --sync-local --merge      # Sync with merge mode
    $(basename "$0") --sync-local --dry-run    # Preview what would be synced
    $(basename "$0") --check                   # Check if dotfiles are already set up

EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}" >&2
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check-only mode: just run the verification script
if [ "$CHECK_ONLY" = true ]; then
    echo -e "${GREEN}Checking dotfiles implementation status...${NC}"
    echo ""
    "$SCRIPTS_DIR/check-implementation.sh"
    exit $?
fi

echo -e "${GREEN}Setting up dotfiles...${NC}"
echo -e "${GREEN}Detected OS: $OS${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] MODE: No changes will be made${NC}"
fi
if [ "$VERBOSE" = true ]; then
    echo -e "${GREEN}[VERBOSE] MODE: Detailed output enabled${NC}"
fi
if [ "$SYNC_LOCAL" = true ]; then
    if [ "$SYNC_MERGE" = true ]; then
        echo -e "${GREEN}[SYNC LOCAL] MODE: Merging local changes into repo${NC}"
    else
        echo -e "${GREEN}[SYNC LOCAL] MODE: Overwriting repo with local changes${NC}"
    fi
fi
echo ""

# Step 1: Check and install dependencies
"$SCRIPTS_DIR/check-dependencies.sh" "${ARGS[@]}"

echo ""

# Step 2: Stow all packages
"$SCRIPTS_DIR/stow-packages.sh" "${ARGS[@]}"

echo ""

# Step 3: Create .secrets file
"$SCRIPTS_DIR/create-secrets.sh" "${ARGS[@]}"

echo ""

# Step 4: Create .lmstudio-home-pointer (if needed)
"$SCRIPTS_DIR/create-lmstudio-pointer.sh" "${ARGS[@]}"

echo ""

# Step 5: Install packages from Brewfile (optional)
"$SCRIPTS_DIR/install-packages.sh" "${ARGS[@]}"

echo ""
echo -e "${GREEN}✓ Dotfiles setup complete!${NC}"
echo ""
echo -e "${RED}Note: Do not commit secrets to this repository.${NC}"
