#!/usr/bin/env bash
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
source "$SCRIPTS_DIR/lib/loaders/standard.sh"

# Parse arguments
DRY_RUN=false
CHECK_ONLY=false
VERBOSE=false
SYNC_LOCAL=false
SYNC_MERGE=false
LOG_FILE=""
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
        --log-file)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --log-file requires a filename${NC}" >&2
                exit 1
            fi
            LOG_FILE="$2"
            ARGS+=("--log-file" "$2")
            shift 2
            ;;
        --no-progress)
            NO_PROGRESS=true
            ARGS+=("--no-progress")
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
    --log-file FILE Enable logging to a file (for debugging and audit trails)
    --no-progress   Disable progress indicators
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

# Initialize logging if log file is specified
if [ -n "$LOG_FILE" ]; then
    init_logging "$LOG_FILE"
fi

# Setup trap handlers for cleanup and error handling
setup_traps cleanup_temp_files

# Check-only mode: just run the verification script
if [ "$CHECK_ONLY" = true ]; then
    echo -e "${GREEN}Checking dotfiles implementation status...${NC}"
    log_info "Checking dotfiles implementation status"
    echo ""
    "$SCRIPTS_DIR/check/check-implementation.sh"
    exit $?
fi

echo -e "${GREEN}Setting up dotfiles...${NC}"
log_info "Setting up dotfiles"
echo -e "${GREEN}Detected OS: $OS${NC}"
log_info "Detected OS: $OS"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] MODE: No changes will be made${NC}"
    log_info "[DRY RUN] MODE: No changes will be made"
fi
if [ "$VERBOSE" = true ]; then
    echo -e "${GREEN}[VERBOSE] MODE: Detailed output enabled${NC}"
    log_info "[VERBOSE] MODE: Detailed output enabled"
fi
if [ "$SYNC_LOCAL" = true ]; then
    if [ "$SYNC_MERGE" = true ]; then
        echo -e "${GREEN}[SYNC LOCAL] MODE: Merging local changes into repo${NC}"
        log_info "[SYNC LOCAL] MODE: Merging local changes into repo"
    else
        echo -e "${GREEN}[SYNC LOCAL] MODE: Overwriting repo with local changes${NC}"
        log_info "[SYNC LOCAL] MODE: Overwriting repo with local changes"
    fi
fi
if [ -n "$LOG_FILE" ]; then
    echo -e "${GREEN}[LOGGING] MODE: Logging to $LOG_FILE${NC}"
    log_info "[LOGGING] MODE: Logging to $LOG_FILE"
    log_info "Installation started"
fi
echo ""

# Step 1: Check and install dependencies
"$SCRIPTS_DIR/install/check-dependencies.sh" "${ARGS[@]}"

echo ""

# Step 2: Stow all packages
"$SCRIPTS_DIR/install/stow-packages.sh" "${ARGS[@]}"

echo ""

# Step 3: Create .secrets file
"$SCRIPTS_DIR/install/create-secrets.sh" "${ARGS[@]}"

echo ""

# Step 4: Create .lmstudio-home-pointer (if needed)
"$SCRIPTS_DIR/install/create-lmstudio-pointer.sh" "${ARGS[@]}"

echo ""

# Step 5: Install packages from Brewfile (optional)
"$SCRIPTS_DIR/install/install-packages.sh" "${ARGS[@]}"

echo ""
echo -e "${GREEN}✓ Dotfiles setup complete!${NC}"
log_info "Dotfiles setup complete"
echo ""
echo -e "${RED}Note: Do not commit secrets to this repository.${NC}"
log_warn "Note: Do not commit secrets to this repository"
