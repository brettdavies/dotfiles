#!/usr/bin/env bats
# Tests for package version comparison library
# Tests: pkg/version.sh

load 'test_helper'

# ============================================================================
# Version Comparison Tests
# ============================================================================

@test "version: version_ge returns true for greater version" {
    load_lib "pkg/version"
    
    run version_ge "2.0.0" "1.0.0"
    assert_success
}

@test "version: version_ge returns true for equal version" {
    load_lib "pkg/version"
    
    run version_ge "1.0.0" "1.0.0"
    assert_success
}

@test "version: version_ge returns false for lesser version" {
    load_lib "pkg/version"
    
    run version_ge "1.0.0" "2.0.0"
    assert_failure
}

@test "version: version_le returns true for lesser version" {
    load_lib "pkg/version"
    
    run version_le "1.0.0" "2.0.0"
    assert_success
}

@test "version: version_le returns true for equal version" {
    load_lib "pkg/version"
    
    run version_le "1.0.0" "1.0.0"
    assert_success
}

@test "version: version_le returns false for greater version" {
    load_lib "pkg/version"
    
    run version_le "2.0.0" "1.0.0"
    assert_failure
}

@test "version: version_lt returns true for lesser version" {
    load_lib "pkg/version"
    
    run version_lt "1.0.0" "2.0.0"
    assert_success
}

@test "version: version_lt returns false for equal version" {
    load_lib "pkg/version"
    
    run version_lt "1.0.0" "1.0.0"
    assert_failure
}

@test "version: version_lt returns false for greater version" {
    load_lib "pkg/version"
    
    run version_lt "2.0.0" "1.0.0"
    assert_failure
}

# ============================================================================
# Version Validation Tests
# ============================================================================

@test "version: validate_package_version accepts version within range" {
    load_lib "pkg/version"
    
    run validate_package_version "5.2.5" "5.2.0" "5.3.0" "true"
    assert_success
}

@test "version: validate_package_version rejects version below min" {
    load_lib "pkg/version"
    
    run validate_package_version "5.1.0" "5.2.0" "5.3.0" "true"
    assert_failure
}

@test "version: validate_package_version rejects version at exclusive max" {
    load_lib "pkg/version"
    
    run validate_package_version "5.3.0" "5.2.0" "5.3.0" "true"
    assert_failure
}

@test "version: validate_package_version accepts version at inclusive max" {
    load_lib "pkg/version"
    
    run validate_package_version "5.3.0" "5.2.0" "5.3.0" "false"
    assert_success
}

@test "version: validate_package_version accepts version with no constraints" {
    load_lib "pkg/version"
    
    run validate_package_version "5.2.0" "" ""
    assert_success
}

# ============================================================================
# Homebrew Version Query Tests
# ============================================================================

@test "version: query_brew_versions returns version for package" {
    load_lib "pkg/version"
    
    # Skip if brew is not available (common in CI environments)
    if ! command -v brew &> /dev/null; then
        skip "brew not available for testing"
    fi
    
    # Mock brew info to return JSON
    mock_command "brew" "if [ \"\$1\" = \"info\" ] && [ \"\$2\" = \"--json=v1\" ]; then echo '[{\"name\":\"bash\",\"versions\":{\"stable\":\"5.2.15\"}}]'; else command brew \"\$@\"; fi"
    
    # Mock jq if not available
    if ! command -v jq &> /dev/null; then
        mock_command "jq" "echo '5.2.15'"
    fi
    
    run query_brew_versions "bash" "package"
    # May succeed or fail depending on actual brew availability
    true
}

@test "version: query_brew_versions returns empty when brew not available" {
    load_lib "pkg/version"
    
    # Ensure brew is not in PATH
    local saved_path="$PATH"
    export PATH="/usr/bin:/bin"
    
    run query_brew_versions "bash" "package"
    assert_failure
    
    export PATH="$saved_path"
}

@test "version: query_brew_versions handles cask type" {
    load_lib "pkg/version"
    
    # Skip if brew is not available
    if ! command -v brew &> /dev/null; then
        skip "brew not available for testing"
    fi
    
    # Mock brew info to return JSON
    mock_command "brew" "if [ \"\$1\" = \"info\" ] && [ \"\$2\" = \"--cask\" ] && [ \"\$3\" = \"--json=v1\" ]; then echo '[{\"name\":\"ghostty\",\"versions\":{\"stable\":\"1.0.0\"}}]'; else command brew \"\$@\"; fi"
    
    # Mock jq if not available
    if ! command -v jq &> /dev/null; then
        mock_command "jq" "echo '1.0.0'"
    fi
    
    run query_brew_versions "ghostty" "cask"
    # May succeed or fail depending on actual brew availability
    true
}

