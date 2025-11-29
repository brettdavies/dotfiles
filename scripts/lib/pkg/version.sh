#!/usr/bin/env bash
# Version comparison functions
# Provides functions for comparing and getting package versions
# Requires: pkg/version-constraints.sh (for version_lt, used by validate_package_version)

# Prevent re-sourcing
if [ -n "${LIB_PKG_VERSION_LOADED:-}" ]; then
    return 0
fi
export LIB_PKG_VERSION_LOADED=1

# ============================================================================
# Version comparison and validation functions
# ============================================================================

# Compare version strings (semantic versioning)
# Parameters: $1 - version to check, $2 - version to compare against
# Returns: 0 if version >= compare_version, 1 otherwise
version_ge() {
    local version="$1"
    local compare_version="$2"
    
    # Split versions into arrays
    IFS='.' read -ra version_parts <<< "$version"
    IFS='.' read -ra compare_parts <<< "$compare_version"
    
    # Compare major version
    if [ "${version_parts[0]}" -gt "${compare_parts[0]}" ]; then
        return 0
    elif [ "${version_parts[0]}" -lt "${compare_parts[0]}" ]; then
        return 1
    fi
    
    # Major version equal, check minor
    if [ "${version_parts[1]:-0}" -gt "${compare_parts[1]:-0}" ]; then
        return 0
    elif [ "${version_parts[1]:-0}" -lt "${compare_parts[1]:-0}" ]; then
        return 1
    fi
    
    # Minor version equal, check patch if both have it
    if [ -n "${version_parts[2]:-}" ] && [ -n "${compare_parts[2]:-}" ]; then
        if [ "${version_parts[2]}" -ge "${compare_parts[2]}" ]; then
            return 0
        else
            return 1
        fi
    fi
    
    # If we get here, versions are equal at the compared level
    return 0
}

# Compare version strings (semantic versioning)
# Parameters: $1 - version to check, $2 - version to compare against
# Returns: 0 if version <= compare_version, 1 otherwise
version_le() {
    local version="$1"
    local compare_version="$2"
    
    # Split versions into arrays
    IFS='.' read -ra version_parts <<< "$version"
    IFS='.' read -ra compare_parts <<< "$compare_version"
    
    # Compare major version
    if [ "${version_parts[0]}" -lt "${compare_parts[0]}" ]; then
        return 0
    elif [ "${version_parts[0]}" -gt "${compare_parts[0]}" ]; then
        return 1
    fi
    
    # Major version equal, check minor
    if [ "${version_parts[1]:-0}" -lt "${compare_parts[1]:-0}" ]; then
        return 0
    elif [ "${version_parts[1]:-0}" -gt "${compare_parts[1]:-0}" ]; then
        return 1
    fi
    
    # Minor version equal, check patch if both have it
    if [ -n "${version_parts[2]:-}" ] && [ -n "${compare_parts[2]:-}" ]; then
        if [ "${version_parts[2]}" -le "${compare_parts[2]}" ]; then
            return 0
        else
            return 1
        fi
    fi
    
    # If we get here, versions are equal at the compared level
    return 0
}

# Helper function for version less than comparison
# Parameters: $1 - version to check, $2 - version to compare against
# Returns: 0 if version < compare_version, 1 otherwise
version_lt() {
    local version="$1"
    local compare_version="$2"
    
    # Use version_le and check they're not equal
    if version_le "$version" "$compare_version"; then
        # Check if they're equal
        if version_ge "$version" "$compare_version"; then
            return 1  # Equal, so not less than
        else
            return 0  # Less than
        fi
    else
        return 1  # Greater than or equal
    fi
}

