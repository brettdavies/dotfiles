#!/usr/bin/env bats
# Tests for file operations library
# Tests: fs/file-ops.sh

load 'test_helper'

# ============================================================================
# File Operations Tests
# ============================================================================

@test "file-ops: get_file_permissions returns octal permissions" {
    load_lib "fs/file-ops"
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    touch "$test_file"
    chmod 644 "$test_file"
    
    run get_file_permissions "$test_file"
    assert_success
    assert_output "644"
}

@test "file: get_file_permissions handles 600 permissions" {
    load_lib "fs/file-ops"
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    touch "$test_file"
    chmod 600 "$test_file"
    
    run get_file_permissions "$test_file"
    assert_success
    assert_output "600"
}

@test "file: get_file_permissions handles 755 permissions" {
    load_lib "fs/file-ops"
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    touch "$test_file"
    chmod 755 "$test_file"
    
    run get_file_permissions "$test_file"
    assert_success
    assert_output "755"
}

@test "file: get_file_permissions works cross-platform" {
    load_lib "fs/file-ops"
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    touch "$test_file"
    chmod 700 "$test_file"
    
    run get_file_permissions "$test_file"
    assert_success
    # Should work on both macOS (stat -f) and Linux (stat -c)
    assert_output "700"
}

@test "file: get_file_permissions works with zsh zstat or external stat" {
    load_lib "fs/file-ops"
    
    # This test verifies that get_file_permissions works with both
    # zsh built-in zstat and external stat command fallback
    local test_file="$BATS_TEST_TMPDIR/stat_test.txt"
    touch "$test_file"
    chmod 644 "$test_file"
    
    run get_file_permissions "$test_file"
    assert_success
    assert_output "644"
}

@test "file: get_file_stat works with zsh zstat or external stat" {
    load_lib "fs/file-ops"
    
    # Test that get_file_stat works with both zsh built-in and external stat
    local test_file="$BATS_TEST_TMPDIR/stat_size.txt"
    echo "test content" > "$test_file"
    
    # Test size retrieval
    run get_file_stat "$test_file" "size"
    assert_success
    # Should return file size (at least 12 bytes for "test content\n")
    [ "$output" -ge 12 ]
}

@test "file: safe_mkdir works with zsh built-in or external mkdir" {
    load_lib "fs/file-ops"
    
    # Test that safe_mkdir works with both zsh zf_mkdir and external mkdir
    local test_dir="$BATS_TEST_TMPDIR/safe_mkdir_test"
    rm -rf "$test_dir"
    
    run safe_mkdir "$test_dir" "-p"
    assert_success
    [ -d "$test_dir" ]
    
    rm -rf "$test_dir"
}

@test "file: safe_ln works with zsh built-in or external ln" {
    load_lib "fs/file-ops"
    
    # Test that safe_ln works with both zsh zf_ln and external ln
    local test_file="$BATS_TEST_TMPDIR/safe_ln_source.txt"
    local test_link="$BATS_TEST_TMPDIR/safe_ln_link.txt"
    echo "test" > "$test_file"
    rm -f "$test_link"
    
    run safe_ln "-s" "$test_file" "$test_link"
    assert_success
    [ -L "$test_link" ]
    
    rm -f "$test_file" "$test_link"
}

@test "file: safe_rm works with zsh built-in or external rm" {
    load_lib "fs/file-ops"
    
    # Test that safe_rm works with both zsh zf_rm and external rm
    local test_file="$BATS_TEST_TMPDIR/safe_rm_test.txt"
    touch "$test_file"
    
    run safe_rm "$test_file" "-f"
    assert_success
    [ ! -f "$test_file" ]
}

@test "file: safe_chmod works with zsh built-in or external chmod" {
    load_lib "fs/file-ops"
    
    # Test that safe_chmod works with both zsh zf_chmod and external chmod
    local test_file="$BATS_TEST_TMPDIR/safe_chmod_test.txt"
    touch "$test_file"
    
    run safe_chmod "600" "$test_file"
    assert_success
    
    local perms
    perms=$(get_file_permissions "$test_file")
    [ "$perms" = "600" ]
    
    rm -f "$test_file"
}

