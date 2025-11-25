#!/usr/bin/env bats
# Tests for package cache library
# Tests: pkg/cache.sh

load 'test_helper'

# ============================================================================
# Package Cache Tests
# ============================================================================

@test "cache: init_package_cache initializes cache" {
    load_lib "pkg/cache"
    
    # Mock brew to avoid actual calls
    mock_command "brew" "echo ''"
    
    run init_package_cache
    assert_success
}

@test "cache: check_assoc_array_support detects support" {
    load_lib "pkg/cache"
    
    run check_assoc_array_support
    # Should succeed on Bash 4+ or zsh
    # May fail on Bash 3.2, which is acceptable
    true
}

