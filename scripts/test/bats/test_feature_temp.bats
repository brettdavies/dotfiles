#!/usr/bin/env bats
# Tests for temporary file management library
# Tests: feature/temp.sh

load 'test_helper'

# ============================================================================
# Temporary Directory Management Tests
# ============================================================================

@test "temp: init_temp_dir creates temporary directory" {
    load_lib "feature/temp"
    
    # Reset temp dir state for clean test
    unset SCRIPT_TEMP_DIR
    
    # Call directly (not in subshell) - subshell would trigger EXIT trap cleanup
    init_temp_dir "test.XXXXXX" > /dev/null
    [ -n "$SCRIPT_TEMP_DIR" ]
    [ -d "$SCRIPT_TEMP_DIR" ]
}

@test "temp: init_temp_dir sets secure permissions" {
    load_lib "feature/temp"
    
    # Reset temp dir state for clean test
    unset SCRIPT_TEMP_DIR
    
    # Call directly (not in subshell) - subshell would trigger EXIT trap cleanup
    init_temp_dir "test.XXXXXX" > /dev/null
    
    # Verify directory exists before checking permissions
    [ -d "$SCRIPT_TEMP_DIR" ] || fail "Temp directory not created"
    
    local perms
    perms=$(stat -f "%OLp" "$SCRIPT_TEMP_DIR" 2>/dev/null || stat -c "%a" "$SCRIPT_TEMP_DIR" 2>/dev/null)
    assert_equal "$perms" "700"
}

@test "temp: get_temp_dir returns existing directory" {
    load_lib "feature/temp"
    
    # Reset temp dir state for clean test
    unset SCRIPT_TEMP_DIR
    
    # First create temp dir (call directly, not in subshell)
    init_temp_dir "test.XXXXXX" > /dev/null
    local temp_dir1="$SCRIPT_TEMP_DIR"
    
    # Now get_temp_dir should return the same directory
    local temp_dir2
    temp_dir2=$(get_temp_dir)
    
    assert_equal "$temp_dir1" "$temp_dir2"
}

@test "temp: get_temp_dir creates directory if not exists" {
    load_lib "feature/temp"
    
    # Reset temp dir state and ensure clean state
    unset SCRIPT_TEMP_DIR
    SCRIPT_TEMP_DIR=""
    
    # Call get_temp_dir directly (not in subshell) to avoid EXIT trap cleanup
    get_temp_dir > /dev/null
    [ -n "$SCRIPT_TEMP_DIR" ]
    [ -d "$SCRIPT_TEMP_DIR" ]
}

@test "temp: create_temp_file creates file in temp directory" {
    load_lib "feature/temp"
    
    init_temp_dir "test.XXXXXX"
    local temp_file
    temp_file=$(create_temp_file "test.XXXXXX")
    
    [ -f "$temp_file" ]
    [ "$(dirname "$temp_file")" = "$(get_temp_dir)" ]
}

@test "temp: create_temp_file sets secure permissions" {
    load_lib "feature/temp"
    
    init_temp_dir "test.XXXXXX"
    local temp_file
    temp_file=$(create_temp_file "test.XXXXXX")
    
    local perms
    perms=$(stat -f "%OLp" "$temp_file" 2>/dev/null || stat -c "%a" "$temp_file" 2>/dev/null)
    assert_equal "$perms" "600"
}

@test "temp: create_temp_subdir creates subdirectory" {
    load_lib "feature/temp"
    
    init_temp_dir "test.XXXXXX"
    local temp_subdir
    temp_subdir=$(create_temp_subdir "subdir.XXXXXX")
    
    [ -d "$temp_subdir" ]
    [ "$(dirname "$temp_subdir")" = "$(get_temp_dir)" ]
}

@test "temp: cleanup_temp_dir removes directory" {
    load_lib "feature/temp"
    
    local temp_dir
    temp_dir=$(init_temp_dir "test.XXXXXX")
    
    cleanup_temp_dir
    
    [ ! -d "$temp_dir" ]
    [ -z "$SCRIPT_TEMP_DIR" ]
}

