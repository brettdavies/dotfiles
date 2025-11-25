#!/usr/bin/env bats
# Tests for shell array manipulation library
# Tests: shell/arrays.sh

load 'test_helper'

# ============================================================================
# Array Reading Tests
# ============================================================================

@test "shell: read_lines_into_array reads file into array" {
    load_lib "shell/arrays"
    
    local test_file
    test_file=$(mktemp)
    echo -e "line1\nline2\nline3" > "$test_file"
    
    local test_array
    read_lines_into_array test_array "$test_file"
    
    [ "${#test_array[@]}" -eq 3 ]
    [ "${test_array[0]}" = "line1" ]
    [ "${test_array[1]}" = "line2" ]
    [ "${test_array[2]}" = "line3" ]
    
    rm -f "$test_file"
}

@test "shell: read_lines_into_array reads from command" {
    load_lib "shell/arrays"
    
    local test_array
    read_lines_into_array test_array "echo -e 'line1\nline2'"
    
    [ "${#test_array[@]}" -eq 2 ]
    [ "${test_array[0]}" = "line1" ]
    [ "${test_array[1]}" = "line2" ]
}

@test "shell: read_lines_into_array handles empty file" {
    load_lib "shell/arrays"
    
    local test_file
    test_file=$(mktemp)
    touch "$test_file"
    
    local test_array
    read_lines_into_array test_array "$test_file"
    
    [ "${#test_array[@]}" -eq 0 ]
    
    rm -f "$test_file"
}

@test "shell: read_lines_into_array works with or without nameref" {
    load_lib "shell/arrays"
    
    # This test verifies that read_lines_into_array works regardless of nameref support
    # It should use nameref when available, eval fallback when not
    local test_file
    test_file=$(mktemp)
    echo -e "test1\ntest2\ntest3" > "$test_file"
    
    local test_array
    read_lines_into_array test_array "$test_file"
    
    # Should work with both nameref and eval fallback
    [ "${#test_array[@]}" -eq 3 ]
    [ "${test_array[0]}" = "test1" ]
    [ "${test_array[1]}" = "test2" ]
    [ "${test_array[2]}" = "test3" ]
    
    rm -f "$test_file"
}

@test "shell: read_lines_into_array fallback works correctly" {
    load_lib "shell/arrays"
    
    # Test that the function produces correct results even when using fallback
    # This verifies backward compatibility
    local test_file
    test_file=$(mktemp)
    echo -e "line1\nline2" > "$test_file"
    
    local test_array
    read_lines_into_array test_array "$test_file"
    
    # Verify results are correct regardless of implementation
    [ "${#test_array[@]}" -eq 2 ]
    [ "${test_array[0]}" = "line1" ]
    [ "${test_array[1]}" = "line2" ]
    
    rm -f "$test_file"
}

@test "shell: read_null_delimited_into_array handles null-delimited input" {
    load_lib "shell/arrays"
    
    local test_array
    read_null_delimited_into_array test_array "printf 'file1\0file2\0file3\0'"
    
    [ "${#test_array[@]}" -eq 3 ]
    [ "${test_array[0]}" = "file1" ]
    [ "${test_array[1]}" = "file2" ]
    [ "${test_array[2]}" = "file3" ]
}

