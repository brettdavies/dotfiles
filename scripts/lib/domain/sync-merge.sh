#!/usr/bin/env bash
# Sync merge operations
# Provides functions for merging files using diff3
# Requires: util/paths.sh (for DOTFILES_DIR, OS), util/output.sh (for err, warn), core/constants.sh (for colors), feature/temp.sh (for create_temp_file)

# Prevent re-sourcing
if [ -n "${LIB_SYNC_MERGE_LOADED:-}" ]; then
    return 0
fi
export LIB_SYNC_MERGE_LOADED=1

# Source dependencies if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# Source output if not already sourced
if ! command -v err &> /dev/null || ! command -v warn &> /dev/null; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/output.sh" 2>/dev/null || true
fi

# Source constants if not already sourced
if [ -z "${YELLOW:-}" ] || [ -z "${GREEN:-}" ] || [ -z "${NC:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../core/constants.sh" 2>/dev/null || true
fi

# ============================================================================
# Merge Operations
# ============================================================================

# Install diffutils package using system package manager
# Usage: install_diffutils
# Returns: 0 if successful, 1 if failed
install_diffutils() {
    if [[ "${OS:-}" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install diffutils
        else
            err "Homebrew not found. Please install diffutils manually: brew install diffutils" 1
            return 1
        fi
    elif [[ "${OS:-}" == "linux" ]]; then
        if command -v apk &> /dev/null; then
            # Alpine Linux
            apk add --no-cache diffutils
        elif command -v apt-get &> /dev/null; then
            # Ubuntu/Debian
            if [ "$EUID" -eq 0 ]; then
                apt-get update && apt-get install -y diffutils
            else
                sudo apt-get update && sudo apt-get install -y diffutils
            fi
        elif command -v yum &> /dev/null; then
            # RHEL/CentOS
            if [ "$EUID" -eq 0 ]; then
                yum install -y diffutils
            else
                sudo yum install -y diffutils
            fi
        elif command -v dnf &> /dev/null; then
            # Fedora
            if [ "$EUID" -eq 0 ]; then
                dnf install -y diffutils
            else
                sudo dnf install -y diffutils
            fi
        else
            err "Package manager not found. Please install diffutils manually. On Debian/Ubuntu: sudo apt-get install diffutils" 1
            return 1
        fi
    else
        err "Unsupported OS. Please install diffutils manually. See your OS documentation for installation instructions." 1
        return 1
    fi
}

# Static variable to track if we've already checked for diff3
_DIFF3_CHECKED=false

# Ensure diff3 is available (check once per script execution)
# Usage: ensure_diff3_available
# Returns: 0 if diff3 is available, 1 if not available (or exits if user quits)
ensure_diff3_available() {
    # Only check if merge mode is enabled
    if [ "${SYNC_MERGE:-false}" != true ]; then
        return 0
    fi
    
    # Only check once
    if [ "$_DIFF3_CHECKED" = true ]; then
        return 0
    fi
    
    _DIFF3_CHECKED=true
    
    # Check if diff3 is available
    if which diff3 &> /dev/null; then
        return 0
    fi
    
    # diff3 not found, call check_diff3 to handle installation
    check_diff3
}

# Check for diff3 and install if needed
# Usage: check_diff3
# Returns: 0 if diff3 is available, 1 if not available (or exits if user quits)
check_diff3() {
    # Check if diff3 is available
    if which diff3 &> /dev/null; then
        return 0
    fi
    
    # diff3 not found
    echo -e "${YELLOW}diff3 not found. It is required for merge operations.${NC}"
    
    # Determine package manager command for user instructions
    local install_cmd=""
    if [[ "${OS:-}" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            install_cmd="brew install diffutils"
        else
            install_cmd="install diffutils via your system's package manager"
        fi
    elif [[ "${OS:-}" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            install_cmd="sudo apt-get install diffutils"
        elif command -v yum &> /dev/null; then
            install_cmd="sudo yum install diffutils"
        elif command -v dnf &> /dev/null; then
            install_cmd="sudo dnf install diffutils"
        elif command -v apk &> /dev/null; then
            install_cmd="apk add diffutils"
        else
            install_cmd="install diffutils via your system's package manager"
        fi
    else
        install_cmd="install diffutils via your system's package manager"
    fi
    
    # Offer to install
    echo -e "${YELLOW}Would you like to install diff3?${NC}"
    
    # Check if we're in an interactive terminal
    if [ ! -t 0 ]; then
        err "Non-interactive mode detected. Cannot prompt for installation. Install diff3 manually or run in interactive mode." 1
        warn "Please install diff3 manually by running: $install_cmd"
        return 1
    fi
    
    read -p "Install diff3? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Installing diffutils...${NC}"
        if install_diffutils; then
            echo -e "${GREEN}diff3 installed successfully.${NC}"
            return 0
        else
            err "Failed to install diff3. Please install it manually. On macOS: brew install diffutils. On Linux: sudo apt-get install diffutils" 1
            warn "You can install it by running: $install_cmd"
            return 1
        fi
    else
        echo -e "${YELLOW}Skipping diff3 installation. Merge operations will not be available.${NC}"
        echo -e "${YELLOW}You can install it later by running: $install_cmd${NC}"
        read -p "Quit script to install diff3? (Y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo -e "${YELLOW}Exiting. Please install diff3 and try again.${NC}"
            exit 1
        else
            echo -e "${YELLOW}Continuing without diff3. Merge operations will not be available.${NC}"
            return 1
        fi
    fi
}

# Merge two files using diff3
# Usage: merge_files <local_file> <repo_file> <output_file>
# Returns: 0 if merge successful, 1 if conflicts or diff3 not available
# Note: Assumes ensure_diff3_available has already been called if merge mode is enabled
merge_files() {
    local local_file="$1"
    local repo_file="$2"
    local output_file="$3"
    
    # diff3 is required for merge operations
    if ! which diff3 &> /dev/null; then
        err "diff3 is required for merge operations but is not available" 1
        return 1
    fi
    
    # Create a temporary base file
    # If the repo file is tracked by git, use the last committed version as the base
    # Otherwise, use an empty file
    local base_file
    if command -v create_temp_file &> /dev/null; then
        base_file=$(create_temp_file "merge-base.XXXXXX")
    else
        base_file=$(mktemp "/tmp/merge-base.XXXXXX" 2>/dev/null || echo "")
        if [ -z "$base_file" ]; then
            err "Failed to create temporary file for merge base" 1
            return 1
        fi
    fi
    
    # Try to get the last committed version from git if the repo is tracked
    if command -v git &> /dev/null; then
        # Get relative path from repo root
        local rel_path="${repo_file#$DOTFILES_DIR/}"
        
        # Check if file is tracked by git and get the last committed version
        if git -C "$DOTFILES_DIR" ls-files --error-unmatch "$rel_path" &> /dev/null; then
            # File is tracked, get the last committed version
            if git -C "$DOTFILES_DIR" show "HEAD:$rel_path" > "$base_file" 2>/dev/null; then
                # Successfully retrieved committed version
                : # base_file now contains the committed version
            else
                # Failed to get committed version, use empty file
                > "$base_file"
            fi
        else
            # File is not tracked, use empty file
            > "$base_file"
        fi
    else
        # Git not available, use empty file
        > "$base_file"
    fi
    
    # Try merge
    if diff3 -m "$local_file" "$base_file" "$repo_file" > "$output_file" 2>/dev/null; then
        # Check if output contains conflict markers
        if grep -q "^<<<<<<< " "$output_file" 2>/dev/null; then
            return 1  # Conflicts found
        fi
        return 0  # Merge successful
    else
        return 1  # Merge failed
    fi
    # Note: base_file cleanup is handled by cleanup_temp_dir via trap
}

