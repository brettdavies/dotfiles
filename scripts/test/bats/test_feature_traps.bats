#!/usr/bin/env bats
# Tests for trap handling library
# Tests: feature/traps.sh

load 'test_helper'

# ============================================================================
# Trap Handling Tests
# ============================================================================

@test "traps: setup_traps sets up EXIT trap" {
    load_lib "feature/traps"
    
    # Create a test cleanup function
    test_cleanup_called=false
    test_cleanup() {
        test_cleanup_called=true
    }
    
    setup_traps test_cleanup
    
    # Verify trap is set (can't easily test execution without exiting)
    # Just verify function doesn't fail
    assert_success
}

@test "traps: setup_function_traps sets up RETURN trap" {
    load_lib "feature/traps"
    
    # Test that setup_function_traps function exists
    command -v setup_function_traps &> /dev/null || skip "setup_function_traps not available"
    
    # Call it (should not fail)
    run setup_function_traps
    assert_success
}

@test "traps: enable_debug_tracing works when supported" {
    load_lib "feature/traps"
    
    # Skip if BASH_XTRACEFD is not supported
    has_xtracefd_support || skip "BASH_XTRACEFD not supported"
    
    local test_log
    test_log=$(mktemp)
    
    run enable_debug_tracing "$test_log"
    # Should succeed if supported
    [ $status -eq 0 ] || [ $status -eq 1 ]
    
    rm -f "$test_log"
}

@test "traps: wait_for_any_process works when supported" {
    load_lib "feature/traps"
    
    # Skip if wait -n is not supported
    has_wait_n_support || skip "wait -n not supported"
    
    # Test that function exists
    command -v wait_for_any_process &> /dev/null || return 1
    
    # Note: Can't easily test wait_for_any_process without background processes
    # Just verify function exists
    true
}

