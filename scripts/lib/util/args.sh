#!/usr/bin/env bash
# Argument parsing library
# Provides functions for parsing common command-line arguments
# Requires: core/constants.sh (for colors in error messages)

# Prevent re-sourcing
if [ -n "${LIB_ARGS_LOADED:-}" ]; then
    return 0
fi
export LIB_ARGS_LOADED=1

# Source constants if not already sourced
if [ -z "${RED:-}" ] || [ -z "${GREEN:-}" ] || [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# ============================================================================
# Argument Parsing
# ============================================================================

# Parse common command-line arguments used across all scripts
# 
# Purpose: Extracts and sets global flags for common script behaviors
# 
# Parameters:
#   "$@" - All command-line arguments passed to the script
# 
# Returns: Nothing (sets global variables)
# 
# Side effects:
#   Sets the following global boolean variables:
#   - DRY_RUN: true if --dry-run flag is present
#   - VERBOSE: true if --verbose or -v flag is present
#   - SYNC_LOCAL: true if --sync-local flag is present
#   - SYNC_MERGE: true if --merge flag is present
#   - NO_PROGRESS: true if --no-progress flag is present
#   - DEBUG: true if --debug flag is present
#   - DEBUG_LOG: path to debug log file if --debug-log is specified
# 
# Example:
#   parse_common_args "$@"
#   if [ "$DRY_RUN" = true ]; then
#       echo "Would perform action"
#   fi
#   if [ "$DEBUG" = true ]; then
#       enable_debug_tracing "$DEBUG_LOG"
#   fi
# 
# Note: Unknown arguments are ignored (may be handled by calling script)
parse_common_args() {
    DRY_RUN=false
    VERBOSE=false
    SYNC_LOCAL=false
    SYNC_MERGE=false
    NO_PROGRESS=false
    DEBUG=false
    DEBUG_LOG=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --sync-local)
                SYNC_LOCAL=true
                shift
                ;;
            --merge)
                SYNC_MERGE=true
                shift
                ;;
            --no-progress)
                NO_PROGRESS=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --debug-log)
                if [[ -z "${2:-}" ]]; then
                    echo -e "${RED}Error: --debug-log requires a filename${NC}" >&2
                    exit 1
                fi
                DEBUG=true
                DEBUG_LOG="$2"
                shift 2
                ;;
            *)
                # Unknown argument, ignore (might be from parent script or script-specific)
                shift
                ;;
        esac
    done
}

