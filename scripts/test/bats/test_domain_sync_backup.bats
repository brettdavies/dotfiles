#!/usr/bin/env bats
# Tests for sync backup operations library
# Tests: domain/sync-backup.sh

load 'test_helper'

# ============================================================================
# Sync Backup Operations Tests
# ============================================================================

@test "sync-backup: copy_to_repo copies file correctly" {
    load_lib "domain/sync-backup"
    
    local source_file="$BATS_TEST_TMPDIR/source.txt"
    local dest_file="$BATS_TEST_TMPDIR/dest.txt"
    echo "test content" > "$source_file"
    
    run copy_to_repo "$source_file" "$dest_file"
    assert_success
    [ -f "$dest_file" ]
    assert_file_contains "$dest_file" "test content"
}

@test "sync-backup: create_file_backup creates backup" {
    load_lib "domain/sync-backup"
    
    local original_file="$BATS_TEST_TMPDIR/original.txt"
    echo "original content" > "$original_file"
    
    local backup_file
    backup_file=$(create_file_backup "$original_file")
    
    [ -f "$backup_file" ]
    assert_file_contains "$backup_file" "original content"
}

