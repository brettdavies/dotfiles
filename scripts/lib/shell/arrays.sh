#!/usr/bin/env bash
# Array manipulation helpers
# Provides functions for array operations with shell compatibility
# Requires: core/detect-shell.sh (for has_nameref_support, has_mapfile_null_delim, is_bash_4_3_plus), core/detect-os.sh (for is_zsh)

# Prevent re-sourcing
if [ -n "${LIB_ARRAYS_LOADED:-}" ]; then
    return 0
fi
export LIB_ARRAYS_LOADED=1

# Source detect-shell if not already sourced
if ! command -v has_nameref_support &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-shell.sh" 2>/dev/null || true
fi

# Source detect-os if not already sourced
if ! command -v is_zsh &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/detect-os.sh" 2>/dev/null || true
fi

# ============================================================================
# Array Manipulation
# ============================================================================

# Assign array to a variable by name (using nameref when available)
# 
# Purpose: Provides a unified interface for array assignment that uses
#   namerefs when available, falling back to eval for older shells
# 
# Parameters:
#   $1 - Array name (without $)
#   $2 - Array values (passed as "${array[@]}")
# 
# Returns: Nothing (populates array via name reference)
# 
# Side effects: Creates/modifies array variable
# 
# Example:
#   local temp=(a b c)
#   assign_to_array target "${temp[@]}"
#   echo "${target[@]}"  # outputs: a b c
# 
# Note: Uses nameref (Bash 4.3+ / zsh) when available, eval fallback otherwise
assign_to_array() {
    local array_name="$1"
    shift
    local values=("$@")
    
    # Use nameref if available (Bash 4.3+ or zsh)
    if has_nameref_support; then
        if is_zsh; then
            # Zsh uses typeset -n for namerefs
            typeset -n array_ref="$array_name"
            array_ref=("${values[@]}")
        else
            # Bash 4.3+ uses local -n or declare -n
            if is_bash_4_3_plus; then
                local -n array_ref="$array_name"
                array_ref=("${values[@]}")
            else
                # Bash 4.0-4.2: use declare -n at function scope
                declare -n array_ref="$array_name"
                array_ref=("${values[@]}")
            fi
        fi
    else
        # Fallback to eval for Bash 3.2 and earlier
        eval "$array_name=(\"\${values[@]}\")"
    fi
}

# Read lines from a file or command into an array
# 
# Purpose: Efficiently reads lines into an array, with zsh optimizations
#   and nameref support when available
# 
# Parameters:
#   $1 - Array name (without $)
#   $2 - File path or command to execute
# 
# Returns: Nothing (populates array via name reference)
# 
# Side effects: Creates/modifies array variable
# 
# Example:
#   read_lines_into_array files "find . -type f"
#   echo "${files[@]}"
# 
# Note: Uses zsh-specific features when available for better performance.
#   Uses nameref (Bash 4.3+) when available, eval fallback for older shells.
read_lines_into_array() {
    local array_name="$1"
    local source="$2"
    local temp_array=()
    
    # Use zsh-specific optimizations if available
    if is_zsh; then
        # Zsh has better array handling
        if [ -f "$source" ]; then
            # Read from file using zsh array assignment with parameter expansion
            # Use (@f) flag to split on newlines, preserving empty lines
            temp_array=("${(@f)$(<"$source")}")
        else
            # Execute command and read output
            temp_array=("${(@f)$(eval "$source" 2>/dev/null)}")
        fi
        # Assign using nameref or direct assignment
        if has_nameref_support; then
            typeset -n array_ref="$array_name"
            array_ref=("${temp_array[@]}")
        else
            eval "${array_name}=(\"\${temp_array[@]}\")"
        fi
        return 0
    fi
    
    # Bash implementation
    # Check if source is a file or a command
    if [ -f "$source" ]; then
        # Read from file
        if has_nameref_support && is_bash_4_3_plus; then
            # Use nameref with readarray (Bash 4.3+)
            local -n array_ref="$array_name"
            readarray -t array_ref < "$source" 2>/dev/null || {
                # Fallback: read manually into temp, then assign
                while IFS= read -r line || [ -n "$line" ]; do
                    temp_array+=("$line")
                done < "$source"
                array_ref=("${temp_array[@]}")
            }
        else
            # Use readarray without nameref (Bash 4.0-4.2) or fallback
            readarray -t "$array_name" < "$source" 2>/dev/null || {
                # Fallback for systems without readarray
                while IFS= read -r line || [ -n "$line" ]; do
                    temp_array+=("$line")
                done < "$source"
                assign_to_array "$array_name" "${temp_array[@]}"
            }
        fi
    else
        # Execute command and read output
        if has_nameref_support && is_bash_4_3_plus; then
            # Use nameref with readarray (Bash 4.3+)
            local -n array_ref="$array_name"
            readarray -t array_ref < <(eval "$source" 2>/dev/null) || {
                # Fallback: read manually into temp, then assign
                while IFS= read -r line || [ -n "$line" ]; do
                    temp_array+=("$line")
                done < <(eval "$source" 2>/dev/null)
                array_ref=("${temp_array[@]}")
            }
        else
            # Use readarray without nameref (Bash 4.0-4.2) or fallback
            readarray -t "$array_name" < <(eval "$source" 2>/dev/null) || {
                # Fallback for systems without readarray
                while IFS= read -r line || [ -n "$line" ]; do
                    temp_array+=("$line")
                done < <(eval "$source" 2>/dev/null)
                assign_to_array "$array_name" "${temp_array[@]}"
            }
        fi
    fi
}

