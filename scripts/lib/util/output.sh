#!/usr/bin/env bash
# Basic output functions
# Provides functions for error reporting, warnings, and info messages
# Requires: core/constants.sh (for colors)

# Prevent re-sourcing
if [ -n "${LIB_OUTPUT_LOADED:-}" ]; then
    return 0
fi
export LIB_OUTPUT_LOADED=1

# Source constants if not already sourced
if [ -z "${RED:-}" ] || [ -z "${GREEN:-}" ] || [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# Source timestamp if available (for get_timestamp)
if ! command -v get_timestamp &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/timestamp.sh" 2>/dev/null || true
fi

# ============================================================================
# Error handling and reporting
# ============================================================================

# Error reporting function with context and actionable guidance
# 
# Purpose: Reports errors with context and suggests solutions
# 
# Parameters:
#   $1 - Error message (required)
#   $2 - Exit code (optional, default: 1)
# 
# Returns: Exit code (for use with ||)
# 
# Side effects: Prints error message to stderr
# 
# Example:
#   err "Failed to create symlink" 1 || return 1
#   err "File not found: $file. Run with --verbose for details." 2
# 
# Error message format: "Error [script] (timestamp): message"
# Include actionable guidance in the message (e.g., "Try: command --help")
err() {
    local message="$1"
    local exit_code="${2:-1}"
    local script_name="${0##*/}"
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    echo -e "${RED}Error [$script_name] ($timestamp): $message${NC}" >&2
    return "$exit_code"
}

# Fatal error function that shows line number and exits
# 
# Purpose: Reports fatal errors with line number, call stack, and exits the script
# 
# Parameters:
#   $1 - Error message (required, should include actionable guidance)
#   $2 - Exit code (optional, default: 1)
# 
# Returns: Never returns (exits script)
# 
# Side effects: Prints error message to stderr and exits script
# 
# Example:
#   die "Failed to create directory: $dir. Check permissions and try again." 1
#   die "Required command 'stow' not found. Install with: brew install stow" 1
# 
# Error message format: "Fatal Error [script:line] (timestamp): message [Call stack: ...]"
# Always include actionable guidance in fatal error messages
die() {
    local message="$1"
    local exit_code="${2:-1}"
    local script_name="${0##*/}"
    local line_number
    
    # Get line number with better context
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh: use $LINENO or funcfiletrace
        line_number="${LINENO:-?}"
    else
        # Bash: use BASH_LINENO array
        if [ -n "${BASH_LINENO[0]:-}" ]; then
            line_number="${BASH_LINENO[0]}"
        else
            line_number="${LINENO:-?}"
        fi
    fi
    
    # Use get_timestamp if available
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local call_stack
    call_stack=$(get_call_stack)
    
    local full_message="Fatal Error [$script_name:$line_number] ($timestamp): $message"
    if [ -n "$call_stack" ]; then
        full_message="${full_message} [Call stack: $call_stack]"
    fi
    
    echo -e "${RED}${full_message}${NC}" >&2
    exit "$exit_code"
}

# Warning function
# Usage: warn <message>
# Example: warn "Package already installed"
warn() {
    local message="$1"
    local script_name="${0##*/}"
    # Use get_timestamp if available
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    echo -e "${YELLOW}Warning [$script_name] ($timestamp): $message${NC}" >&2
}

# Info function
# Usage: info <message>
# Example: info "Starting installation"
info() {
    local message="$1"
    local script_name="${0##*/}"
    # Use get_timestamp if available
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    echo -e "${GREEN}Info [$script_name] ($timestamp): $message${NC}"
}

# Get function call stack for error reporting
# 
# Purpose: Builds a human-readable function call stack for error context
# 
# Parameters: None
# 
# Returns: Call stack string via echo
# 
# Side effects: None
# 
# Example:
#   stack=$(get_call_stack)
#   echo "Call stack: $stack"
get_call_stack() {
    local stack=""
    
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh uses funcfiletrace array
        if [ -n "${funcfiletrace[@]:-}" ]; then
            local i
            for i in "${funcfiletrace[@]}"; do
                if [ -n "$stack" ]; then
                    stack="${stack} -> "
                fi
                stack="${stack}${i}"
            done
        fi
    else
        # Bash uses FUNCNAME and BASH_SOURCE arrays
        if [ -n "${FUNCNAME[@]:-}" ] && [ ${#FUNCNAME[@]} -gt 1 ]; then
            local i
            # Skip first element (current function) and last (main)
            for ((i=1; i<${#FUNCNAME[@]}-1; i++)); do
                if [ -n "$stack" ]; then
                    stack="${stack} -> "
                fi
                local func="${FUNCNAME[$i]}"
                local file="${BASH_SOURCE[$i]##*/}"
                local line="${BASH_LINENO[$i-1]}"
                stack="${stack}${func}(${file}:${line})"
            done
        fi
    fi
    
    echo -n "$stack"
}

