#!/usr/bin/env bats
# Tests for Stow operations library
# Tests: domain/stow.sh

load 'test_helper'

# ============================================================================
# Stow Operations Tests
# ============================================================================

@test "stow: transform_dotfiles_path converts dot- to ." {
    load_lib "domain/stow"
    
    run transform_dotfiles_path "dot-zshrc"
    assert_success
    assert_output ".zshrc"
}

@test "stow: transform_dotfiles_path handles nested paths" {
    load_lib "domain/stow"
    
    run transform_dotfiles_path "config/dot-git/config"
    assert_success
    assert_output "config/.git/config"
}

@test "stow: normalize_path resolves absolute paths" {
    load_lib "domain/stow"
    
    local test_dir="$BATS_TEST_TMPDIR/test"
    mkdir -p "$test_dir"
    
    # Get the expected resolved path (macOS resolves /var -> /private/var)
    local expected_dir
    expected_dir=$(cd "$test_dir" && pwd -P)
    
    run normalize_path "$test_dir"
    assert_success
    assert_output "$expected_dir"
}

@test "stow: normalize_path resolves relative paths" {
    load_lib "domain/stow"
    
    local test_dir="$BATS_TEST_TMPDIR/test"
    mkdir -p "$test_dir"
    cd "$BATS_TEST_TMPDIR"
    
    # Get the expected resolved path (macOS resolves /var -> /private/var)
    local expected_dir
    expected_dir=$(cd "$test_dir" && pwd -P)
    
    run normalize_path "test"
    assert_success
    assert_output "$expected_dir"
}

@test "stow: normalize_path handles . and .." {
    load_lib "domain/stow"
    
    local test_dir="$BATS_TEST_TMPDIR/test"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    run normalize_path ".."
    assert_success
    assert_output "$BATS_TEST_TMPDIR"
}

@test "stow: check_dir_symlink detects directory symlink" {
    load_lib "domain/stow"
    
    local target_dir="$BATS_TEST_TMPDIR/target"
    local link_dir="$BATS_TEST_TMPDIR/link"
    mkdir -p "$target_dir"
    ln -s "$target_dir" "$link_dir"
    
    run check_dir_symlink "$link_dir" "$target_dir"
    assert_success
}

@test "stow: is_parent_dir_symlinked detects parent symlink" {
    load_lib "domain/stow"
    
    # Set up a proper stow-like structure
    local test_home="$BATS_TEST_TMPDIR/home"
    local test_stow="$BATS_TEST_TMPDIR/stow"
    local package="testpkg"
    
    mkdir -p "$test_home"
    mkdir -p "$test_stow/$package/dot-config"
    
    # Override HOME and STOW_DIR for this test
    export HOME="$test_home"
    export STOW_DIR="$test_stow"
    
    # Create the symlink: ~/.config -> stow/testpkg/dot-config
    ln -s "$test_stow/$package/dot-config" "$test_home/.config"
    touch "$test_stow/$package/dot-config/somefile"
    
    # Test that is_parent_dir_symlinked detects the symlink
    run is_parent_dir_symlinked "$test_home/.config/somefile" "$package"
    assert_success
}

