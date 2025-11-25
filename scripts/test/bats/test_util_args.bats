#!/usr/bin/env bats
# Tests for argument parsing library
# Tests: util/args.sh

load 'test_helper'

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "args: parse_common_args sets DRY_RUN flag" {
    load_lib "util/args"
    
    parse_common_args --dry-run
    [ "$DRY_RUN" = "true" ]
    [ "$VERBOSE" = "false" ]
}

@test "args: parse_common_args sets VERBOSE flag" {
    load_lib "util/args"
    
    parse_common_args --verbose
    [ "$VERBOSE" = "true" ]
    [ "$DRY_RUN" = "false" ]
}

@test "args: parse_common_args sets VERBOSE flag with -v" {
    load_lib "util/args"
    
    parse_common_args -v
    [ "$VERBOSE" = "true" ]
}

@test "args: parse_common_args sets SYNC_LOCAL flag" {
    load_lib "util/args"
    
    parse_common_args --sync-local
    [ "$SYNC_LOCAL" = "true" ]
}

@test "args: parse_common_args sets SYNC_MERGE flag" {
    load_lib "util/args"
    
    parse_common_args --merge
    [ "$SYNC_MERGE" = "true" ]
}

@test "args: parse_common_args sets NO_PROGRESS flag" {
    load_lib "util/args"
    
    parse_common_args --no-progress
    [ "$NO_PROGRESS" = "true" ]
}

@test "args: parse_common_args handles multiple flags" {
    load_lib "util/args"
    
    parse_common_args --dry-run --verbose --sync-local
    [ "$DRY_RUN" = "true" ]
    [ "$VERBOSE" = "true" ]
    [ "$SYNC_LOCAL" = "true" ]
}

@test "args: parse_common_args ignores unknown arguments" {
    load_lib "util/args"
    
    parse_common_args --unknown-arg --dry-run
    [ "$DRY_RUN" = "true" ]
}

