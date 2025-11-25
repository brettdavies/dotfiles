#!/usr/bin/env bash
# Timestamp generation library
# Provides functions for generating timestamps
# Requires: shell/zsh-modules.sh (for zsh datetime module)

# Prevent re-sourcing
if [ -n "${LIB_TIMESTAMP_LOADED:-}" ]; then
    return 0
fi
export LIB_TIMESTAMP_LOADED=1

# Source zsh modules if available (for datetime support)
if command -v is_zsh &> /dev/null && is_zsh; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../shell/zsh-modules.sh" 2>/dev/null || true
fi

# ============================================================================
# Date/Time Helpers
# ============================================================================

# Get formatted timestamp
# 
# Purpose: Returns a formatted timestamp using zsh strftime when available,
#   falling back to external date command
# 
# Parameters:
#   $1 - Format string (optional, default: '%Y-%m-%d %H:%M:%S')
# 
# Returns: Formatted timestamp via echo
# 
# Side effects: None
# 
# Example:
#   timestamp=$(get_timestamp)
#   timestamp=$(get_timestamp '%Y-%m-%d')
# 
# Note: Uses zsh strftime (zsh/datetime) when ZSH_DATETIME_LOADED is set,
#   falls back to external date command otherwise
get_timestamp() {
    local format="${1:-%Y-%m-%d %H:%M:%S}"
    
    # Use zsh strftime if datetime module is loaded
    if command -v is_zsh &> /dev/null && is_zsh && [ -n "${ZSH_DATETIME_LOADED:-}" ]; then
        # zsh strftime(format, epoch_time) - use EPOCHSECONDS for current time
        # EPOCHSECONDS is available when zsh/datetime is loaded
        if [ -n "${EPOCHSECONDS:-}" ]; then
            strftime "$format" "$EPOCHSECONDS" 2>/dev/null || {
                # Fallback if strftime fails
                date "+$format" 2>/dev/null || echo ""
            }
        else
            # Fallback if EPOCHSECONDS not available
            date "+$format" 2>/dev/null || echo ""
        fi
    else
        # Fallback to external date command
        date "+$format" 2>/dev/null || echo ""
    fi
}

# Get epoch timestamp (seconds since 1970-01-01)
# 
# Purpose: Returns epoch timestamp using zsh datetime when available,
#   falling back to external date command
# 
# Parameters: None
# 
# Returns: Epoch timestamp (integer) via echo
# 
# Side effects: None
# 
# Example:
#   epoch=$(get_epoch_timestamp)
# 
# Note: Uses zsh EPOCHSECONDS when ZSH_DATETIME_LOADED is set,
#   falls back to external date +%s otherwise
get_epoch_timestamp() {
    # Use zsh EPOCHSECONDS if datetime module is loaded
    if command -v is_zsh &> /dev/null && is_zsh && [ -n "${ZSH_DATETIME_LOADED:-}" ]; then
        echo -n "${EPOCHSECONDS:-$(date +%s 2>/dev/null || echo 0)}"
    else
        # Fallback to external date command
        date +%s 2>/dev/null || echo "0"
    fi
}

