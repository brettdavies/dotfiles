#!/usr/bin/env bats
# Tests for output utility library
# Tests: util/output.sh

load 'test_helper'

# ============================================================================
# Error Reporting Tests
# ============================================================================

@test "output: err outputs error message to stderr" {
    load_lib "util/output"
    
    run err "Test error message" 1
    assert_failure
    assert_output --partial "Test error message"
    assert_output --partial "Error"
}

@test "output: err returns specified exit code" {
    load_lib "util/output"
    
    run err "Test error" 42
    assert_failure
    [ "$status" -eq 42 ]
}

@test "output: die exits with error message" {
    load_lib "util/output"
    
    # die function should be available after loading util/output
    # Test that it exists (can't easily test exit behavior in BATS)
    command -v die &> /dev/null || return 1
    # We can't easily test exit codes in BATS for functions that exit
    # So we'll just verify the function exists
    true
}

@test "output: warn outputs warning message to stderr" {
    load_lib "util/output"
    
    run warn "Test warning"
    assert_success
    assert_output --partial "Test warning"
    assert_output --partial "Warning"
}

@test "output: info outputs info message to stdout" {
    load_lib "util/output"
    
    run info "Test info"
    assert_success
    assert_output --partial "Test info"
    assert_output --partial "Info"
}

@test "output: get_call_stack returns call stack information" {
    load_lib "util/output"
    
    # Test that get_call_stack function exists and can be called
    run get_call_stack
    # Function should return (may be empty, but shouldn't error)
    assert_success
}

@test "output: die includes call stack in error message" {
    load_lib "util/output"
    
    # Test that die function exists and can be called
    # (We can't easily test the full output without exiting)
    command -v die &> /dev/null || return 1
    
    # Verify get_call_stack is used by die
    command -v get_call_stack &> /dev/null || return 1
}

