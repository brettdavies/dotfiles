#!/usr/bin/env bash
# Check and install required dependencies (stow, shells, oh-my-zsh)
# Orchestrator script that coordinates dependency checking

set -euo pipefail

# Source shared libraries
# Uses packages.sh loader to provide version comparison functions (version_ge, etc.)
# from lib/pkg/version.sh, which are required by dependency checkers
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/packages.sh"

# Parse arguments
parse_common_args "$@"

# Setup trap handlers for cleanup and error handling
# Initialize temporary directory for this script execution
init_temp_dir "check-dependencies.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# Source dependency checkers
DEPS_DIR="$(cd "$(dirname "$0")/dependencies" && pwd)"
source "$DEPS_DIR/common.sh"
source "$DEPS_DIR/bash.sh"
source "$DEPS_DIR/yq.sh"
source "$DEPS_DIR/stow.sh"
source "$DEPS_DIR/shells.sh"
source "$DEPS_DIR/oh-my-zsh.sh"

# Main execution
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Checking dependencies..."
else
    log_info "Checking dependencies..."
fi

MISSING_COUNT=0

# Check bash version FIRST (must be 5.2+)
# This ensures all subsequent scripts can use modern bash features
if ! check_bash_version; then
    ((MISSING_COUNT++))
fi

# Check yq version (must be 4.0+)
# Required for generate-brewfile.sh script
if ! check_yq_version; then
    ((MISSING_COUNT++))
fi

# Check stow
if ! check_stow; then
    ((MISSING_COUNT++))
fi

# Check shells
check_shells
SHELL_MISSING=$?
MISSING_COUNT=$((MISSING_COUNT + SHELL_MISSING))

# Check oh-my-zsh
if ! check_oh_my_zsh; then
    ((MISSING_COUNT++))
fi

# Summary for dry-run
if [ "$DRY_RUN" = true ]; then
    if [ $MISSING_COUNT -eq 0 ]; then
        log_info "[DRY RUN] All dependencies satisfied"
    else
        log_info "[DRY RUN] Would install $MISSING_COUNT missing dependencies"
    fi
else
    if [ $MISSING_COUNT -eq 0 ]; then
        log_info "All dependencies satisfied"
    fi
fi
