#!/usr/bin/env bash
# Trap handlers and signal handling
# Provides functions for trap setup, signal handling, and debug tracing
# Requires: util/output.sh (for err, warn), feature/temp.sh (for cleanup_temp_dir)

# Prevent re-sourcing
if [ -n "${LIB_TRAPS_LOADED:-}" ]; then
    return 0
fi
export LIB_TRAPS_LOADED=1

# Source output if not already sourced
if ! command -v err &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/output.sh" 2>/dev/null || true
fi

# Source temp if available (for cleanup_temp_dir)
if ! command -v cleanup_temp_dir &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/temp.sh" 2>/dev/null || true
fi

# ============================================================================
# Signal and Error Handling
# ============================================================================

# Handle signals (INT, TERM)
# Usage: handle_signal <signal>
handle_signal() {
    local signal="$1"
    local script_name="${0##*/}"
    warn "Received $signal signal, cleaning up..."
    if command -v cleanup_temp_dir &> /dev/null; then
        cleanup_temp_dir
    fi
    exit 130  # Standard exit code for SIGINT
}

# Handle errors with enhanced context
# Usage: handle_error <exit_code> <line_number>
# 
# Purpose: Enhanced error handler that includes call stack information
handle_error() {
    local exit_code="$1"
    local line_number="$2"
    local script_name="${0##*/}"
    local call_stack
    if command -v get_call_stack &> /dev/null; then
        call_stack=$(get_call_stack)
    fi
    
    local error_msg="Error at line $line_number (exit code: $exit_code)"
    if [ -n "$call_stack" ]; then
        error_msg="${error_msg} [Call stack: $call_stack]"
    fi
    
    # Use log_error if available, otherwise use err
    if command -v log_error &> /dev/null; then
        log_error "$error_msg"
    elif command -v err &> /dev/null; then
        err "$error_msg" "$exit_code"
    fi
    if command -v cleanup_temp_dir &> /dev/null; then
        cleanup_temp_dir
    fi
}

# Function cleanup handler (for RETURN trap)
# Usage: Internal use by setup_function_traps
# 
# Purpose: Handles cleanup when a function returns
_function_return_handler() {
    local exit_code=$?
    # Only perform cleanup if function exited with error
    if [ $exit_code -ne 0 ]; then
        # Could add function-specific cleanup here if needed
        :
    fi
    return $exit_code
}

# Setup function-level traps (RETURN trap)
# Usage: setup_function_traps [cleanup_function]
# 
# Purpose: Sets up RETURN trap for function-level cleanup and error tracking
#   This allows tracking when functions return and performing cleanup
# 
# Parameters:
#   $1 - Optional cleanup function to call on function return
# 
# Returns: Nothing
# 
# Side effects: Sets up RETURN trap
# 
# Example:
#   setup_function_traps my_cleanup
setup_function_traps() {
    local cleanup_func="${1:-}"
    
    if [ -n "$cleanup_func" ]; then
        # Use provided cleanup function
        trap "$cleanup_func" RETURN
    else
        # Use default handler
        trap '_function_return_handler' RETURN
    fi
}

# Enable debug tracing with BASH_XTRACEFD (Bash 5.1+)
# Usage: enable_debug_tracing [log_file]
# 
# Purpose: Redirects set -x output to a separate file descriptor
#   This allows debug output to be separated from stdout/stderr
# 
# Parameters:
#   $1 - Optional log file path (default: /tmp/debug-$$.log)
# 
# Returns: 0 on success, 1 if not supported
# 
# Side effects: Sets up BASH_XTRACEFD and enables tracing
# 
# Example:
#   enable_debug_tracing "/tmp/my-debug.log"
#   set -x
enable_debug_tracing() {
    local log_file="${1:-/tmp/debug-$$.log}"
    
    if ! command -v has_xtracefd_support &> /dev/null || ! has_xtracefd_support; then
        # Not supported, return failure
        return 1
    fi
    
    # Create log file
    touch "$log_file" 2>/dev/null || return 1
    
    # Open file descriptor for debug output
    exec {BASH_XTRACEFD}>"$log_file" || return 1
    
    # Enable tracing
    set -x
    
    return 0
}

# Wait for any background process to complete (Bash 5.1+)
# Usage: wait_for_any_process
# 
# Purpose: Waits for any background process to complete
#   Uses wait -n when available (Bash 5.1+), falls back to wait
# 
# Parameters: None
# 
# Returns: Exit code of the completed process
# 
# Side effects: Waits for a background process
# 
# Example:
#   some_command &
#   wait_for_any_process
wait_for_any_process() {
    if command -v has_wait_n_support &> /dev/null && has_wait_n_support; then
        # Bash 5.1+: use wait -n
        wait -n
        return $?
    else
        # Fallback: wait for all background processes
        wait
        return $?
    fi
}

# Setup trap handlers for cleanup and error handling
# Usage: setup_traps [cleanup_function]
# Example: setup_traps cleanup_temp_dir
# 
# Purpose: Sets up comprehensive trap handlers for signals, errors, and cleanup
#   Enhanced with RETURN trap support and better error context
setup_traps() {
    local cleanup_func="${1:-cleanup_temp_dir}"
    
    # Cleanup on exit
    trap "$cleanup_func" EXIT
    
    # Handle signals gracefully
    trap "handle_signal INT" INT
    trap "handle_signal TERM" TERM
    
    # Error handler with enhanced context
    # Use BASH_LINENO for better line number reporting
    if [[ "${-}" != *e* ]]; then
        if command -v is_zsh &> /dev/null && is_zsh; then
            trap 'handle_error $? $LINENO' ERR
        else
            # Bash: use BASH_LINENO for more accurate line numbers
            trap 'handle_error $? ${BASH_LINENO[0]:-$LINENO}' ERR
        fi
    fi
    
    # Setup function return trap if supported
    # RETURN trap is available in both Bash and zsh
    setup_function_traps
}

