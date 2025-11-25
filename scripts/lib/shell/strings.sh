#!/usr/bin/env bash
# String manipulation helpers
# Provides functions for string operations with shell compatibility
# Requires: core/detect-shell.sh (for has_nameref_support), core/detect-os.sh (for is_zsh)

# Prevent re-sourcing
if [ -n "${LIB_STRINGS_LOADED:-}" ]; then
    return 0
fi
export LIB_STRINGS_LOADED=1

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
# String Manipulation
# ============================================================================

# Split a string into an array by delimiter
# 
# Purpose: Splits a string into an array using a delimiter
#   Uses zsh parameter expansion when available for better performance
# 
# Parameters:
#   $1 - Array name (without $) to store results
#   $2 - String to split
#   $3 - Delimiter (default: ",")
# 
# Returns: Nothing (populates array via name reference)
# 
# Side effects: Creates/modifies array variable
# 
# Example:
#   split_string items "a,b,c" ","
#   echo "${items[@]}"  # outputs: a b c
# 
# Note: Uses zsh ${(s:,:)string} when available, fallback for bash
split_string() {
    local array_name="$1"
    local string="$2"
    local delimiter="${3:-,}"
    local temp_array=()
    
    if is_zsh; then
        # Zsh: use (s:) parameter expansion flag
        # Escape delimiter for zsh pattern matching
        local escaped_delim
        # Check if delimiter is a special character that needs escaping
        # Use case statement for bash 3.2 compatibility
        case "$delimiter" in
            ','|';'|':'|'/'|'\'|'*'|'?'|'['|']'|'('|')'|'{'|'}'|'^'|'$'|'|'|'&'|'~'|'#'|'%'|'!'|'@')
                escaped_delim="\\${delimiter}"
                ;;
            *)
                escaped_delim="$delimiter"
                ;;
        esac
        temp_array=("${(@s:${escaped_delim}:)string}")
    else
        # Bash: use IFS and read
        local old_ifs="$IFS"
        IFS="$delimiter"
        read -ra temp_array <<< "$string"
        IFS="$old_ifs"
    fi
    
    # Assign to target array
    if has_nameref_support; then
        if is_zsh; then
            typeset -n array_ref="$array_name"
            array_ref=("${temp_array[@]}")
        else
            local -n array_ref="$array_name"
            array_ref=("${temp_array[@]}")
        fi
    else
        eval "$array_name=(\"\${temp_array[@]}\")"
    fi
}

# Join array elements into a string with delimiter
# 
# Purpose: Joins array elements into a single string with a delimiter
#   Uses zsh parameter expansion when available for better performance
# 
# Parameters:
#   $1 - Array name (without $) or array values
#   $2 - Delimiter (default: ",")
#   $3 - If provided, treat $1 as array name; otherwise treat as values
# 
# Returns: Joined string via echo
# 
# Side effects: None
# 
# Example:
#   items=(a b c)
#   result=$(join_array items ",")
#   echo "$result"  # outputs: a,b,c
# 
# Note: Uses zsh ${(j:,:)array} when available, fallback for bash
join_array() {
    local array_input="$1"
    local delimiter="${2:-,}"
    local is_array_name="${3:-}"
    local array_values=()
    
    if [ -n "$is_array_name" ]; then
        # $1 is array name, need to get values
        if has_nameref_support; then
            if is_zsh; then
                typeset -n array_ref="$array_input"
                array_values=("${array_ref[@]}")
            else
                local -n array_ref="$array_input"
                array_values=("${array_ref[@]}")
            fi
        else
            eval "array_values=(\"\${${array_input}[@]}\")"
        fi
    else
        # Treat remaining args as array values
        shift
        delimiter="${1:-,}"
        shift
        array_values=("$@")
    fi
    
    if is_zsh; then
        # Zsh: use (j:) parameter expansion flag
        # Escape delimiter for zsh pattern
        local escaped_delim
        # Check if delimiter is a special character that needs escaping
        # Use case statement for bash 3.2 compatibility
        case "$delimiter" in
            ','|';'|':'|'/'|'\'|'*'|'?'|'['|']'|'('|')'|'{'|'}'|'^'|'$'|'|'|'&'|'~'|'#'|'%'|'!'|'@')
                escaped_delim="\\${delimiter}"
                ;;
            *)
                escaped_delim="$delimiter"
                ;;
        esac
        echo -n "${(j:${escaped_delim}:)array_values}"
    else
        # Bash: use printf or manual joining
        local first=true
        local result=""
        for item in "${array_values[@]}"; do
            if [ "$first" = true ]; then
                result="$item"
                first=false
            else
                result="${result}${delimiter}${item}"
            fi
        done
        echo -n "$result"
    fi
}

# Convert string to uppercase
# 
# Purpose: Converts a string to uppercase
#   Uses zsh parameter expansion when available (zsh 5.1+)
# 
# Parameters:
#   $1 - String to convert
# 
# Returns: Uppercase string via echo
# 
# Side effects: None
# 
# Example:
#   result=$(uppercase_string "hello")
#   echo "$result"  # outputs: HELLO
# 
# Note: Uses zsh ${string:u} (zsh 5.1+) when available, tr fallback otherwise
uppercase_string() {
    local string="$1"
    
    if is_zsh; then
        # Check zsh version for :u flag (requires zsh 5.1+)
        if [[ "${ZSH_VERSION%%.*}" -ge 5 ]] && [[ "${ZSH_VERSION#*.}" =~ ^[1-9] ]]; then
            # Use zsh parameter expansion
            echo -n "${string:u}"
            return 0
        fi
    fi
    
    # Fallback: use tr
    echo -n "$string" | tr '[:lower:]' '[:upper:]'
}

# Convert string to lowercase
# 
# Purpose: Converts a string to lowercase
#   Uses zsh parameter expansion when available (zsh 5.1+)
# 
# Parameters:
#   $1 - String to convert
# 
# Returns: Lowercase string via echo
# 
# Side effects: None
# 
# Example:
#   result=$(lowercase_string "HELLO")
#   echo "$result"  # outputs: hello
# 
# Note: Uses zsh ${string:l} (zsh 5.1+) when available, tr fallback otherwise
lowercase_string() {
    local string="$1"
    
    if is_zsh; then
        # Check zsh version for :l flag (requires zsh 5.1+)
        if [[ "${ZSH_VERSION%%.*}" -ge 5 ]] && [[ "${ZSH_VERSION#*.}" =~ ^[1-9] ]]; then
            # Use zsh parameter expansion
            echo -n "${string:l}"
            return 0
        fi
    fi
    
    # Fallback: use tr
    echo -n "$string" | tr '[:upper:]' '[:lower:]'
}

