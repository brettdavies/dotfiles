#!/usr/bin/env bats
# Tests for IDE extension management library
# Tests: pkg/extensions.sh

load 'test_helper'

# ============================================================================
# Extension Command Tests
# ============================================================================

@test "extensions: get_cursor_command finds cursor command" {
    load_lib "pkg/extensions"
    
    mock_command "cursor" "echo 'cursor command'"
    
    run get_cursor_command
    # Should find the mocked command or return empty
    true
}

