#!/usr/bin/env bash
# Shell version and feature detection library
# Provides functions for detecting shell version and features
# No dependencies (core layer)

# Prevent re-sourcing
if [ -n "${LIB_DETECT_SHELL_LOADED:-}" ]; then
    return 0
fi
export LIB_DETECT_SHELL_LOADED=1

# ============================================================================
# Bash Version Detection
# ============================================================================

# Get Bash version string (major.minor.patch)
# 
# Purpose: Extracts and returns the Bash version as a string
# 
# Parameters: None
# 
# Returns: Version string in format "major.minor" (e.g., "5.2")
#   Echoes result to stdout (use with command substitution)
# 
# Side effects: None
# 
# Example:
#   version=$(get_bash_version)
#   echo "Bash version: $version"
get_bash_version() {
    if [ -z "${BASH_VERSION:-}" ]; then
        echo -n "0.0"
        return 1
    fi
    
    # Extract major.minor from BASH_VERSION (format: "5.2.0(1)-release")
    local version="${BASH_VERSION%%.*}"
    local rest="${BASH_VERSION#*.}"
    local minor="${rest%%.*}"
    
    echo -n "${version}.${minor}"
}

# Compare Bash version with a target version
# 
# Purpose: Compares current Bash version with a target version
# 
# Parameters:
#   $1 - Target version string (e.g., "5.2")
#   $2 - Comparison operator: "ge" (>=), "gt" (>), "le" (<=), "lt" (<), "eq" (==)
# 
# Returns: 0 if comparison is true, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if compare_bash_version "5.2" "ge"; then
#       echo "Bash 5.2 or newer"
#   fi
compare_bash_version() {
    local target="$1"
    local op="${2:-ge}"
    local current
    current=$(get_bash_version)
    
    if [ -z "$current" ] || [ "$current" = "0.0" ]; then
        return 1
    fi
    
    # Convert versions to comparable integers (major * 100 + minor)
    local current_major="${current%%.*}"
    local current_minor="${current#*.}"
    local target_major="${target%%.*}"
    local target_minor="${target#*.}"
    
    local current_int=$((current_major * 100 + current_minor))
    local target_int=$((target_major * 100 + target_minor))
    
    case "$op" in
        ge) [ "$current_int" -ge "$target_int" ] ;;
        gt) [ "$current_int" -gt "$target_int" ] ;;
        le) [ "$current_int" -le "$target_int" ] ;;
        lt) [ "$current_int" -lt "$target_int" ] ;;
        eq) [ "$current_int" -eq "$target_int" ] ;;
        *) return 1 ;;
    esac
}

# Check if Bash version is 5.2 or newer
# 
# Purpose: Determines if running under Bash 5.2+
# 
# Parameters: None
# 
# Returns: 0 if Bash 5.2+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_5_2_plus; then
#       echo "Using Bash 5.2+ features"
#   fi
is_bash_5_2_plus() {
    compare_bash_version "5.2" "ge"
}

# Check if Bash version is 5.1 or newer
# 
# Purpose: Determines if running under Bash 5.1+
# 
# Parameters: None
# 
# Returns: 0 if Bash 5.1+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_5_1_plus; then
#       echo "Using Bash 5.1+ features"
#   fi
is_bash_5_1_plus() {
    compare_bash_version "5.1" "ge"
}

# Check if Bash version is 5.0 or newer
# 
# Purpose: Determines if running under Bash 5.0+
# 
# Parameters: None
# 
# Returns: 0 if Bash 5.0+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_5_0_plus; then
#       echo "Using Bash 5.0+ features"
#   fi
is_bash_5_0_plus() {
    compare_bash_version "5.0" "ge"
}

# Check if Bash version is 4.4 or newer
# 
# Purpose: Determines if running under Bash 4.4+
# 
# Parameters: None
# 
# Returns: 0 if Bash 4.4+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_4_4_plus; then
#       echo "Using Bash 4.4+ features"
#   fi
is_bash_4_4_plus() {
    compare_bash_version "4.4" "ge"
}

# Check if Bash version is 4.3 or newer
# 
# Purpose: Determines if running under Bash 4.3+
# 
# Parameters: None
# 
# Returns: 0 if Bash 4.3+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_4_3_plus; then
#       echo "Using Bash 4.3+ features"
#   fi
is_bash_4_3_plus() {
    compare_bash_version "4.3" "ge"
}

