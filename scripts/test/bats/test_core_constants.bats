#!/usr/bin/env bats
# Tests for core constants library
# Tests: core/constants.sh

load 'test_helper'

# ============================================================================
# Constants Tests
# ============================================================================

@test "constants: color constants are defined" {
    load_lib "core/constants"
    
    [ -n "$RED" ]
    [ -n "$GREEN" ]
    [ -n "$YELLOW" ]
    [ -n "$NC" ]
}

@test "constants: permission constants are defined" {
    load_lib "core/constants"
    
    [ "$PERM_SECRET_FILE" = "600" ]
    [ "$PERM_SECRET_DIR" = "700" ]
    [ "$PERM_EXECUTABLE" = "755" ]
    [ "$PERM_REGULAR_FILE" = "644" ]
}

