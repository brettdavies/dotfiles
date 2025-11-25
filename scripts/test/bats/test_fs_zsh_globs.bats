#!/usr/bin/env bats
# Tests for Zsh glob operations library
# Tests: fs/zsh-globs.sh

load 'test_helper'

# ============================================================================
# Zsh Glob Qualifier Tests
# ============================================================================

@test "zsh-globs: find_files_zsh_glob works under zsh" {
    load_lib "fs/zsh-globs"
    
    # Skip if not running under zsh
    is_zsh || skip "Not running under zsh"
    
    local test_dir="$BATS_TEST_TMPDIR/zshglob"
    mkdir -p "$test_dir"
    touch "$test_dir/file1.sh"
    touch "$test_dir/file2.sh"
    touch "$test_dir/file3.txt"
    
    run find_files_zsh_glob "$test_dir" "f" "*.sh"
    assert_success
    
    [ "${#FIND_RESULTS[@]}" -ge 2 ]
}

@test "zsh-globs: find_files_zsh_glob returns empty when not zsh" {
    load_lib "fs/zsh-globs"
    
    # Skip if running under zsh (this test is for bash)
    is_zsh && skip "Running under zsh, skipping bash fallback test"
    
    local test_dir="$BATS_TEST_TMPDIR/bash_test"
    mkdir -p "$test_dir"
    touch "$test_dir/file1.txt"
    
    # Should return empty array and exit with failure when not zsh
    run find_files_zsh_glob "$test_dir" "f"
    assert_failure
    [ "${#FIND_RESULTS[@]}" -eq 0 ]
}

@test "zsh-globs: get_dir_listing_zsh works under zsh" {
    load_lib "fs/zsh-globs"
    
    # Skip if not running under zsh
    is_zsh || skip "Not running under zsh"
    
    local test_dir="$BATS_TEST_TMPDIR/zshlist"
    mkdir -p "$test_dir"
    touch "$test_dir/file1.txt"
    touch "$test_dir/file2.txt"
    mkdir -p "$test_dir/subdir"
    
    run get_dir_listing_zsh "$test_dir" "f"
    assert_success
    
    [ "${#DIR_LISTING[@]}" -ge 2 ]
}