# Get installed version of a Homebrew package
# Parameters: $1 - package name
# Returns: version string via echo, or empty string if not found/installed
get_brew_package_version() {
    local pkg="$1"
    
    if ! command -v brew &> /dev/null; then
        echo ""
        return 1
    fi
    
    # Check if package is installed
    if ! brew list "$pkg" &>/dev/null 2>&1; then
        echo ""
        return 1
    fi
    
    # Get version info
    local version_info
    version_info=$(brew info "$pkg" 2>/dev/null | grep -E "^$pkg:" | head -n1)
    
    if [ -z "$version_info" ]; then
        echo ""
        return 1
    fi
    
    # Extract version (format: "package: version")
    if [[ "$version_info" =~ ^[^:]+:[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?(-[^[:space:]]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    echo ""
    return 1
}

# Get installed version of a Homebrew cask
# Parameters: $1 - cask name
# Returns: version string via echo, or empty string if not found/installed
get_brew_cask_version() {
    local cask="$1"
    
    if ! command -v brew &> /dev/null; then
        echo ""
        return 1
    fi
    
    # Check if cask is installed
    if ! brew list --cask "$cask" &>/dev/null 2>&1; then
        echo ""
        return 1
    fi
    
    # Get version info
    local version_info
    version_info=$(brew info --cask "$cask" 2>/dev/null | grep -E "^$cask:" | head -n1)
    
    if [ -z "$version_info" ]; then
        echo ""
        return 1
    fi
    
    # Extract version (format: "cask: version")
    if [[ "$version_info" =~ ^[^:]+:[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?(-[^[:space:]]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    echo ""
    return 1
}

# Validate package version against min/max constraints
# Parameters: $1 - installed version, $2 - min_version (optional), $3 - max_version (optional), $4 - max_exclusive (optional, default false)
# Returns: 0 if valid, 1 if invalid
# Note: When max_version comes from caret expansion (e.g., "5.3.0" for "5.2^"), it represents an exclusive upper bound
validate_package_version() {
    local installed_version="$1"
    local min_version="${2:-}"
    local max_version="${3:-}"
    local max_exclusive="${4:-false}"
    
    # If no version constraints, always valid
    if [ -z "$min_version" ] && [ -z "$max_version" ]; then
        return 0
    fi
    
    # If installed version is empty, can't validate (package not installed)
    if [ -z "$installed_version" ]; then
        return 1
    fi
    
    # Check min_version
    if [ -n "$min_version" ]; then
        if ! version_ge "$installed_version" "$min_version"; then
            return 1
        fi
    fi
    
    # Check max_version
    if [ -n "$max_version" ]; then
        if [ "$max_exclusive" = "true" ]; then
            # Use exclusive comparison (<) for caret-expanded max versions
            if ! version_lt "$installed_version" "$max_version"; then
                return 1
            fi
        else
            # Use inclusive comparison (<=) for regular max versions
            if ! version_le "$installed_version" "$max_version"; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# Query Homebrew for available versions of a package
# Parameters: $1 - package/cask name, $2 - type ("package" or "cask")
# Returns: list of available versions via echo (one per line), empty on failure
query_brew_versions() {
    local name="$1"
    local type="${2:-package}"
    
    if ! command -v brew &> /dev/null; then
        return 1
    fi
    
    local json_output
    local brew_cmd
    
    if [ "$type" = "cask" ]; then
        brew_cmd="brew info --cask --json=v1"
    else
        brew_cmd="brew info --json=v1"
    fi
    
    # Query Homebrew for package info
    json_output=$($brew_cmd "$name" 2>/dev/null)
    
    if [ -z "$json_output" ]; then
        return 1
    fi
    
    # Check if jq is available for JSON parsing
    if ! command -v jq &> /dev/null; then
        # Fallback: try to extract version from brew info text output
        local info_output
        if [ "$type" = "cask" ]; then
            info_output=$(brew info --cask "$name" 2>/dev/null)
        else
            info_output=$(brew info "$name" 2>/dev/null)
        fi
        
        # Extract version from "name: version" line
        if [[ "$info_output" =~ ^[^:]+:[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?(-[^[:space:]]+)?) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
        return 1
    fi
    
    # Parse JSON to extract versions
    # Homebrew JSON structure: [{"name":"package","versions":{"stable":"1.2.3",...},...}]
    local stable_version
    stable_version=$(echo "$json_output" | jq -r '.[0].versions.stable // empty' 2>/dev/null)
    
    if [ -n "$stable_version" ] && [ "$stable_version" != "null" ]; then
        echo "$stable_version"
        return 0
    fi
    
    # If no stable version, try to get any version field
    local any_version
    any_version=$(echo "$json_output" | jq -r '.[0].versions | to_entries[0].value // empty' 2>/dev/null)
    
    if [ -n "$any_version" ] && [ "$any_version" != "null" ]; then
        echo "$any_version"
        return 0
    fi
    
    return 1
}

# Find the latest version from a list that matches the constraint
# Parameters: $1 - version list (newline-separated), $2 - min_version, $3 - max_version
# Returns: latest matching version via echo, or empty if none found
find_matching_version() {
    local version_list="$1"
    local min_version="${2:-}"
    local max_version="${3:-}"
    local latest_version=""
    local latest_valid=false
    
    if [ -z "$version_list" ]; then
        return 1
    fi
    
    # If no constraints, return the first (assumed latest) version
    if [ -z "$min_version" ] && [ -z "$max_version" ]; then
        echo "$version_list" | head -n1
        return 0
    fi
    
    # Process each version in the list
    while IFS= read -r version; do
        [ -z "$version" ] && continue
        
        # Clean up version string (remove leading/trailing whitespace)
        version="${version#"${version%%[![:space:]]*}"}"  # trim leading
        version="${version%"${version##*[![:space:]]}"}"  # trim trailing
        
        # Check if version matches constraints
        local matches=true
        
        if [ -n "$min_version" ]; then
            if ! version_ge "$version" "$min_version"; then
                matches=false
            fi
        fi
        
        if [ "$matches" = true ] && [ -n "$max_version" ]; then
            # For max_version from caret expansion (X.(Y+1).0), we want < comparison
            # So we check if version < max_version
            if ! version_lt "$version" "$max_version"; then
                matches=false
            fi
        fi
        
        if [ "$matches" = true ]; then
            # This version matches, check if it's newer than current latest
            if [ "$latest_valid" = false ]; then
                latest_version="$version"
                latest_valid=true
            elif version_ge "$version" "$latest_version"; then
                latest_version="$version"
            fi
        fi
    done <<< "$version_list"
    
    if [ "$latest_valid" = true ]; then
        echo "$latest_version"
        return 0
    fi
    
    return 1
}

# ============================================================================
# Dependency checking functions
# ============================================================================

# Extract version from command output using regex pattern
# Parameters: $1 - command name or path (e.g., "bash", "/bin/bash", "yq")
#             $2 - version flag (e.g., "--version", "-v")
#             $3 - regex pattern to extract version (e.g., `version[[:space:]]+v?([0-9]+\.[0-9]+(\.[0-9]+)?)`)
#             $4 - optional: additional command arguments
# Returns: version string via echo, empty string if not found
extract_version_from_command() {
    local cmd="$1"
    local version_flag="$2"
    local pattern="$3"
    local extra_args="${4:-}"
    
    # Check if command exists
    if ! command -v "$cmd" &> /dev/null && [ ! -x "$cmd" ]; then
        echo ""
        return 1
    fi
    
    # Build command with version flag
    local full_cmd="$cmd $version_flag"
    [ -n "$extra_args" ] && full_cmd="$full_cmd $extra_args"
    
    # Get version output (first line only)
    local version_output
    version_output=$(eval "$full_cmd" 2>/dev/null | head -n1)
    
    if [ -z "$version_output" ]; then
        echo ""
        return 1
    fi
    
    # Extract version using regex pattern
    if [[ "$version_output" =~ $pattern ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    echo ""
    return 1
}

# Verify installed version meets minimum requirement
# Parameters: $1 - tool name (for logging, e.g., "bash", "yq")
#             $2 - minimum version (e.g., "5.2", "4.0")
#             $3 - command name/path
#             $4 - version flag (e.g., "--version")
#             $5 - version regex pattern
#             $6 - optional: find executable function name (for tools like bash with custom paths)
# Returns: 0 if meets requirement, 1 otherwise
verify_installed_version() {
    local tool_name="$1"
    local min_version="$2"
    local cmd="$3"
    local version_flag="$4"
    local pattern="$5"
    local find_func="${6:-}"
    
    # Use find function if provided (e.g., for bash with custom paths)
    if [ -n "$find_func" ] && command -v "$find_func" &> /dev/null; then
        cmd=$("$find_func")
    fi
    
    # Extract version
    local installed_version
    installed_version=$(extract_version_from_command "$cmd" "$version_flag" "$pattern")
    
    if [ -z "$installed_version" ]; then
        warn "$tool_name was installed but version check failed. Please verify manually."
        return 1
    fi
    
    # Use existing validate_package_version function (reuses version_ge internally)
    if validate_package_version "$installed_version" "$min_version" "" ""; then
        log_info "$tool_name upgraded to version $installed_version"
        return 0
    else
        warn "$tool_name was installed but version $installed_version does not meet requirement >= $min_version"
        return 1
    fi
}

# Check versioned dependency and install/upgrade if needed
# Parameters: $1 - tool name (e.g., "bash", "yq")
#             $2 - minimum version (e.g., "5.2", "4.0")
#             $3 - command name/path (e.g., "bash", "/bin/bash", "yq")
#             $4 - version flag (e.g., "--version")
#             $5 - version regex pattern
#             $6 - install function name (e.g., "install_bash")
#             $7 - upgrade function name (e.g., "upgrade_yq") - optional, uses install if not provided
#             $8 - optional: find executable function name (for tools like bash with custom paths)
# Returns: 0 if satisfied, 1 if missing/needs upgrade
check_versioned_dependency() {
    local tool_name="$1"
    local min_version="$2"
    local cmd="$3"
    local version_flag="$4"
    local pattern="$5"
    local install_func="$6"
    local upgrade_func="${7:-}"
    local find_func="${8:-}"
    
    # Use find function if provided
    if [ -n "$find_func" ] && command -v "$find_func" &> /dev/null; then
        cmd=$("$find_func")
    fi
    
    # Get current version
    local current_version
    current_version=$(extract_version_from_command "$cmd" "$version_flag" "$pattern")
    
    # Check if tool is installed
    if [ -z "$current_version" ]; then
        if [ "${DRY_RUN:-false}" = true ]; then
            verbose_missing "$tool_name" "not found"
            return 1
        else
            log_info "$tool_name not found. Installing..."
            if ! command -v "$install_func" &> /dev/null; then
                err "Install function '$install_func' not found" 1
                return 1
            fi
            "$install_func" || return 1
            verify_installed_version "$tool_name" "$min_version" "$cmd" "$version_flag" "$pattern" "$find_func"
            return $?
        fi
    fi
    
    # Check if version meets minimum requirement (reuses validate_package_version)
    if validate_package_version "$current_version" "$min_version" "" ""; then
        if [ "${VERBOSE:-false}" = true ]; then
            verbose_found "$tool_name" "version $current_version (>= $min_version)"
        elif [ "${DRY_RUN:-false}" != true ]; then
            log_info "$tool_name version $current_version found (meets requirement >= $min_version)"
        fi
        return 0
    fi
    
    # Version is too old, need to install/upgrade
    if [ "${DRY_RUN:-false}" = true ]; then
        verbose_missing "$tool_name" "version $current_version (requires >= $min_version)"
        return 1
    fi
    
    log_info "$tool_name version $current_version found, but requires >= $min_version. Installing/upgrading..."
    
    # Use upgrade function if provided, otherwise use install function
    local upgrade_cmd="${upgrade_func:-$install_func}"
    if ! command -v "$upgrade_cmd" &> /dev/null; then
        err "Upgrade/install function '$upgrade_cmd' not found" 1
        return 1
    fi
    "$upgrade_cmd" || return 1
    verify_installed_version "$tool_name" "$min_version" "$cmd" "$version_flag" "$pattern" "$find_func"
}

# Check simple dependency without version requirements
# Parameters: $1 - tool name (e.g., "GNU Stow")
#             $2 - command name (e.g., "stow")
#             $3 - install function name (e.g., "install_stow")
# Returns: 0 if present, 1 if missing
check_simple_dependency() {
    local tool_name="$1"
    local cmd="$2"
    local install_func="$3"
    
    if ! command -v "$cmd" &> /dev/null; then
        if [ "${DRY_RUN:-false}" = true ]; then
            verbose_missing "$tool_name"
            return 1
        else
            log_info "$tool_name not found. Installing..."
            if ! command -v "$install_func" &> /dev/null; then
                err "Install function '$install_func' not found" 1
                return 1
            fi
            "$install_func" || return 1
        fi
    else
        if [ "${VERBOSE:-false}" = true ]; then
            verbose_found "$tool_name"
        elif [ "${DRY_RUN:-false}" != true ]; then
            log_info "$tool_name found"
        fi
        return 0
    fi
}

