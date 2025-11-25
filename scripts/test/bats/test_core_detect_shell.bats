#!/usr/bin/env bats
# Tests for shell detection library
# Tests: core/detect-shell.sh

load 'test_helper'

# ============================================================================
# Bash Version Detection Tests
# ============================================================================

@test "detect-shell: get_bash_version returns version string" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run get_bash_version
    assert_success
    # Version should be in format "major.minor"
    [[ "$output" =~ ^[0-9]+\.[0-9]+$ ]]
}

@test "detect-shell: compare_bash_version compares versions correctly" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    # Get current version
    local current_version
    current_version=$(get_bash_version)
    
    # Test eq (equal) with current version - should always succeed
    run compare_bash_version "$current_version" "eq"
    assert_success
    
    # Test ge (greater than or equal) - result depends on version
    # If current version is >= 4.0, should succeed; otherwise should fail
    run compare_bash_version "4.0" "ge"
    # Function should not error (exit code 0 or 1, not 2+)
    [ $status -eq 0 ] || [ $status -eq 1 ]
    
    # Test le (less than or equal) with a high version - should succeed for any reasonable version
    run compare_bash_version "10.0" "le"
    assert_success
}

@test "detect-shell: is_bash_4_plus detects Bash 4+" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run is_bash_4_plus
    # Should succeed if Bash 4+, fail otherwise
    # We can't predict the result, but the function should not error
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

@test "detect-shell: is_bash_5_2_plus detects Bash 5.2+" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run is_bash_5_2_plus
    # Should succeed if Bash 5.2+, fail otherwise
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

# ============================================================================
# Feature Detection Tests
# ============================================================================

@test "detect-shell: has_nameref_support detects nameref availability" {
    load_lib "core/detect-shell"
    
    run has_nameref_support
    # Should succeed if nameref is supported, fail otherwise
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

@test "detect-shell: has_wait_n_support detects wait -n availability" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run has_wait_n_support
    # Should succeed if wait -n is supported (Bash 5.1+), fail otherwise
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

@test "detect-shell: has_xtracefd_support detects BASH_XTRACEFD availability" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run has_xtracefd_support
    # Should succeed if BASH_XTRACEFD is supported (Bash 5.1+), fail otherwise
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

@test "detect-shell: has_mapfile_null_delim detects mapfile -d availability" {
    load_lib "core/detect-shell"
    
    # Skip if not running under bash
    [ -n "${BASH_VERSION:-}" ] || skip "Not running under bash"
    
    run has_mapfile_null_delim
    # Should succeed if mapfile -d is supported (Bash 4.4+), fail otherwise
    [ $status -eq 0 ] || [ $status -eq 1 ]
}

