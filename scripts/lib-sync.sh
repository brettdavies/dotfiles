#!/bin/bash
# Sync-local helper functions
# Provides functions for syncing local changes back into the dotfiles repository
# Requires: lib-core.sh (for DOTFILES_DIR variable)

# Source core library if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    source "$(dirname "$0")/lib-core.sh"
fi

# Detect if a file is binary
# Usage: is_binary_file <file_path>
# Returns: 0 if binary, 1 if text
is_binary_file() {
    local file="$1"
    
    # Check if file exists
    [ -f "$file" ] || return 1
    
    # Use file command if available
    if command -v file &> /dev/null; then
        local file_type
        file_type=$(file -b --mime-type "$file" 2>/dev/null || echo "")
        if [[ "$file_type" =~ ^(image|video|audio|application)/ ]] || [[ "$file_type" == "application/octet-stream" ]]; then
            return 0
        fi
        # Check for text types explicitly
        if [[ "$file_type" =~ ^text/ ]] || [[ "$file_type" == "application/json" ]] || [[ "$file_type" == "application/xml" ]]; then
            return 1
        fi
    fi
    
    # Fallback: check common binary extensions
    local ext="${file##*.}"
    case "$ext" in
        png|jpg|jpeg|gif|bmp|ico|svg|webp|pdf|zip|tar|gz|bz2|xz|exe|dll|so|dylib|bin|o|a|pyc|pyo|class|jar|war|ear|deb|rpm|dmg|pkg|app|ipa|apk)
            return 0
            ;;
    esac
    
    # Default to text file
    return 1
}

# Compare two files
# Usage: compare_files <file1> <file2>
# Returns: 0 if identical, 1 if different
compare_files() {
    local file1="$1"
    local file2="$2"
    
    # Both files must exist
    [ -f "$file1" ] && [ -f "$file2" ] || return 1
    
    # Use cmp for binary-safe comparison
    cmp -s "$file1" "$file2" 2>/dev/null
}

# Show diff between two files in git unified diff format
# Usage: show_file_diff <file1> <file2> [label1] [label2]
# Shows diff in git unified format (like git diff)
show_file_diff() {
    local file1="$1"
    local file2="$2"
    local label1="${3:-a/$file1}"
    local label2="${4:-b/$file2}"
    
    # Use git diff if available (produces better output)
    if command -v git &> /dev/null; then
        git diff --no-index --no-color -- "$file1" "$file2" 2>/dev/null | sed "1s|^---.*|--- $label1|; 2s|^+++.*|+++ $label2|" || true
    else
        # Fallback to diff -u
        diff -u --label "$label1" --label "$label2" "$file1" "$file2" 2>/dev/null || true
    fi
}

# Copy local file to repo location with proper path transformation
# Usage: copy_to_repo <local_file> <repo_file>
# Creates parent directories if needed
copy_to_repo() {
    local local_file="$1"
    local repo_file="$2"
    
    # Create parent directory if needed
    local repo_dir
    repo_dir=$(dirname "$repo_file")
    mkdir -p "$repo_dir"
    
    # Copy file
    cp "$local_file" "$repo_file"
}

# Create backup of a file
# Usage: create_file_backup <file_path>
# Creates backup in .backup/ directory with timestamp
# Returns: backup path via echo
create_file_backup() {
    local file="$1"
    local backup_dir="$DOTFILES_DIR/.backup"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local filename
    filename=$(basename "$file")
    local rel_path
    rel_path="${file#$DOTFILES_DIR/}"
    local backup_path="$backup_dir/$rel_path.$timestamp"
    
    # Create backup directory structure
    mkdir -p "$(dirname "$backup_path")"
    
    # Copy file to backup
    cp "$file" "$backup_path"
    
    echo "$backup_path"
}

# Install diffutils package using system package manager
# Usage: install_diffutils
# Returns: 0 if successful, 1 if failed
install_diffutils() {
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install diffutils
        else
            echo -e "${RED}Error: Homebrew not found. Please install diffutils manually.${NC}"
            return 1
        fi
    elif [[ "$OS" == "linux" ]]; then
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
            echo -e "${RED}Error: Package manager not found. Please install diffutils manually.${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: Unsupported OS. Please install diffutils manually.${NC}"
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
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            install_cmd="brew install diffutils"
        else
            install_cmd="install diffutils via your system's package manager"
        fi
    elif [[ "$OS" == "linux" ]]; then
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
        echo -e "${RED}Error: Non-interactive mode detected. Cannot prompt for installation.${NC}"
        echo -e "${YELLOW}Please install diff3 manually by running: $install_cmd${NC}"
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
            echo -e "${RED}Failed to install diff3. Please install it manually.${NC}"
            echo -e "${YELLOW}You can install it by running: $install_cmd${NC}"
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
        echo -e "${RED}Error: diff3 is required for merge operations but is not available.${NC}" >&2
        return 1
    fi
    
    # Create a temporary base file
    # If the repo file is tracked by git, use the last committed version as the base
    # Otherwise, use an empty file
    local base_file
    base_file=$(mktemp)
    trap "rm -f '$base_file'" EXIT
    
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
        rm -f "$base_file"
        # Check if output contains conflict markers
        if grep -q "^<<<<<<< " "$output_file" 2>/dev/null; then
            return 1  # Conflicts found
        fi
        return 0  # Merge successful
    else
        rm -f "$base_file"
        return 1  # Merge failed
    fi
}

