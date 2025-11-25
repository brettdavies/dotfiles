#!/usr/bin/env bats
# Tests for path utilities library
# Tests: util/paths.sh

load 'test_helper'

# ============================================================================
# Path Utilities Tests
# ============================================================================

@test "paths: get_dotfiles_dir returns absolute path" {
    load_lib "util/paths"
    
    # Test that get_dotfiles_dir returns an absolute path
    local result
    result=$(get_dotfiles_dir)
    [ "${result:0:1}" = "/" ]  # Starts with /
}

@test "paths: DOTFILES_DIR is set after loading lib-paths" {
    load_lib "util/paths"
    
    [ -n "$DOTFILES_DIR" ]
    [ -d "$DOTFILES_DIR" ]
}

@test "paths: STOW_DIR is set correctly" {
    load_lib "util/paths"
    
    [ -n "$STOW_DIR" ]
    [ "$STOW_DIR" = "$DOTFILES_DIR/stow" ]
}

@test "paths: SCRIPTS_DIR is set correctly" {
    load_lib "util/paths"
    
    [ -n "$SCRIPTS_DIR" ]
    [ "$SCRIPTS_DIR" = "$DOTFILES_DIR/scripts" ]
}

@test "paths: OS is set after loading lib-paths" {
    load_lib "util/paths"
    
    [ -n "${OS:-}" ]
    case "${OS:-}" in
        macos|linux|unknown)
            true
            ;;
        *)
            false
            ;;
    esac
}

