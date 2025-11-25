#!/usr/bin/env bats
# Tests for timestamp utility library
# Tests: util/timestamp.sh

load 'test_helper'

# ============================================================================
# Timestamp Tests
# ============================================================================

@test "timestamp: get_timestamp returns formatted timestamp" {
    load_lib "util/timestamp"
    
    run get_timestamp
    assert_success
    # Timestamp should be in format YYYY-MM-DD HH:MM:SS
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "timestamp: get_epoch_timestamp returns epoch seconds" {
    load_lib "util/timestamp"
    
    run get_epoch_timestamp
    assert_success
    # Epoch timestamp should be numeric
    [[ "$output" =~ ^[0-9]+$ ]]
    # Should be a reasonable value (after 2020-01-01)
    [ "$output" -gt 1577836800 ]
}

