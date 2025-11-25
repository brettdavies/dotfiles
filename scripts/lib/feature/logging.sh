#!/usr/bin/env bash
# Structured logging system
# Provides functions for logging to files with timestamps and log levels
# Requires: core/constants.sh (for colors), util/args.sh (for VERBOSE flag), util/timestamp.sh (for get_timestamp)

# Prevent re-sourcing
if [ -n "${LIB_LOGGING_LOADED:-}" ]; then
    return 0
fi
export LIB_LOGGING_LOADED=1

# Source constants if not already sourced
if [ -z "${RED:-}" ] || [ -z "${GREEN:-}" ] || [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# Ensure VERBOSE variable exists (default to false if not set)
: "${VERBOSE:=false}"

# ============================================================================
# Structured logging system
# ============================================================================

# Global logging variables
LOG_FILE=""
LOG_ENABLED=false

# Initialize logging system
# 
# Purpose: Sets up structured logging to a file with header information
# 
# Parameters:
#   $1 - Log file path (optional, if not provided logging is disabled)
# 
# Returns: Nothing
# 
# Side effects:
#   - Sets LOG_FILE and LOG_ENABLED global variables
#   - Creates log file with header if path is provided
# 
# Example:
#   init_logging "$HOME/.dotfiles-install.log"
#   log_info "Installation started"
init_logging() {
    local log_file="${1:-}"
    if [ -n "$log_file" ]; then
        LOG_FILE="$log_file"
        LOG_ENABLED=true
        # Create log file with header
        {
            echo "=========================================="
            echo "Dotfiles Installation Log"
            # Use get_timestamp if available, otherwise fallback to date
            if command -v get_timestamp &> /dev/null; then
                echo "Started: $(get_timestamp)"
            else
                echo "Started: $(date)"
            fi
            echo "Script: ${0##*/}"
            echo "=========================================="
            echo ""
        } >> "$LOG_FILE"
    fi
}

# Log info message
# 
# Purpose: Logs an informational message with timestamp and script name
# 
# Parameters:
#   $1 - Message to log (required)
# 
# Returns: Nothing
# 
# Side effects:
#   - Writes to log file if logging is enabled
#   - Prints to stdout if VERBOSE is true
# 
# Example:
#   log_info "Package installed successfully"
#   log_info "Creating symlink: $file"
log_info() {
    local message="$1"
    # Use get_timestamp if available, otherwise fallback to date
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local script_name="${0##*/}"
    local log_entry="[INFO] [$script_name] ($timestamp): $message"
    
    if [ "$LOG_ENABLED" = true ] && [ -n "$LOG_FILE" ]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}$log_entry${NC}"
    fi
}

# Log warning message
# 
# Purpose: Logs a warning message with timestamp and script name
# 
# Parameters:
#   $1 - Warning message (required)
# 
# Returns: Nothing
# 
# Side effects:
#   - Writes to log file if logging is enabled
#   - Always prints to stderr (warnings should always be visible)
# 
# Example:
#   log_warn "Package already installed"
#   log_warn "Skipping binary file: $file"
log_warn() {
    local message="$1"
    # Use get_timestamp if available, otherwise fallback to date
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local script_name="${0##*/}"
    local log_entry="[WARN] [$script_name] ($timestamp): $message"
    
    if [ "$LOG_ENABLED" = true ] && [ -n "$LOG_FILE" ]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
    
    echo -e "${YELLOW}$log_entry${NC}" >&2
}

# Log error message
# 
# Purpose: Logs an error message with timestamp and script name
# 
# Parameters:
#   $1 - Error message (required)
# 
# Returns: Nothing
# 
# Side effects:
#   - Writes to log file if logging is enabled
#   - Always prints to stderr (errors should always be visible)
# 
# Example:
#   log_error "Failed to create symlink"
#   log_error "File not found: $file"
log_error() {
    local message="$1"
    # Use get_timestamp if available, otherwise fallback to date
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local script_name="${0##*/}"
    local log_entry="[ERROR] [$script_name] ($timestamp): $message"
    
    if [ "$LOG_ENABLED" = true ] && [ -n "$LOG_FILE" ]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
    
    echo -e "${RED}$log_entry${NC}" >&2
}

# Log debug message
# 
# Purpose: Logs a debug message with timestamp and script name
# 
# Parameters:
#   $1 - Debug message (required)
# 
# Returns: Nothing
# 
# Side effects:
#   - Writes to log file if logging is enabled
#   - Prints to stdout only if VERBOSE is true
# 
# Example:
#   log_debug "Checking package status"
#   log_debug "Cache hit for package: $package"
log_debug() {
    local message="$1"
    # Use get_timestamp if available, otherwise fallback to date
    local timestamp
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp)
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local script_name="${0##*/}"
    local log_entry="[DEBUG] [$script_name] ($timestamp): $message"
    
    if [ "$LOG_ENABLED" = true ] && [ -n "$LOG_FILE" ]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}$log_entry${NC}"
    fi
}