# Check if Bash version is 4.0 or newer
# 
# Purpose: Determines if running under Bash 4.0+
#   This function already exists in detect_os() but is provided here for consistency
# 
# Parameters: None
# 
# Returns: 0 if Bash 4+, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if is_bash_4_plus; then
#       echo "Using Bash 4+ features"
#   fi
is_bash_4_plus() {
    compare_bash_version "4.0" "ge"
}

# ============================================================================
# Feature Detection
# ============================================================================

# Check if nameref variables are supported
# 
# Purpose: Tests if the shell supports nameref variables (declare -n / local -n)
#   Namerefs are available in Bash 4.3+ and zsh
# 
# Parameters: None
# 
# Returns: 0 if nameref is supported, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if has_nameref_support; then
#       local -n array_ref="$1"
#   fi
has_nameref_support() {
    # Check if is_zsh function exists (from detect-os.sh)
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh always supports namerefs via typeset -n
        return 0
    fi
    
    # Test if declare -n works (Bash 4.3+)
    local test_ref
    if declare -n test_ref 2>/dev/null; then
        return 0
    fi
    return 1
}

# Check if wait -n is supported
# 
# Purpose: Tests if the shell supports wait -n (wait for any background process)
#   Available in Bash 5.1+
# 
# Parameters: None
# 
# Returns: 0 if wait -n is supported, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if has_wait_n_support; then
#       wait -n
#   fi
has_wait_n_support() {
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh doesn't have wait -n, but has wait for any process differently
        return 1
    fi
    
    # wait -n is available in Bash 5.1+
    is_bash_5_1_plus
}

# Check if BASH_XTRACEFD is supported
# 
# Purpose: Tests if the shell supports BASH_XTRACEFD for debug output redirection
#   Available in Bash 5.1+
# 
# Parameters: None
# 
# Returns: 0 if BASH_XTRACEFD is supported, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if has_xtracefd_support; then
#       exec {BASH_XTRACEFD}>debug.log
#   fi
has_xtracefd_support() {
    if command -v is_zsh &> /dev/null && is_zsh; then
        # BASH_XTRACEFD is Bash-specific
        return 1
    fi
    
    # BASH_XTRACEFD is available in Bash 5.1+
    is_bash_5_1_plus
}

# Check if mapfile with null delimiter is supported
# 
# Purpose: Tests if mapfile -d '' (null delimiter) is supported
#   Available in Bash 4.4+
# 
# Parameters: None
# 
# Returns: 0 if mapfile -d is supported, 1 otherwise
# 
# Side effects: None
# 
# Example:
#   if has_mapfile_null_delim; then
#       mapfile -d '' -t array < <(find . -print0)
#   fi
has_mapfile_null_delim() {
    if command -v is_zsh &> /dev/null && is_zsh; then
        # Zsh has different array reading mechanisms
        return 1
    fi
    
    # mapfile -d '' is available in Bash 4.4+
    is_bash_4_4_plus
}

# ============================================================================
# Initialize Bash Feature Flags
# ============================================================================

# Initialize Bash feature flags after shell detection
# These flags indicate which features are available based on shell version
# They are exported as environment variables for use by scripts
# This initialization happens automatically when detect-shell.sh is loaded
if ! is_zsh; then
    # Bash feature flags
    export BASH_5_2_PLUS=false
    export BASH_5_1_PLUS=false
    export BASH_5_0_PLUS=false
    export BASH_4_4_PLUS=false
    export BASH_4_3_PLUS=false
    export BASH_4_PLUS=false
    
    if is_bash_5_2_plus; then
        export BASH_5_2_PLUS=true
        export BASH_5_1_PLUS=true
        export BASH_5_0_PLUS=true
        export BASH_4_4_PLUS=true
        export BASH_4_3_PLUS=true
        export BASH_4_PLUS=true
    elif is_bash_5_1_plus; then
        export BASH_5_1_PLUS=true
        export BASH_5_0_PLUS=true
        export BASH_4_4_PLUS=true
        export BASH_4_3_PLUS=true
        export BASH_4_PLUS=true
    elif is_bash_5_0_plus; then
        export BASH_5_0_PLUS=true
        export BASH_4_4_PLUS=true
        export BASH_4_3_PLUS=true
        export BASH_4_PLUS=true
    elif is_bash_4_4_plus; then
        export BASH_4_4_PLUS=true
        export BASH_4_3_PLUS=true
        export BASH_4_PLUS=true
    elif is_bash_4_3_plus; then
        export BASH_4_3_PLUS=true
        export BASH_4_PLUS=true
    elif is_bash_4_plus; then
        export BASH_4_PLUS=true
    fi
fi

