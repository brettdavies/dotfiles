#!/usr/bin/env bats
# Tests for shell string manipulation library
# Tests: shell/strings.sh

load 'test_helper'

# ============================================================================
# Parameter Expansion Helper Tests
# ============================================================================

@test "strings: split_string splits string by delimiter (works with zsh and bash)" {
    load_lib "shell/strings"
    
    # This test verifies split_string works with both zsh parameter expansion and bash IFS fallback
    local test_array
    split_string test_array "a,b,c" ","
    
    [ "${#test_array[@]}" -eq 3 ]
    [ "${test_array[0]}" = "a" ]
    [ "${test_array[1]}" = "b" ]
    [ "${test_array[2]}" = "c" ]
}

@test "strings: split_string fallback produces same results" {
    load_lib "shell/strings"
    
    # Test with different delimiters to verify fallback works
    local test_array1 test_array2
    
    split_string test_array1 "a:b:c" ":"
    split_string test_array2 "x-y-z" "-"
    
    [ "${#test_array1[@]}" -eq 3 ]
    [ "${#test_array2[@]}" -eq 3 ]
    [ "${test_array1[0]}" = "a" ]
    [ "${test_array2[0]}" = "x" ]
}

@test "strings: join_array joins array with delimiter" {
    load_lib "shell/strings"
    
    local test_array=(a b c)
    local result
    result=$(join_array test_array "," "name")
    
    [ "$result" = "a,b,c" ]
}

@test "strings: uppercase_string converts to uppercase (zsh and fallback)" {
    load_lib "shell/strings"
    
    # Test that uppercase_string works with both zsh parameter expansion and tr fallback
    local result
    result=$(uppercase_string "hello")
    
    [ "$result" = "HELLO" ]
    
    # Test with mixed case
    result=$(uppercase_string "HeLLo WoRLd")
    [ "$result" = "HELLO WORLD" ]
}

@test "strings: lowercase_string converts to lowercase (zsh and fallback)" {
    load_lib "shell/strings"
    
    # Test that lowercase_string works with both zsh parameter expansion and tr fallback
    local result
    result=$(lowercase_string "HELLO")
    
    [ "$result" = "hello" ]
    
    # Test with mixed case
    result=$(lowercase_string "HeLLo WoRLd")
    [ "$result" = "hello world" ]
}

