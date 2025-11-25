#!/usr/bin/env bats
# Tests for verbose output library
# Tests: feature/verbose.sh

load 'test_helper'

# ============================================================================
# Verbose Output Tests
# ============================================================================

@test "verbose: verbose_found outputs when VERBOSE is true" {
    load_lib "feature/verbose"
    
    VERBOSE=true
    run verbose_found "Test Item"
    assert_success
    assert_output --partial "Test Item: found"
}

@test "verbose: verbose_found does not output when VERBOSE is false" {
    load_lib "feature/verbose"
    
    VERBOSE=false
    run verbose_found "Test Item"
    assert_success
    assert_output ""
}

@test "verbose: verbose_missing outputs when VERBOSE is true" {
    load_lib "feature/verbose"
    
    VERBOSE=true
    run verbose_missing "Test Item"
    assert_success
    assert_output --partial "Test Item: not found"
}

@test "verbose: verbose_would_create outputs when VERBOSE is true" {
    load_lib "feature/verbose"
    
    VERBOSE=true
    run verbose_would_create "~/.testfile"
    assert_success
    assert_output --partial "Would create: ~/.testfile"
}

@test "verbose: verbose_already_exists outputs when VERBOSE is true" {
    load_lib "feature/verbose"
    
    VERBOSE=true
    run verbose_already_exists ".testfile" "permissions: 600"
    assert_success
    assert_output --partial ".testfile already exists"
}

