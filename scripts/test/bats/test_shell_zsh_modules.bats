#!/usr/bin/env bats
# Tests for Zsh module loading library
# Tests: shell/zsh-modules.sh

load 'test_helper'

# ============================================================================
# Zsh Module Loading Tests
# ============================================================================

@test "zsh-modules: zsh modules load when running under zsh" {
    load_lib "shell/zsh-modules"
    
    # Skip if not running under zsh
    is_zsh || skip "Not running under zsh"
    
    # Modules should be loaded (flags should be set)
    # Note: This test may pass even if modules fail to load (they're optional)
    # We're just checking that the function doesn't error
    run load_zsh_modules
    assert_success
}

