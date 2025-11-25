#!/usr/bin/env bats
# Tests for logging library
# Tests: feature/logging.sh

load 'test_helper'

# ============================================================================
# Logging Tests
# ============================================================================

@test "logging: init_logging creates log file" {
    load_lib "feature/logging"
    
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    [ -f "$log_file" ]
    assert_file_contains "$log_file" "Dotfiles Installation Log"
}

@test "logging: log_info writes to log file when enabled" {
    load_lib "feature/logging"
    
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    log_info "Test message"
    
    assert_file_contains "$log_file" "Test message"
    assert_file_contains "$log_file" "[INFO]"
}

@test "logging: log_info outputs to stdout when VERBOSE is true" {
    load_lib "feature/logging"
    
    VERBOSE=true
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    run log_info "Test message"
    assert_success
    assert_output --partial "Test message"
}

@test "logging: log_warn writes to log file and stderr" {
    load_lib "feature/logging"
    
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    run log_warn "Test warning"
    assert_success
    assert_output --partial "Test warning"
    assert_file_contains "$log_file" "[WARN]"
}

@test "logging: log_error writes to log file and stderr" {
    load_lib "feature/logging"
    
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    run log_error "Test error"
    assert_success
    assert_output --partial "Test error"
    assert_file_contains "$log_file" "[ERROR]"
}

@test "logging: log_debug writes to log file when enabled" {
    load_lib "feature/logging"
    
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    log_debug "Test debug"
    
    assert_file_contains "$log_file" "[DEBUG]"
    assert_file_contains "$log_file" "Test debug"
}

@test "logging: log_debug outputs to stdout when VERBOSE is true" {
    load_lib "feature/logging"
    
    VERBOSE=true
    local log_file="$BATS_TEST_TMPDIR/test.log"
    init_logging "$log_file"
    
    run log_debug "Test debug"
    assert_success
    assert_output --partial "Test debug"
}

@test "logging: log functions work without log file" {
    load_lib "feature/logging"
    
    # Don't initialize logging
    LOG_ENABLED=false
    
    run log_info "Test message"
    assert_success
    # Should not fail even without log file
}

