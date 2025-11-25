#!/usr/bin/env bats
# Tests for OS detection library
# Tests: core/detect-os.sh

load 'test_helper'

# ============================================================================
# OS Detection Tests
# ============================================================================

@test "os: detect_os returns valid OS" {
    load_lib "core/detect-os"
    
    run detect_os
    assert_success
    case "$output" in
        macos|linux|unknown)
            true
            ;;
        *)
            false
            ;;
    esac
}

@test "os: is_zsh detects zsh correctly" {
    load_lib "core/detect-os"
    
    # Test when running under zsh
    if [ -n "${ZSH_VERSION:-}" ]; then
        run is_zsh
        assert_success
    else
        # Test when not running under zsh
        run is_zsh
        assert_failure
    fi
}

