#!/usr/bin/env bats
# Tests for filesystem find operations library
# Tests: fs/find.sh

load 'test_helper'

# ============================================================================
# Filesystem Operations Tests
# ============================================================================

@test "find: find_files_array finds files in directory" {
    load_lib "fs/find"
    
    local test_dir="$BATS_TEST_TMPDIR/testdir"
    mkdir -p "$test_dir"
    touch "$test_dir/file1.txt"
    touch "$test_dir/file2.txt"
    mkdir -p "$test_dir/subdir"
    touch "$test_dir/subdir/file3.txt"
    
    local files_array
    find_files_array files_array "$test_dir" "-type f"
    
    [ "${#files_array[@]}" -ge 3 ]
}

@test "find: find_dirs_in_dir finds directories" {
    load_lib "fs/find"
    
    local test_dir="$BATS_TEST_TMPDIR/testdir"
    mkdir -p "$test_dir/subdir1"
    mkdir -p "$test_dir/subdir2"
    touch "$test_dir/file.txt"
    
    find_dirs_in_dir "$test_dir"
    
    [ "${#FIND_RESULTS[@]}" -ge 2 ]
}

@test "find: count_files_in_dir counts files correctly" {
    load_lib "fs/find"
    
    local test_dir="$BATS_TEST_TMPDIR/testdir"
    mkdir -p "$test_dir"
    touch "$test_dir/file1.txt"
    touch "$test_dir/file2.txt"
    touch "$test_dir/file3.txt"
    
    local count
    count=$(count_files_in_dir "$test_dir")
    
    [ "$count" -ge 3 ]
}

@test "find: is_dir_empty returns true for empty directory" {
    load_lib "fs/find"
    
    local test_dir="$BATS_TEST_TMPDIR/emptydir"
    mkdir -p "$test_dir"
    
    run is_dir_empty "$test_dir"
    assert_success
}

@test "find: is_dir_empty returns false for non-empty directory" {
    load_lib "fs/find"
    
    local test_dir="$BATS_TEST_TMPDIR/nonemptydir"
    mkdir -p "$test_dir"
    touch "$test_dir/file.txt"
    
    run is_dir_empty "$test_dir"
    assert_failure
}

@test "find: clear_dir_cache clears cache" {
    load_lib "fs/find"
    
    init_dir_cache
    run clear_dir_cache
    
    # Cache should be cleared (no way to directly verify, but function should not fail)
    assert_success
}

@test "find: find_files_in_dir works with zsh globs or find fallback" {
    load_lib "fs/find"
    
    # This test verifies that find_files_in_dir works correctly whether using
    # zsh glob qualifiers or find command fallback
    local test_dir="$BATS_TEST_TMPDIR/fallback_test"
    mkdir -p "$test_dir"
    touch "$test_dir/test1.txt"
    touch "$test_dir/test2.txt"
    touch "$test_dir/test3.sh"
    
    find_files_in_dir "$test_dir" "-type f"
    
    # Should find files regardless of method used (zsh globs or find)
    [ "${#FIND_RESULTS[@]}" -ge 3 ]
    
    # Verify specific files are found
    local found=false
    for file in "${FIND_RESULTS[@]}"; do
        if [[ "$file" == *"test1.txt" ]]; then
            found=true
            break
        fi
    done
    [ "$found" = true ]
}

@test "find: find_files_in_dir fallback produces correct results" {
    load_lib "fs/find"
    
    # Test that fallback to find command produces same results as zsh globs
    local test_dir="$BATS_TEST_TMPDIR/fallback_verify"
    mkdir -p "$test_dir/subdir"
    touch "$test_dir/file1.txt"
    touch "$test_dir/subdir/file2.txt"
    
    find_files_in_dir "$test_dir" "-type f"
    local count="${#FIND_RESULTS[@]}"
    
    # Should find both files regardless of implementation
    [ "$count" -ge 2 ]
}

