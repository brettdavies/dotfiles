#!/usr/bin/env bats
# Tests for validation library
# Tests: feature/validation.sh

load 'test_helper'

# ============================================================================
# Validation Tests
# ============================================================================

@test "validation: validate_path_within allows valid paths" {
    load_lib "feature/validation"
    
    # Create the base directory first (function requires it to exist)
    local test_base="$BATS_TEST_TMPDIR/base/dir"
    mkdir -p "$test_base"
    
    run validate_path_within "$test_base/file.txt" "$test_base"
    assert_success
}

@test "validation: validate_path_within rejects path traversal" {
    load_lib "feature/validation"
    
    run validate_path_within "/base/dir" "/base/dir/../../etc/passwd"
    assert_failure
}

@test "validation: validate_home_path allows home directory paths" {
    load_lib "feature/validation"
    
    run validate_home_path "$HOME/.zshrc"
    assert_success
}

@test "validation: validate_home_path rejects paths outside home" {
    load_lib "feature/validation"
    
    run validate_home_path "/etc/passwd"
    assert_failure
}

@test "validation: sanitize_filename removes dangerous characters" {
    load_lib "feature/validation"
    
    run sanitize_filename "../../etc/passwd"
    assert_success
    assert_output --regexp "^[^./]+"
}

@test "validation: sanitize_filename preserves safe characters" {
    load_lib "feature/validation"
    
    run sanitize_filename "my-file_123.txt"
    assert_success
    assert_output "my-file_123.txt"
}

@test "validation: prevent_path_traversal detects traversal attempts" {
    load_lib "feature/validation"
    
    run prevent_path_traversal "../../etc/passwd"
    assert_failure
}

@test "validation: prevent_path_traversal allows safe paths" {
    load_lib "feature/validation"
    
    # prevent_path_traversal requires path and base_dir arguments
    # A relative path without .. should be safe when within base_dir
    # The parent directory must exist for validation to pass
    local test_base="$BATS_TEST_TMPDIR/test_base"
    mkdir -p "$test_base/safe/path"
    touch "$test_base/safe/path/file.txt"
    run prevent_path_traversal "safe/path/file.txt" "$test_base"
    assert_success
}

@test "validation: validate_directory succeeds for existing directory" {
    load_lib "feature/validation"
    
    local test_dir="$BATS_TEST_TMPDIR/testdir"
    mkdir -p "$test_dir"
    
    run validate_directory "$test_dir"
    assert_success
}

@test "validation: validate_directory fails for non-existent directory" {
    load_lib "feature/validation"
    
    run validate_directory "/nonexistent/directory"
    assert_failure
}

@test "validation: validate_file succeeds for existing file" {
    load_lib "feature/validation"
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    touch "$test_file"
    
    run validate_file "$test_file"
    assert_success
}

@test "validation: validate_file fails for non-existent file" {
    load_lib "feature/validation"
    
    run validate_file "/nonexistent/file.txt"
    assert_failure
}

