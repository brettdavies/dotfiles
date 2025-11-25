#!/usr/bin/env bash
# Stow all dotfiles packages to create symlinks
#
# Uses stow --dotfiles for all packages except VS Code (see exception in code).
# The --dotfiles option converts dot-* prefixes to .* prefixes automatically.

set -euo pipefail

# Source shared libraries
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/full.sh"

# Parse arguments
parse_common_args "$@"

# Initialize temporary directory for this script execution
init_temp_dir "stow-packages.XXXXXX" >/dev/null
# Setup trap handlers for cleanup and error handling
setup_traps cleanup_temp_dir

# Initialize sync counters
SYNCED_FILES=0
SYNCED_DIRECTORIES=0

# Function to check for conflicts and count what would be done
# Returns conflicts count via global variable CONFLICTS_FOUND
# Returns symlinks count via global variable SYMLINKS_TO_CREATE
CONFLICTS_FOUND=0
SYMLINKS_TO_CREATE=0

check_conflicts_and_symlinks() {
    local package=$1
    local target=$2
    local package_conflicts=0
    local package_symlinks=0
    
    # Find all files in the package directory
    if [ ! -d "$package" ]; then
        return 0  # Package doesn't exist, nothing to check
    fi
    
    # Find files in package directory, but don't follow symlinks (-P flag)
    find -P "$package" -type f | while read -r file; do
        # Get relative path from package directory
        rel_path="${file#$package/}"
        
        # Skip .DS_Store files
        if [[ "$(basename "$rel_path")" == ".DS_Store" ]]; then
            continue
        fi
        
        # Apply --dotfiles transformation: convert dot-* prefixes to .* prefixes
        # Use Bash 4+ pattern replacement instead of sed
        transformed_path="${rel_path//dot-/.}"
        
        # Construct target path with transformed path
        if [[ "$target" == "~" ]]; then
            target_file="$HOME/$transformed_path"
        else
            target_file="$target/$transformed_path"
        fi
        
        # Safety check: Only process files in the home directory, never in the repo
        if [[ -z "$STOW_DIR" ]]; then
            continue
        fi
        
        # Skip if target is not in HOME or if it's in STOW_DIR (the repo)
        if [[ ! "$target_file" =~ ^"$HOME"/ ]] || [[ "$target_file" =~ ^"$STOW_DIR"/ ]]; then
            continue
        fi
        
        # Count symlinks that would be created
        if [ ! -e "$target_file" ]; then
            ((package_symlinks++))
            if [ "$VERBOSE" = true ]; then
                echo "    → Would create: ${target_file#$HOME/} -> ${file#$STOW_DIR/}"
            fi
        elif [ -L "$target_file" ]; then
            # Already a symlink, check if it points to the right place
            local actual_source=$(readlink "$target_file")
            if [[ "$actual_source" != /* ]]; then
                actual_source="$(cd "$(dirname "$target_file")" && pwd)/$actual_source"
            fi
            local expected_source="$file"
            if [ "$actual_source" != "$expected_source" ]; then
                ((package_conflicts++))
                if [ "$VERBOSE" = true ]; then
                    echo -e "    ${YELLOW}⚠ Conflict: ${target_file#$HOME/} exists as symlink pointing elsewhere${NC}"
                fi
            fi
        else
            # Regular file or directory, would be removed
            ((package_conflicts++))
            if [ "$VERBOSE" = true ]; then
                echo -e "    ${YELLOW}⚠ Conflict: ${target_file#$HOME/} exists (not a symlink) - would be removed${NC}"
            fi
        fi
    done
    
    # Update global counters (note: this won't work in subshell, so we'll handle differently)
    CONFLICTS_FOUND=$((CONFLICTS_FOUND + package_conflicts))
    SYMLINKS_TO_CREATE=$((SYMLINKS_TO_CREATE + package_symlinks))
}

# Build target file path from package file
# Usage: build_target_path <package_file> <package_dir> <target_base>
# Returns: target path via echo
build_target_path() {
    local file="$1"
    local package_dir="$2"
    local target_base="$3"
    
    local rel_path="${file#$package_dir/}"
    local transformed_path
    transformed_path=$(transform_dotfiles_path "$rel_path")
    
    if [[ "$target_base" == "~" ]]; then
        echo "$HOME/$transformed_path"
    else
        echo "$target_base/$transformed_path"
    fi
}

# Validate target path is safe to process
# Usage: is_safe_target_path <target_path>
# Returns: 0 if safe, 1 if not
is_safe_target_path() {
    local target_path="$1"
    
    # Safety check: STOW_DIR must be set
    [[ -z "${STOW_DIR:-}" ]] && return 1
    
    # Must be in HOME directory
    [[ ! "$target_path" =~ ^"$HOME"/ ]] && return 1
    
    # Must not be in STOW_DIR (the repo)
    [[ "$target_path" =~ ^"$STOW_DIR"/ ]] && return 1
    
    return 0
}

# Check if target file is already correctly symlinked
# Usage: is_already_symlinked <source_file> <target_file>
# Returns: 0 if already symlinked, 1 if not
is_already_symlinked() {
    local source_file="$1"
    local target_file="$2"
    
    [[ "$(realpath "$source_file" 2>/dev/null || echo "$source_file")" == "$(realpath "$target_file" 2>/dev/null || echo "$target_file")" ]]
}

# Remove a single conflicting file
# Usage: remove_conflicting_file <target_file>
remove_conflicting_file() {
    local target_file="$1"
    
    if [ -L "$target_file" ]; then
        # Already a symlink, skip it - stow will handle it
        return 0
    fi
    
    # Regular file or directory, remove it to make way for symlink
    echo "    Removing existing: ${target_file#$HOME/}"
    log_info "Removing existing: ${target_file#$HOME/}"
    if [ "$DRY_RUN" != true ]; then
        rm -rf "$target_file"
    fi
}

# This function handles the --dotfiles transformation (dot-* -> .*)
# and removes conflicting files
remove_conflicting_files() {
    local package=$1
    local target=$2
    
    # Find all files in the package directory
    if [ ! -d "$package" ]; then
        return 0  # Package doesn't exist, nothing to remove
    fi
    
    # Find files in package directory, but don't follow symlinks (-P flag)
    find -P "$package" -type f | while read -r file; do
        local target_file
        target_file=$(build_target_path "$file" "$package" "$target")
        
        # Validate target path is safe
        if ! is_safe_target_path "$target_file"; then
            if [[ -z "${STOW_DIR:-}" ]]; then
                log_error "STOW_DIR not set! Skipping to prevent accidental deletion."
                continue
            fi
            continue
        fi
        
        # If target exists, check what to do
        if [ -e "$target_file" ]; then
            # Check if already correctly symlinked
            if is_already_symlinked "$file" "$target_file"; then
                echo "    SKIP: Already symlinked: ${target_file#$HOME/}"
                log_info "SKIP: Already symlinked: ${target_file#$HOME/}"
                continue
            fi
            
            # Remove conflicting file
            remove_conflicting_file "$target_file"
        fi
    done
}

# Check if a file should be skipped (e.g., .DS_Store)
# Usage: should_skip_file <file_path>
# Returns: 0 if should skip, 1 if not
should_skip_file() {
    local file_path="$1"
    [[ "$(basename "$file_path")" == ".DS_Store" ]]
}

# Check if target path is valid for processing
# Usage: is_valid_target_path <target_path>
# Returns: 0 if valid, 1 if not
is_valid_target_path() {
    local target_path="$1"
    [[ "$target_path" =~ ^"$HOME"/ ]] && [[ ! "$target_path" =~ ^"$STOW_DIR"/ ]]
}

# Check if symlink points to expected source
# Usage: is_symlink_correct <target_file> <expected_source>
# Returns: 0 if correct, 1 if not
is_symlink_correct() {
    local target_file="$1"
    local expected_source="$2"
    
    if [ ! -L "$target_file" ]; then
        return 1
    fi
    
    local actual_source
    actual_source=$(readlink "$target_file")
    if [[ "$actual_source" != /* ]]; then
        local base_dir
        base_dir="$(cd "$(dirname "$target_file")" && pwd)" || return 1
        actual_source="$base_dir/$actual_source"
    fi
    
    local actual_dir expected_dir
    actual_dir="$(cd "$(dirname "$actual_source")" && pwd)" || return 1
    expected_dir="$(cd "$(dirname "$expected_source")" && pwd)" || return 1
    
    [[ "$actual_dir/$(basename "$actual_source")" == "$expected_dir/$(basename "$expected_source")" ]]
}

# Check a single file in dry-run mode and return status
# Usage: check_file_dry_run <file> <package> <target_file>
# Returns: "conflict", "symlink", or "done" via echo
check_file_dry_run() {
    local file="$1"
    local package="$2"
    local target_file="$3"
    
    # Check if any parent directory is a symlink pointing to the stow directory
    if is_parent_dir_symlinked "$target_file" "$package"; then
        if [ -f "$file" ]; then
            verbose_already_setup "${target_file#$HOME/}" "accessible via directory symlink"
            echo "done"
        fi
    elif [ ! -e "$target_file" ]; then
        verbose_would_create "${target_file#$HOME/}" "${file#$STOW_DIR/}"
        echo "symlink"
    elif [ -L "$target_file" ]; then
        if is_symlink_correct "$target_file" "$file"; then
            verbose_already_setup "${target_file#$HOME/}"
            echo "done"
        else
            verbose_conflict "${target_file#$HOME/}" "exists as symlink pointing elsewhere"
            echo "conflict"
        fi
    else
        verbose_conflict "${target_file#$HOME/}" "exists (not a symlink) - would be removed"
        echo "conflict"
    fi
}

# Check package in dry-run mode
# Usage: check_package_dry_run <package> <description>
check_package_dry_run() {
    local package="$1"
    local description="$2"
    local pkg_conflicts=0
    local pkg_symlinks=0
    local pkg_already_done=0
    
    if [ "$VERBOSE" = true ]; then
        echo "  - $description"
    fi
    
    # Use optimized find function
    local files_array
    find_files_array files_array "$STOW_DIR/$package" "-type f"
    for file in "${files_array[@]}"; do
        local rel_path="${file#$STOW_DIR/$package/}"
        
        if should_skip_file "$rel_path"; then
            continue
        fi
        
        local transformed_path
        transformed_path=$(transform_dotfiles_path "$rel_path")
        local target_file="$HOME/$transformed_path"
        
        if ! is_valid_target_path "$target_file"; then
            continue
        fi
        
        local status
        status=$(check_file_dry_run "$file" "$package" "$target_file")
        case "$status" in
            conflict) ((pkg_conflicts++)) ;;
            symlink) ((pkg_symlinks++)) ;;
            done) ((pkg_already_done++)) ;;
        esac
    done
    
    CONFLICTS_FOUND=$((CONFLICTS_FOUND + pkg_conflicts))
    SYMLINKS_TO_CREATE=$((SYMLINKS_TO_CREATE + pkg_symlinks))
}

# Sync local changes back into repo for a package
# Usage: sync_local_changes <package> <target>
sync_local_changes() {
    local package="$1"
    local target="$2"
    local package_dir="$STOW_DIR/$package"
    
    # Ensure diff3 is available if merge mode is enabled (check once)
    ensure_diff3_available || return 1
    
    if [ ! -d "$package_dir" ]; then
        return 0  # Package doesn't exist
    fi
    
    # Find all files in the package directory
    while IFS= read -r -d '' repo_file; do
        local rel_path="${repo_file#$package_dir/}"
        
        # Skip .DS_Store files
        if should_skip_file "$rel_path"; then
            continue
        fi
        
        # Build target path (where file should be in home directory)
        local target_file
        target_file=$(build_target_path "$repo_file" "$package_dir" "$target")
        
        # Validate target path is safe
        if ! is_safe_target_path "$target_file"; then
            continue
        fi
        
        # Skip if target doesn't exist locally
        if [ ! -e "$target_file" ]; then
            continue
        fi
        
        # Skip if already correctly symlinked
        if is_already_symlinked "$repo_file" "$target_file"; then
            continue
        fi
        
        # Skip if accessible via parent directory symlink
        if is_parent_dir_symlinked "$target_file" "$package"; then
            continue
        fi
        
        # Skip if target is a symlink pointing elsewhere (not a conflict we can sync)
        if [ -L "$target_file" ]; then
            continue
        fi
        
        # Skip binary files
        if is_binary_file "$target_file"; then
            if [ "$VERBOSE" = true ]; then
                log_warn "Skipping binary file: ${target_file#$HOME/}"
            fi
            continue
        fi
        
        # Check if files differ
        if ! compare_files "$target_file" "$repo_file"; then
            # Files differ, need to sync
            if [ "$DRY_RUN" = true ]; then
                echo -e "    ${YELLOW}Would sync: ${target_file#$HOME/}${NC}"
                if [ "$VERBOSE" = true ]; then
                    echo "    Diff:"
                    show_file_diff "$repo_file" "$target_file" "repo/${target_file#$HOME/}" "local/${target_file#$HOME/}" | sed 's/^/      /'
                fi
                ((SYNCED_FILES++))
            else
                # Create backup of repo file
                local backup_path
                backup_path=$(create_file_backup "$repo_file")
                
                if [ "$SYNC_MERGE" = true ]; then
                    # Merge mode
                    local temp_file
                    temp_file=$(create_temp_file "merge.XXXXXX")
                    if merge_files "$target_file" "$repo_file" "$temp_file"; then
                        # Merge successful
                        cp "$temp_file" "$repo_file"
                        echo -e "    ${GREEN}✓ Merged: ${target_file#$HOME/}${NC}"
                        log_info "Merged: ${target_file#$HOME/}"
                        if [ "$VERBOSE" = true ]; then
                            echo "    Diff:"
                            show_file_diff "$backup_path" "$repo_file" "backup/${target_file#$HOME/}" "merged/${target_file#$HOME/}" | sed 's/^/      /'
                        fi
                    else
                        # Merge had conflicts
                        log_warn "Merge conflicts in: ${target_file#$HOME/}"
                        log_info "Backup saved to: $backup_path"
                        if [ "$VERBOSE" = true ]; then
                            echo "    Diff:"
                            show_file_diff "$repo_file" "$target_file" "repo/${target_file#$HOME/}" "local/${target_file#$HOME/}" | sed 's/^/      /'
                        fi
                        # Copy merged file with conflicts to repo (user can resolve)
                        cp "$temp_file" "$repo_file"
                    fi
                    # Note: temp_file cleanup handled by cleanup_temp_dir
                else
                    # Overwrite mode
                    copy_to_repo "$target_file" "$repo_file"
                    echo -e "    ${GREEN}✓ Synced: ${target_file#$HOME/}${NC}"
                    log_info "Synced: ${target_file#$HOME/}"
                    if [ "$VERBOSE" = true ]; then
                        echo "    Backup saved to: $backup_path"
                        log_info "Backup saved to: $backup_path"
                        echo "    Diff:"
                        show_file_diff "$backup_path" "$repo_file" "backup/${target_file#$HOME/}" "synced/${target_file#$HOME/}" | sed 's/^/      /'
                    fi
                fi
                ((SYNCED_FILES++))
            fi
        fi
    done < <(find -P "$package_dir" -type f -print0 2>/dev/null)
    
    # Handle directory sync: if files exist locally in directories that match package structure
    # but don't exist in the repo, copy them to the stow directory
    # Find directories in package
    while IFS= read -r -d '' repo_dir; do
        local dir_rel_path="${repo_dir#$package_dir/}"
        local transformed_path
        transformed_path=$(transform_dotfiles_path "$dir_rel_path")
        local target_dir="$HOME/$transformed_path"
        
        # Check if target directory exists locally and is not a symlink
        if [ -d "$target_dir" ] && [ ! -L "$target_dir" ]; then
            # Check if any files in target_dir don't exist in repo_dir
            while IFS= read -r -d '' local_file; do
                local file_rel_path="${local_file#$target_dir/}"
                # Transform to dot-* format for repo
                local repo_file_transformed
                repo_file_transformed=$(echo "$file_rel_path" | sed 's|\.|dot-|g')
                local repo_file_path="$repo_dir/$repo_file_transformed"
                
                # Skip if file already exists in repo
                if [ -f "$repo_file_path" ]; then
                    continue
                fi
                
                # Skip binary files
                if is_binary_file "$local_file"; then
                    if [ "$VERBOSE" = true ]; then
                        log_warn "Skipping binary file: ${local_file#$HOME/}"
                    fi
                    continue
                fi
                
                if [ "$DRY_RUN" = true ]; then
                    echo -e "    ${YELLOW}Would add: ${local_file#$HOME/} -> ${repo_file_path#$STOW_DIR/}${NC}"
                else
                    # Copy file to repo (with dot-* transformation)
                    copy_to_repo "$local_file" "$repo_file_path"
                    echo -e "    ${GREEN}✓ Added: ${local_file#$HOME/} -> ${repo_file_path#$STOW_DIR/}${NC}"
                    log_info "Added: ${local_file#$HOME/} -> ${repo_file_path#$STOW_DIR/}"
                fi
                ((SYNCED_FILES++))
            done < <(find "$target_dir" -type f -print0 2>/dev/null)
        fi
    done < <(find -P "$package_dir" -type d -print0 2>/dev/null)
}

# Execute stow operation for a package
# Usage: execute_stow <package>
execute_stow() {
    local package="$1"
    cd "$STOW_DIR" || return 1
    stow --dotfiles -t "$HOME" "$package" 2>/dev/null || true
}

# Function to stow a package with dotfiles support
# Uses stow's --dotfiles option which converts dot-* prefixes to .* prefixes
# This allows us to keep files visible in the stow directory (with dot- prefix)
# while creating proper hidden dotfiles (with . prefix) in the home directory
# Outputs any messages from remove_conflicting_files to stdout
stow_package() {
    local package=$1
    local description="${2:-$package}"
    
    if [ ! -d "$STOW_DIR/$package" ]; then
        return 0  # Package doesn't exist
    fi
    
    # Sync local changes before dry-run or actual stow
    if [ "$SYNC_LOCAL" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            if [ "$VERBOSE" = true ]; then
                echo "  - $description (sync preview)"
            fi
            sync_local_changes "$package" "$HOME"
        else
            echo "  - $description (syncing local changes)"
            log_info "$description (syncing local changes)"
            sync_local_changes "$package" "$HOME"
        fi
    fi
    
    if [ "$DRY_RUN" = true ]; then
        check_package_dry_run "$package" "$description"
        return 0
    fi
    
    # Validate package path before operations
    if ! validate_repo_path "$STOW_DIR/$package"; then
        log_error "Invalid package path: $STOW_DIR/$package"
        return 1
    fi
    
    # Initialize rollback tracking for this package
    if [ "$ROLLBACK_INITIALIZED" != true ]; then
        init_rollback
    fi
    
    # Remove conflicting files first (output goes to stdout)
    remove_conflicting_files "$STOW_DIR/$package" "$HOME"
    
    # Execute stow operation
    execute_stow "$package"
    
    # Record rollback operation
    record_operation "unstow" "Unstow package $package" "cd '$STOW_DIR' && stow -D --dotfiles -t '$HOME' '$package'"
}

# Main execution
if [ "$SYNC_LOCAL" = true ]; then
    # Warn if repo has uncommitted changes
    if [ "$DRY_RUN" != true ] && command -v git &> /dev/null; then
        cd "$DOTFILES_DIR" || true
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            warn "Repository has uncommitted changes"
            echo "  Consider committing or stashing changes before syncing"
            echo ""
        fi
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Previewing local changes to sync..."
    else
        log_info "Syncing local changes into repository..."
    fi
    SYNCED_FILES=0
    SYNCED_DIRECTORIES=0
fi

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Checking symlinks..."
    CONFLICTS_FOUND=0
    SYMLINKS_TO_CREATE=0
else
    if [ "$SYNC_LOCAL" != true ]; then
        log_info "Creating symlinks..."
        # Initialize rollback tracking
        init_rollback
        # Start progress tracking
        progress_start "Creating symlinks for dotfiles packages..."
    fi
fi

# Count total packages for progress tracking
local total_packages=0
local current_package=0
if [ "$DRY_RUN" != true ] && [ "$SYNC_LOCAL" != true ]; then
    for pkg_dir in "$STOW_DIR"/*; do
        [ -d "$pkg_dir" ] && [ "$(basename "$pkg_dir")" != "vscode" ] && ((total_packages++))
    done
    [ -d "$STOW_DIR/vscode" ] && ((total_packages++))
fi

# Shell configs
if [ "$DRY_RUN" = true ]; then
    stow_package zsh "Shell configs (zsh, bash)"
    stow_package bash ""
else
    output_zsh=$(stow_package zsh 2>&1)
    output_bash=$(stow_package bash 2>&1)
    if [ -n "${output_zsh// }" ] || [ -n "${output_bash// }" ]; then
        echo "  - Shell configs (zsh, bash)"
        log_info "Shell configs (zsh, bash)"
        [ -n "${output_zsh// }" ] && echo "$output_zsh" && log_info "$output_zsh"
        [ -n "${output_bash// }" ] && echo "$output_bash" && log_info "$output_bash"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Git configs
if [ "$DRY_RUN" = true ]; then
    stow_package git "Git configs"
else
    output=$(stow_package git 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Git configs"
        log_info "Git configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# SSH config
if [ "$DRY_RUN" = true ]; then
    stow_package ssh "SSH config"
else
    output=$(stow_package ssh 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - SSH config"
        log_info "SSH config"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Terminal configs (Ghostty)
# Always stow to standard location (~/.config/ghostty/config)
# On macOS, also create symlink to Application Support location
if [ "$DRY_RUN" = true ]; then
    stow_package ghostty "Terminal configs (ghostty)"
    # On macOS, also check for Application Support location
    if [[ "$OS" == "macos" ]]; then
        GHOSTTY_CONFIG_SOURCE="$STOW_DIR/ghostty/dot-config/ghostty/config"
        GHOSTTY_MACOS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
        GHOSTTY_CONFIG_TARGET="$GHOSTTY_MACOS_DIR/config"
        if [ -f "$GHOSTTY_CONFIG_SOURCE" ]; then
            status=$(check_file_dry_run "$GHOSTTY_CONFIG_SOURCE" "ghostty" "$GHOSTTY_CONFIG_TARGET")
            case "$status" in
                conflict) ((CONFLICTS_FOUND++)) ;;
                symlink) ((SYMLINKS_TO_CREATE++)) ;;
            esac
        fi
    fi
else
    output=$(stow_package ghostty 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Terminal configs (ghostty)"
        log_info "Terminal configs (ghostty)"
        echo "$output"
        log_info "$output"
    fi
    # On macOS, also create symlink to Application Support location
    if [[ "$OS" == "macos" ]]; then
        GHOSTTY_CONFIG_SOURCE="$STOW_DIR/ghostty/dot-config/ghostty/config"
        GHOSTTY_MACOS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
        GHOSTTY_CONFIG_TARGET="$GHOSTTY_MACOS_DIR/config"
        if [ -f "$GHOSTTY_CONFIG_SOURCE" ]; then
            mkdir -p "$GHOSTTY_MACOS_DIR"
            if [ -e "$GHOSTTY_CONFIG_TARGET" ] && [ ! -L "$GHOSTTY_CONFIG_TARGET" ]; then
                remove_conflicting_file "$GHOSTTY_CONFIG_TARGET"
            fi
            if [ ! -L "$GHOSTTY_CONFIG_TARGET" ] || ! is_symlink_correct "$GHOSTTY_CONFIG_TARGET" "$GHOSTTY_CONFIG_SOURCE"; then
                ln -sf "$GHOSTTY_CONFIG_SOURCE" "$GHOSTTY_CONFIG_TARGET"
                echo "    Created symlink: ${GHOSTTY_CONFIG_TARGET#$HOME/} -> ${GHOSTTY_CONFIG_SOURCE#$STOW_DIR/}"
                log_info "Created symlink: ${GHOSTTY_CONFIG_TARGET#$HOME/} -> ${GHOSTTY_CONFIG_SOURCE#$STOW_DIR/}"
            fi
        fi
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# GitHub CLI configs
if [ "$DRY_RUN" = true ]; then
    stow_package gh "GitHub CLI configs"
else
    output=$(stow_package gh 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - GitHub CLI configs"
        log_info "GitHub CLI configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# oh-my-zsh customizations
if [ "$DRY_RUN" = true ]; then
    stow_package oh-my-zsh "oh-my-zsh customizations"
else
    output=$(stow_package oh-my-zsh 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - oh-my-zsh customizations"
        log_info "oh-my-zsh customizations"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Local bin configs
if [ "$DRY_RUN" = true ]; then
    stow_package local "Local bin configs"
else
    output=$(stow_package local 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Local bin configs"
        log_info "Local bin configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Claude IDE configs
if [ "$DRY_RUN" = true ]; then
    stow_package claude "Claude IDE configs"
else
    output=$(stow_package claude 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Claude IDE configs"
        log_info "Claude IDE configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Codex configs
if [ "$DRY_RUN" = true ]; then
    stow_package codex "Codex configs"
else
    output=$(stow_package codex 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Codex configs"
        log_info "Codex configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Cursor configs
if [ "$DRY_RUN" = true ]; then
    stow_package cursor "Cursor configs"
else
    output=$(stow_package cursor 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Cursor configs"
        log_info "Cursor configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# OpenCode configs
if [ "$DRY_RUN" = true ]; then
    stow_package opencode "OpenCode configs"
else
    output=$(stow_package opencode 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - OpenCode configs"
        log_info "OpenCode configs"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# Telemetry settings
if [ "$DRY_RUN" = true ]; then
    stow_package telemetry "Telemetry settings"
else
    output=$(stow_package telemetry 2>&1)
    if [ -n "${output// }" ]; then
        echo "  - Telemetry settings"
        log_info "Telemetry settings"
        echo "$output"
        log_info "$output"
    fi
    if [ "$SYNC_LOCAL" != true ] && [ "$total_packages" -gt 0 ]; then
        ((current_package++))
        progress_update_item "$current_package" "$total_packages" "Stowing package %d of %d..."
    fi
fi

# VS Code settings (macOS specific)
# EXCEPTION: Uses regular stow (not --dotfiles) because:
# 1. VS Code settings are in a non-standard location (~/Library/Application Support/Code/User)
# 2. Files don't need dot prefix restoration (they're not dotfiles)
# 3. We stow from inside the vscode directory to target the correct path structure
if [[ "$OS" == "macos" ]]; then
    if [ "$DRY_RUN" = true ]; then
        if [ "$VERBOSE" = true ]; then
            echo "  - VS Code settings"
        fi
        VS_CODE_DIR="$HOME/Library/Application Support/Code/User"
        if [ -d "$STOW_DIR/vscode" ]; then
            while IFS= read -r -d '' file; do
                rel_path="${file#$STOW_DIR/vscode/}"
                target_file="$VS_CODE_DIR/$rel_path"
                if [ ! -e "$target_file" ]; then
                    ((SYMLINKS_TO_CREATE++))
                    if [ "$VERBOSE" = true ]; then
                        echo "    → Would create: ${target_file#$HOME/} -> ${file#$STOW_DIR/}"
                    fi
                elif [ -L "$target_file" ]; then
                    # Check if correct
                    local actual_source=$(readlink "$target_file")
                    if [[ "$actual_source" != /* ]]; then
                        actual_source="$(cd "$(dirname "$target_file")" && pwd)/$actual_source"
                    fi
                    if [ "$actual_source" != "$file" ]; then
                        ((CONFLICTS_FOUND++))
                        if [ "$VERBOSE" = true ]; then
                            echo -e "    ${YELLOW}⚠ Conflict: ${target_file#$HOME/} exists as symlink pointing elsewhere${NC}"
                        fi
                    fi
                else
                    ((CONFLICTS_FOUND++))
                    verbose_conflict "${target_file#$HOME/}" "exists (not a symlink) - would be removed"
                fi
            done
            
            # Use optimized find for VS Code files
            local vscode_files_array
            find_files_array vscode_files_array "$STOW_DIR/vscode" "-type f"
            for file in "${vscode_files_array[@]}"; do
                local rel_path="${file#$STOW_DIR/vscode/}"
                local target_file="$VS_CODE_DIR/$rel_path"
                check_symlink "$target_file" "$file" "VS Code: $rel_path"
            done
        fi
    else
        echo "  - VS Code settings"
        log_info "VS Code settings"
        VS_CODE_DIR="$HOME/Library/Application Support/Code/User"
        if [ ! -d "$VS_CODE_DIR" ]; then
            mkdir -p "$VS_CODE_DIR"
        fi
        # Remove conflicting files
        if [ -d "$STOW_DIR/vscode" ]; then
            # Use optimized find for VS Code files
            local vscode_files_array
            find_files_array vscode_files_array "$STOW_DIR/vscode" "-type f"
            for file in "${vscode_files_array[@]}"; do
                rel_path="${file#$STOW_DIR/vscode/}"
                target_file="$VS_CODE_DIR/$rel_path"
                if [ -e "$target_file" ] && [ ! -L "$target_file" ]; then
                    echo "    Removing existing: ${target_file#$HOME/}"
                    log_info "Removing existing: ${target_file#$HOME/}"
                    rm -rf "$target_file"
                fi
            done
            # Stow from vscode directory, targeting Library/Application Support/Code/User
            cd "$STOW_DIR/vscode" || return 1
            stow -t "$VS_CODE_DIR" . 2>/dev/null || true
            cd "$STOW_DIR" || return 1
        else
            echo "    (VS Code config directory not found, skipping)"
            log_info "VS Code config directory not found, skipping"
        fi
    fi
fi

# Summary
if [ "$SYNC_LOCAL" = true ]; then
    echo ""
    if [ "$DRY_RUN" = true ]; then
        if [ $SYNCED_FILES -gt 0 ]; then
            log_info "[DRY RUN] Would sync $SYNCED_FILES file(s)"
        else
            log_info "[DRY RUN] No files to sync"
        fi
    else
        if [ $SYNCED_FILES -gt 0 ]; then
            log_info "Synced $SYNCED_FILES file(s) into repository"
            warn "Note: Review changes and commit them with git"
        else
            log_info "No files needed syncing"
        fi
    fi
    echo ""
fi

# Summary for dry-run (symlinks)
if [ "$DRY_RUN" = true ]; then
    if [ "$SYNC_LOCAL" != true ]; then
        echo ""
    fi
    if [ $CONFLICTS_FOUND -gt 0 ]; then
        log_info "[DRY RUN] Would create $SYMLINKS_TO_CREATE symlinks, remove $CONFLICTS_FOUND conflicting files"
    else
        log_info "[DRY RUN] Would create $SYMLINKS_TO_CREATE symlinks"
    fi
elif [ "$SYNC_LOCAL" != true ]; then
    # Complete progress and finalize rollback
    progress_complete "Symlink creation complete"
    if [ "$ROLLBACK_INITIALIZED" = true ]; then
        finalize_rollback
        log_info "Rollback script saved to: $ROLLBACK_SCRIPT"
    fi
fi

