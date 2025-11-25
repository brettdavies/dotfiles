#!/usr/bin/env bash
# Constants library
# Provides color constants and file permission constants
# This file should be sourced early, before other libraries that need colors

# Prevent re-sourcing
if [ -n "${LIB_CONSTANTS_LOADED:-}" ]; then
    return 0
fi
export LIB_CONSTANTS_LOADED=1

# ============================================================================
# Constants
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# File permissions
readonly PERM_SECRET_FILE='600'      # Secret files (e.g., .secrets)
readonly PERM_SECRET_DIR='700'       # Secret directories (temp dirs)
readonly PERM_EXECUTABLE='755'       # Executable files
readonly PERM_REGULAR_FILE='644'     # Regular files

