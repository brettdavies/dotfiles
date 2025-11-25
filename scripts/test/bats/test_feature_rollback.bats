#!/usr/bin/env bats
# Tests for rollback functionality library
# Tests: feature/rollback.sh

load 'test_helper'

# ============================================================================
# Rollback Tests
# ============================================================================

@test "rollback: init_rollback initializes rollback system" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    run init_rollback
    assert_success
}

@test "rollback: record_operation records an operation" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    init_rollback
    
    run record_operation "test" "echo 'test'"
    assert_success
}

@test "rollback: record_file_backup records file backup" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    init_rollback
    
    local test_file="$BATS_TEST_TMPDIR/test.txt"
    echo "test content" > "$test_file"
    local backup_file="$BATS_TEST_TMPDIR/backup.txt"
    cp "$test_file" "$backup_file"
    
    run record_file_backup "$test_file" "$backup_file"
    assert_success
}

@test "rollback: record_symlink_creation records symlink" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    init_rollback
    
    local target="$BATS_TEST_TMPDIR/target.txt"
    local link="$BATS_TEST_TMPDIR/link.txt"
    echo "target" > "$target"
    ln -s "$target" "$link"
    
    run record_symlink_creation "$link" "$target"
    assert_success
}

@test "rollback: get_rollback_script generates rollback script" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    init_rollback
    record_operation "test" "echo 'test'"
    
    local script
    script=$(get_rollback_script)
    
    [ -n "$script" ]
    assert_file_contains "$script" "test"
}

@test "rollback: finalize_rollback completes rollback setup" {
    load_lib "feature/rollback"
    load_lib "feature/rollback"
    
    init_temp_dir "rollback-test.XXXXXX"
    init_rollback
    record_operation "test" "echo 'test'"
    
    run finalize_rollback
    assert_success
}

