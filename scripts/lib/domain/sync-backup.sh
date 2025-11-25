#!/usr/bin/env bash
# Sync backup operations
# Provides functions for creating backups and copying files to repo
# Requires: util/paths.sh (for DOTFILES_DIR), fs/file-ops.sh (for safe_mkdir), util/timestamp.sh (for get_timestamp)

# Prevent re-sourcing
if [ -n "${LIB_SYNC_BACKUP_LOADED:-}" ]; then
    return 0
fi
export LIB_SYNC_BACKUP_LOADED=1

# Source dependencies if not already sourced
if [ -z "${DOTFILES_DIR:-}" ]; then
    _SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SOURCE_DIR/../util/paths.sh" 2>/dev/null || true
fi

# ============================================================================
# Backup and Copy Operations
# ============================================================================

# Copy local file to repo location with proper path transformation
# Usage: copy_to_repo <local_file> <repo_file>
# Creates parent directories if needed
copy_to_repo() {
    local local_file="$1"
    local repo_file="$2"
    
    # Create parent directory if needed
    local repo_dir
    repo_dir=$(dirname "$repo_file")
    # Use safe_mkdir if available, otherwise fallback to mkdir
    if command -v safe_mkdir &> /dev/null; then
        safe_mkdir "$repo_dir" "-p" || return 1
    else
        mkdir -p "$repo_dir" || return 1
    fi
    
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
    if command -v get_timestamp &> /dev/null; then
        timestamp=$(get_timestamp '%Y%m%d_%H%M%S')
    else
        timestamp=$(date +%Y%m%d_%H%M%S)
    fi
    local filename
    filename=$(basename "$file")
    local rel_path
    rel_path="${file#$DOTFILES_DIR/}"
    local backup_path="$backup_dir/$rel_path.$timestamp"
    
    # Create backup directory structure
    # Use safe_mkdir if available, otherwise fallback to mkdir
    if command -v safe_mkdir &> /dev/null; then
        safe_mkdir "$(dirname "$backup_path")" "-p" || return 1
    else
        mkdir -p "$(dirname "$backup_path")" || return 1
    fi
    
    # Copy file to backup
    cp "$file" "$backup_path"
    
    echo "$backup_path"
}

