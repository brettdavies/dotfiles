#!/usr/bin/env bats
# Tests for package version constraints library
# Tests: pkg/version-constraints.sh

load 'test_helper'

# ============================================================================
# Target Version Parsing Tests
# ============================================================================

@test "version-constraints: parse_target_version extracts base version without caret" {
    load_lib "pkg/version-constraints"
    
    parse_target_version "5.2.0"
    [ "$TARGET_VERSION_BASE" = "5.2.0" ]
    [ "$TARGET_VERSION_HAS_CARET" = "false" ]
}

@test "version-constraints: parse_target_version detects caret syntax" {
    load_lib "pkg/version-constraints"
    
    parse_target_version "5.2^"
    [ "$TARGET_VERSION_BASE" = "5.2" ]
    [ "$TARGET_VERSION_HAS_CARET" = "true" ]
}

@test "version-constraints: parse_target_version fails for empty version" {
    load_lib "pkg/version-constraints"
    
    run parse_target_version ""
    assert_failure
}

# ============================================================================
# Target Version Expansion Tests
# ============================================================================

@test "version-constraints: expand_target_version expands caret syntax correctly" {
    load_lib "pkg/version-constraints"
    
    expand_target_version "5.2^"
    [ "$EXPANDED_MIN_VERSION" = "5.2.0" ]
    [ "$EXPANDED_MAX_VERSION" = "5.3.0" ]
}

@test "version-constraints: expand_target_version handles version without caret" {
    load_lib "pkg/version-constraints"
    
    expand_target_version "5.2.0"
    [ "$EXPANDED_MIN_VERSION" = "5.2.0" ]
    [ "$EXPANDED_MAX_VERSION" = "5.2.0" ]
}

@test "version-constraints: expand_target_version handles single digit minor version" {
    load_lib "pkg/version-constraints"
    
    expand_target_version "1.6^"
    [ "$EXPANDED_MIN_VERSION" = "1.6.0" ]
    [ "$EXPANDED_MAX_VERSION" = "1.7.0" ]
}

@test "version-constraints: expand_target_version fails for empty version" {
    load_lib "pkg/version-constraints"
    
    run expand_target_version ""
    assert_failure
}

# ============================================================================
# Version Matching Tests
# ============================================================================

@test "version-constraints: find_matching_version finds version within range" {
    load_lib "pkg/version-constraints"
    load_lib "pkg/version"
    
    local versions
    versions="5.2.0
5.2.1
5.2.15
5.3.0"
    
    run find_matching_version "$versions" "5.2.0" "5.3.0"
    assert_success
    assert_output "5.2.15"
}

@test "version-constraints: find_matching_version returns empty when no match" {
    load_lib "pkg/version-constraints"
    load_lib "pkg/version"
    
    local versions
    versions="5.1.0
5.3.0"
    
    run find_matching_version "$versions" "5.2.0" "5.3.0"
    assert_failure
    assert_output ""
}

@test "version-constraints: find_matching_version handles no constraints" {
    load_lib "pkg/version-constraints"
    load_lib "pkg/version"
    
    local versions
    versions="5.2.0
5.2.1"
    
    run find_matching_version "$versions" "" ""
    assert_success
    assert_output "5.2.0"
}

# ============================================================================
# Package Version Constraints Tests
# ============================================================================

@test "version-constraints: get_package_version_constraints reads target_version from yaml" {
    load_lib "pkg/version-constraints"
    
    # Skip if yq is not available
    if ! command -v yq &> /dev/null; then
        skip "yq not available for testing"
    fi
    
    # Create test packages.yaml in test temp directory
    # Function expects $STOW_DIR/brew/packages.yaml, so create that structure
    local test_stow_dir="$BATS_TEST_TMPDIR/test_stow"
    local test_yaml="$test_stow_dir/brew/packages.yaml"
    mkdir -p "$(dirname "$test_yaml")"
    cat > "$test_yaml" <<EOF
packages:
  bash:
    brew: bash
    target_version: "5.2^"
EOF
    
    # Temporarily override STOW_DIR to point to test temp directory
    local original_stow_dir="${STOW_DIR:-}"
    export STOW_DIR="$test_stow_dir"
    
    get_package_version_constraints "bash" "brew"
    
    # Restore original STOW_DIR
    if [ -n "$original_stow_dir" ]; then
        export STOW_DIR="$original_stow_dir"
    else
        unset STOW_DIR
    fi
    
    [ "$PACKAGE_MIN_VERSION" = "5.2.0" ]
    [ "$PACKAGE_MAX_VERSION" = "5.3.0" ]
    [ "$PACKAGE_MAX_VERSION_EXCLUSIVE" = "true" ]
}

@test "version-constraints: get_package_version_constraints handles brew_target_version override" {
    load_lib "pkg/version-constraints"
    
    # Skip if yq is not available
    if ! command -v yq &> /dev/null; then
        skip "yq not available for testing"
    fi
    
    # Create test packages.yaml in test temp directory
    # Function expects $STOW_DIR/brew/packages.yaml, so create that structure
    local test_stow_dir="$BATS_TEST_TMPDIR/test_stow"
    local test_yaml="$test_stow_dir/brew/packages.yaml"
    mkdir -p "$(dirname "$test_yaml")"
    cat > "$test_yaml" <<EOF
packages:
  bash:
    brew: bash
    target_version: "5.1^"
    brew_target_version: "5.2^"
EOF
    
    # Temporarily override STOW_DIR to point to test temp directory
    local original_stow_dir="${STOW_DIR:-}"
    export STOW_DIR="$test_stow_dir"
    
    get_package_version_constraints "bash" "brew"
    
    # Restore original STOW_DIR
    if [ -n "$original_stow_dir" ]; then
        export STOW_DIR="$original_stow_dir"
    else
        unset STOW_DIR
    fi
    
    [ "$PACKAGE_MIN_VERSION" = "5.2.0" ]
    [ "$PACKAGE_MAX_VERSION" = "5.3.0" ]
}

@test "version-constraints: get_package_version_constraints falls back to min_version" {
    load_lib "pkg/version-constraints"
    
    # Skip if yq is not available
    if ! command -v yq &> /dev/null; then
        skip "yq not available for testing"
    fi
    
    # Create test packages.yaml in test temp directory
    # Function expects $STOW_DIR/brew/packages.yaml, so create that structure
    local test_stow_dir="$BATS_TEST_TMPDIR/test_stow"
    local test_yaml="$test_stow_dir/brew/packages.yaml"
    mkdir -p "$(dirname "$test_yaml")"
    cat > "$test_yaml" <<EOF
packages:
  bash:
    brew: bash
    min_version: "5.2"
EOF
    
    # Temporarily override STOW_DIR to point to test temp directory
    local original_stow_dir="${STOW_DIR:-}"
    export STOW_DIR="$test_stow_dir"
    
    get_package_version_constraints "bash" "brew"
    
    # Restore original STOW_DIR
    if [ -n "$original_stow_dir" ]; then
        export STOW_DIR="$original_stow_dir"
    else
        unset STOW_DIR
    fi
    
    [ "$PACKAGE_MIN_VERSION" = "5.2" ]
}

