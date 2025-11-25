#!/usr/bin/env bash
# Progress indicator functions using ConEmu OSC 9;4 escape sequence protocol
# Provides standardized progress reporting for terminal emulators
# Requires: core/constants.sh (for colors), util/args.sh (for VERBOSE, NO_PROGRESS flags)

# Prevent re-sourcing
if [ -n "${LIB_PROGRESS_LOADED:-}" ]; then
    return 0
fi
export LIB_PROGRESS_LOADED=1

# Source constants if not already sourced
if [ -z "${YELLOW:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# Global progress state
PROGRESS_ENABLED=true
PROGRESS_INDETERMINATE=false
PROGRESS_CURRENT=0

# Check if progress indicators should be disabled
# Usage: is_progress_enabled
# Returns: 0 if enabled, 1 if disabled
is_progress_enabled() {
    # Check for --no-progress flag or if output is not a terminal
    if [ "${NO_PROGRESS:-false}" = "true" ]; then
        return 1
    fi
    # In test environments, allow progress if NO_PROGRESS is explicitly false
    # even if stdout is not a terminal
    if [ "${NO_PROGRESS:-}" = "false" ]; then
        return 0
    fi
    if [ ! -t 1 ]; then
        return 1  # Not a terminal
    fi
    return 0
}

# Send OSC 7 escape sequence (current directory reporting)
# Format: \033]7;file://hostname/path\033\\
# Usage: _send_osc7_directory
_send_osc7_directory() {
    if ! is_progress_enabled; then
        return 0
    fi
    
    local hostname="${HOSTNAME:-${HOST:-localhost}}"
    printf '\033]7;file://%s%s\033\\' "$hostname" "$PWD" >&2
}

# Send ConEmu OSC 9;4 escape sequence
# Format: \033]9;4;<state>;<progress>\033\\
# state: 0=idle, 1=active, 2=complete, 3=error
# progress: 0-100 (percentage)
# Usage: _send_progress_sequence <state> <progress>
_send_progress_sequence() {
    local state="$1"
    local progress="${2:-0}"
    
    if ! is_progress_enabled; then
        return 0
    fi
    
    # Ensure progress is between 0 and 100
    if [ "$progress" -lt 0 ]; then
        progress=0
    elif [ "$progress" -gt 100 ]; then
        progress=100
    fi
    
    # Send OSC 7 directory update along with progress
    _send_osc7_directory
    
    # Send escape sequence
    printf "\033]9;4;%d;%d\033\\" "$state" "$progress" >&2
}

# Initialize progress tracking
# Usage: progress_start [message]
# Example: progress_start "Installing packages..."
progress_start() {
    local message="${1:-}"
    PROGRESS_CURRENT=0
    PROGRESS_INDETERMINATE=false
    
    if ! is_progress_enabled; then
        [ -n "$message" ] && echo "$message" >&2
        return 0
    fi
    
    _send_progress_sequence 1 0  # state=1 (active), progress=0
    
    if [ -n "$message" ] && [ "${VERBOSE:-false}" != true ]; then
        echo "$message" >&2
    fi
}

# Update progress percentage
# Usage: progress_update <percentage> [message]
# Example: progress_update 50 "Halfway done..."
progress_update() {
    local percentage="$1"
    local message="${2:-}"
    
    PROGRESS_CURRENT="$percentage"
    PROGRESS_INDETERMINATE=false
    
    if ! is_progress_enabled; then
        [ -n "$message" ] && echo "$message" >&2
        return 0
    fi
    
    _send_progress_sequence 1 "$percentage"  # state=1 (active)
    
    if [ -n "$message" ] && [ "${VERBOSE:-false}" != true ]; then
        echo "$message" >&2
    fi
}

# Mark progress as complete
# Usage: progress_complete [message]
# Example: progress_complete "Installation complete!"
progress_complete() {
    local message="${1:-}"
    
    PROGRESS_INDETERMINATE=false
    
    if ! is_progress_enabled; then
        [ -n "$message" ] && echo "$message" >&2
        return 0
    fi
    
    _send_progress_sequence 2 100  # state=2 (complete), progress=100
    
    if [ -n "$message" ] && [ "${VERBOSE:-false}" != true ]; then
        echo "$message" >&2
    fi
}

# Mark progress as error
# Usage: progress_error [message]
# Example: progress_error "Installation failed!"
progress_error() {
    local message="${1:-}"
    
    PROGRESS_INDETERMINATE=false
    
    if ! is_progress_enabled; then
        [ -n "$message" ] && echo "$message" >&2
        return 0
    fi
    
    _send_progress_sequence 3 "$PROGRESS_CURRENT"  # state=3 (error), keep current progress
    
    if [ -n "$message" ]; then
        echo "$message" >&2
    fi
}

# Start indeterminate progress (spinner)
# Usage: progress_indeterminate [message]
# Example: progress_indeterminate "Processing..."
progress_indeterminate() {
    local message="${1:-}"
    
    PROGRESS_INDETERMINATE=true
    
    if ! is_progress_enabled; then
        [ -n "$message" ] && echo "$message" >&2
        return 0
    fi
    
    # For indeterminate progress, we use state=1 (active) with progress=0
    # Some terminals may show a spinner for this
    _send_progress_sequence 1 0  # state=1 (active), progress=0
    
    if [ -n "$message" ] && [ "${VERBOSE:-false}" != true ]; then
        echo "$message" >&2
    fi
}

# Stop progress indicator
# Usage: progress_stop
# Example: progress_stop
progress_stop() {
    if ! is_progress_enabled; then
        return 0
    fi
    
    _send_progress_sequence 0 0  # state=0 (idle), progress=0
    PROGRESS_INDETERMINATE=false
    PROGRESS_CURRENT=0
}

# Calculate progress percentage from current and total
# Usage: calculate_progress <current> <total>
# Returns: percentage (0-100) via echo
# Example: progress=$(calculate_progress 5 10)  # Returns 50
calculate_progress() {
    local current="$1"
    local total="$2"
    
    if [ "$total" -eq 0 ]; then
        echo -n "0"
        return 0
    fi
    
    local percentage=$((current * 100 / total))
    echo -n "$percentage"
}

# Update progress based on current item and total items
# Usage: progress_update_item <current> <total> [message_template]
# Example: progress_update_item 5 10 "Installing package %d of %d..."
progress_update_item() {
    local current="$1"
    local total="$2"
    local message_template="${3:-}"
    
    local percentage
    percentage=$(calculate_progress "$current" "$total")
    
    local message=""
    if [ -n "$message_template" ]; then
        message=$(printf "$message_template" "$current" "$total")
    fi
    
    progress_update "$percentage" "$message"
}