# Read null-delimited lines into an array (for find -print0)
# 
# Purpose: Reads null-delimited output (e.g., from find -print0) into an array
#   Uses nameref when available for better performance and safety
# 
# Parameters:
#   $1 - Array name (without $)
#   $2 - Command to execute (should output null-delimited lines)
# 
# Returns: Nothing (populates array via name reference)
# 
# Side effects: Creates/modifies array variable
# 
# Example:
#   read_null_delimited_into_array files "find . -type f -print0"
#   echo "${files[@]}"
# 
# Note: Uses mapfile -d '' (Bash 4.4+) with nameref (Bash 4.3+) when available.
#   Falls back to manual reading for older shells.
read_null_delimited_into_array() {
    local array_name="$1"
    local command="$2"
    local temp_array=()
    
    # Use zsh-specific handling if available
    if is_zsh; then
        # Zsh can read null-delimited input using (0) parameter expansion flag
        # Read into temp array first, then assign
        temp_array=("${(@0)$(eval "$command" 2>/dev/null)}")
        if has_nameref_support; then
            typeset -n array_ref="$array_name"
            array_ref=("${temp_array[@]}")
        else
            eval "${array_name}=(\"\${temp_array[@]}\")"
        fi
        return 0
    fi
    
    # Bash implementation
    # Use mapfile with null delimiter (Bash 4.4+) and nameref (Bash 4.3+)
    if has_mapfile_null_delim && has_nameref_support && is_bash_4_3_plus; then
        # Best case: mapfile -d '' with nameref (Bash 4.4+)
        local -n array_ref="$array_name"
        mapfile -d '' -t array_ref < <(eval "$command" 2>/dev/null) 2>/dev/null || {
            # Fallback: read manually
            while IFS= read -r -d '' line || [ -n "$line" ]; do
                temp_array+=("$line")
            done < <(eval "$command" 2>/dev/null)
            array_ref=("${temp_array[@]}")
        }
    elif has_mapfile_null_delim; then
        # mapfile -d '' without nameref (Bash 4.4, but < 4.3 for nameref)
        mapfile -d '' -t "$array_name" < <(eval "$command" 2>/dev/null) 2>/dev/null || {
            # Fallback: read manually
            while IFS= read -r -d '' line || [ -n "$line" ]; do
                temp_array+=("$line")
            done < <(eval "$command" 2>/dev/null)
            assign_to_array "$array_name" "${temp_array[@]}"
        }
    else
        # Fallback for systems without mapfile -d ''
        while IFS= read -r -d '' line || [ -n "$line" ]; do
            temp_array+=("$line")
        done < <(eval "$command" 2>/dev/null)
        assign_to_array "$array_name" "${temp_array[@]}"
    fi
}

