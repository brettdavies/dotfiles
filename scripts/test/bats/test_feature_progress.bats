#!/usr/bin/env bats
# Tests for progress indicators library
# Tests: feature/progress.sh

load 'test_helper'

# ============================================================================
# Progress Indicator Tests
# ============================================================================

@test "progress: is_progress_enabled returns false when NO_PROGRESS is true" {
    load_lib "feature/progress"
    
    NO_PROGRESS=true
    run is_progress_enabled
    assert_failure
}

@test "progress: is_progress_enabled returns true when NO_PROGRESS is false" {
    load_lib "feature/progress"
    
    NO_PROGRESS=false
    run is_progress_enabled
    assert_success
}

@test "progress: calculate_progress calculates percentage correctly" {
    load_lib "feature/progress"
    
    run calculate_progress 50 100
    assert_success
    assert_output "50"
}

@test "progress: calculate_progress handles zero total" {
    load_lib "feature/progress"
    
    run calculate_progress 0 0
    assert_success
    # Should handle division by zero gracefully
    true
}

@test "progress: progress_start initializes progress" {
    load_lib "feature/progress"
    
    NO_PROGRESS=false
    run progress_start "Test operation"
    assert_success
}

@test "progress: progress_complete completes progress" {
    load_lib "feature/progress"
    
    NO_PROGRESS=false
    run progress_complete "Test operation complete"
    assert_success
}

@test "progress: progress_update updates progress" {
    load_lib "feature/progress"
    
    NO_PROGRESS=false
    run progress_update 50 "50% complete"
    assert_success
}

@test "progress: progress_update_item updates item progress" {
    load_lib "feature/progress"
    
    NO_PROGRESS=false
    run progress_update_item 5 10 "Processing item %d of %d..."
    assert_success
}

