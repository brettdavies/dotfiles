#!/usr/bin/env bash
# Check if dotfiles are fully implemented on this system
#
# This script verifies that all dotfiles configurations are properly set up:
# - Dependencies (stow, shells, oh-my-zsh)
# - Stow package symlinks
# - Special files (.secrets)
# - Homebrew packages (macOS only)
# - VS Code extensions (macOS only)
# - Cursor extensions
#
# This script only checks - it does not install anything.
#
# Usage:
#   ./check-implementation.sh
#   ./check-implementation.sh --help
#
# Exit codes:
#   0 - All checks passed (or only warnings)
#   1 - Some checks failed

set -u  # Exit on undefined variable

# Don't use set -e, we want to continue checking even if some checks fail

# Source shared libraries early for colors and common functions
# Get dotfiles directory first (before sourcing libraries)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
    DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    DOTFILES_DIR="$SCRIPT_DIR"
fi
SCRIPTS_DIR="$DOTFILES_DIR/scripts"

# Source shared libraries
if [ ! -f "$SCRIPTS_DIR/lib/loaders/full.sh" ]; then
    err "Cannot find loaders/full.sh at $SCRIPTS_DIR/lib/loaders/full.sh. Check that SCRIPTS_DIR is set correctly." 1
    exit 1
fi
source "$SCRIPTS_DIR/lib/loaders/full.sh"

# Initialize package status cache for performance
init_package_cache

# Additional color for this script
BLUE='\033[0;34m'

# Show usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Check if dotfiles are fully implemented on this system.

OPTIONS:
    -h, --help      Show this help message and exit
    -q, --quiet     Suppress output except for summary
    -v, --verbose   Show detailed output for each check
    -o, --output FILE   Save results to FILE (also displays on stdout)

EXAMPLES:
    $(basename "$0")                          # Run full check with normal output
    $(basename "$0") --quiet                  # Run check with minimal output
    $(basename "$0") --verbose                # Run check with detailed output
    $(basename "$0") -o report.txt            # Save results to report.txt
    $(basename "$0") --quiet -o report.txt    # Save minimal output to report.txt

EOF
}

# Parse command line arguments
QUIET=false
VERBOSE=false
OUTPUT_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -o|--output)
            if [[ -z "${2:-}" ]]; then
                err "--output requires a filename. Usage: --output <filename>" 1
                show_usage
                exit 1
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            err "Unknown option: $1. Use --help for usage information." 1
            show_usage
            exit 1
            ;;
    esac
done

# Set up output redirection if output file is specified
if [[ -n "$OUTPUT_FILE" ]]; then
    # Create output directory if it doesn't exist
    OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
    if [[ -n "$OUTPUT_DIR" ]] && [[ "$OUTPUT_DIR" != "." ]]; then
        mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
    fi
    
    # Use tee to write to both stdout and file
    # Remove color codes for file output
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$OUTPUT_FILE"))
    echo "Results will be saved to: $OUTPUT_FILE" >&2
fi

# Set up STOW_DIR (DOTFILES_DIR already set from lib-core.sh sourcing above)
STOW_DIR="$DOTFILES_DIR/stow"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Results arrays
PASSED=()
FAILED=()
WARNINGS_LIST=()

# Helper functions
check_pass() {
    ((TOTAL_CHECKS++))
    ((PASSED_CHECKS++))
    PASSED+=("$1")
    if [ "$VERBOSE" = true ] && [ "$QUIET" = false ]; then
        echo -e "  ${GREEN}✓${NC} $1"
    fi
}

check_fail() {
    ((TOTAL_CHECKS++))
    ((FAILED_CHECKS++))
    FAILED+=("$1")
    if [ "$QUIET" = false ]; then
        echo -e "  ${RED}✗${NC} $1"
    fi
}

check_warn() {
    ((TOTAL_CHECKS++))
    ((WARNINGS++))
    WARNINGS_LIST+=("$1")
    if [ "$QUIET" = false ]; then
        echo -e "  ${YELLOW}⚠${NC} $1"
    fi
}

# Check if a file is a macOS Finder alias
is_macos_alias() {
    local file="$1"
    if [[ "$OS" == "macos" ]]; then
        # Check if file has alias file type attribute
        if [ -f "$file" ]; then
            # Use osascript to check if it's an alias
            osascript -e "tell application \"Finder\" to get class of alias file (POSIX file \"$file\")" 2>/dev/null && return 0
            # Alternative: check for alias resource fork
            [ -s "$file/..namedfork/rsrc" ] 2>/dev/null && return 0
        fi
    fi
    return 1
}

# Check if a symlink exists and points to the correct location
check_symlink() {
    local target="$1"
    local expected_source="$2"
    local description="$3"
    
    if [ -L "$target" ]; then
        local actual_source
        actual_source=$(readlink "$target")
        
        # Resolve relative symlinks
        if [[ "$actual_source" != /* ]]; then
            local base_dir
            base_dir="$(cd "$(dirname "$target")" && pwd)" || {
                check_fail "$description (cannot resolve symlink path)"
                return 1
            }
            actual_source="$base_dir/$actual_source"
        fi
        
        # Normalize paths using shared function
        local normalized_actual normalized_expected
        normalized_actual=$(normalize_path "$actual_source") || {
            check_fail "$description (cannot normalize actual path)"
            return 1
        }
        normalized_expected=$(normalize_path "$expected_source") || {
            check_fail "$description (cannot normalize expected path)"
            return 1
        }
        
        if [ "$normalized_actual" == "$normalized_expected" ]; then
            check_pass "$description"
            return 0
        else
            check_fail "$description (points to wrong location: $normalized_actual)"
            return 1
        fi
    elif [ -e "$target" ]; then
        # Check if it's a macOS alias (which is acceptable as an alternative to symlinks)
        if is_macos_alias "$target"; then
            check_warn "$description (exists as macOS alias, should be symlink for better compatibility)"
            return 0
        else
            check_fail "$description (exists but is not a symlink)"
            return 1
        fi
    else
        check_fail "$description (does not exist)"
        return 1
    fi
}

# Check if a file exists (not necessarily a symlink)
check_file_exists() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        check_pass "$description"
        return 0
    else
        check_fail "$description (does not exist)"
        return 1
    fi
}

# Check if a directory exists
check_dir_exists() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        check_pass "$description"
        return 0
    else
        check_fail "$description (does not exist)"
        return 1
    fi
}

# Check if a command exists
check_command() {
    local cmd="$1"
    local description="$2"
    
    if command -v "$cmd" &> /dev/null; then
        check_pass "$description"
        return 0
    else
        check_fail "$description (not found)"
        return 1
    fi
}

# Check stow package symlinks
check_stow_package() {
    local package="$1"
    local description="$2"
    
    if [ ! -d "$STOW_DIR/$package" ]; then
        check_warn "$description (package directory not found in repo)"
        return 0
    fi
    
    # Find all files in the package
    local found_any=false
    local checked_dirs=()
    
    while IFS= read -r -d '' file; do
        found_any=true
        local rel_path="${file#$STOW_DIR/$package/}"
        # Apply dotfiles transformation using shared function
        local transformed_path
        transformed_path=$(transform_dotfiles_path "$rel_path")
        local target_file="$HOME/$transformed_path"
        
        # Skip .DS_Store files
        if [[ "$(basename "$target_file")" == ".DS_Store" ]]; then
            continue
        fi
        
        # Check if any parent directory is a symlink pointing to the stow directory
        if is_parent_dir_symlinked "$target_file" "$package"; then
            # Parent directory is symlinked, so this file is accessible through that symlink
            # Just verify the file exists in the stow directory
            if [ -f "$file" ]; then
                check_pass "$description: $transformed_path (accessible via directory symlink)"
            else
                check_fail "$description: $transformed_path (file missing in stow directory)"
            fi
        else
            # No parent directory symlink, so this file should be a symlink itself
            check_symlink "$target_file" "$file" "$description: $transformed_path"
        fi
    done
    
    # Use optimized find function
    local files_array
    find_files_array files_array "$STOW_DIR/$package" "-type f"
    for file in "${files_array[@]}"; do
        found_any=true
        local rel_path="${file#$STOW_DIR/$package/}"
        # Apply dotfiles transformation using shared function
        local transformed_path
        transformed_path=$(transform_dotfiles_path "$rel_path")
        local target_file="$HOME/$transformed_path"
        
        # Skip .DS_Store files
        if [[ "$(basename "$target_file")" == ".DS_Store" ]]; then
            continue
        fi
        
        # Check if any parent directory is a symlink pointing to the stow directory
        if is_parent_dir_symlinked "$target_file" "$package"; then
            # Parent directory is symlinked, so this file is accessible through that symlink
            # Just verify the file exists in the stow directory
            if [ -f "$file" ]; then
                check_pass "$description: $transformed_path (accessible via directory symlink)"
            else
                check_fail "$description: $transformed_path (file missing in stow directory)"
            fi
        else
            # No parent directory symlink, so this file should be a symlink itself
            check_symlink "$target_file" "$file" "$description: $transformed_path"
        fi
    done
    
    if [ "$found_any" = false ]; then
        check_warn "$description (no files found in package)"
    fi
}

# Print header (unless quiet)
if [ "$QUIET" = false ]; then
    echo "=========================================="
    echo "Dotfiles Implementation Check Report"
    echo "=========================================="
    echo "OS: $OS"
    echo "Home Directory: $HOME"
    echo "Dotfiles Directory: $DOTFILES_DIR"
    echo "Generated: $(date)"
    echo ""
    echo "Checking dependencies..."
    echo ""
fi

# Check dependencies
check_command "stow" "GNU Stow installed"
check_command "zsh" "zsh shell installed"
check_command "bash" "bash shell installed"
check_dir_exists "$HOME/.oh-my-zsh" "oh-my-zsh installed"

if [ "$QUIET" = false ]; then
    echo ""
    echo "Checking stow packages..."
    echo ""
fi

# Check all stow packages
check_stow_package "zsh" "Zsh configs"
check_stow_package "bash" "Bash configs"
check_stow_package "git" "Git configs"
check_stow_package "ssh" "SSH config"
check_stow_package "ghostty" "Ghostty terminal config"
# Check Ghostty macOS Application Support location (macOS only)
if [[ "$OS" == "macos" ]]; then
    GHOSTTY_MACOS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
    GHOSTTY_CONFIG_SOURCE="$STOW_DIR/ghostty/dot-config/ghostty/config"
    GHOSTTY_CONFIG_TARGET="$GHOSTTY_MACOS_DIR/config"
    if [ -f "$GHOSTTY_CONFIG_SOURCE" ]; then
        check_symlink "$GHOSTTY_CONFIG_TARGET" "$GHOSTTY_CONFIG_SOURCE" "Ghostty: macOS Application Support config"
    fi
fi
check_stow_package "gh" "GitHub CLI config"
check_stow_package "local" "Local bin configs"
check_stow_package "claude" "Claude IDE config"
check_stow_package "codex" "Codex config"
check_stow_package "cursor" "Cursor config"
check_stow_package "opencode" "OpenCode config"
check_stow_package "telemetry" "Telemetry settings"

# Check special files
if [ "$QUIET" = false ]; then
    echo ""
    echo "Checking special files..."
    echo ""
fi

check_file_exists "$HOME/.secrets" ".secrets file exists"
if [ -f "$HOME/.secrets" ]; then
    perms=$(get_file_permissions "$HOME/.secrets")
    if [ "$perms" == "$PERM_SECRET_FILE" ]; then
        check_pass ".secrets file has correct permissions ($PERM_SECRET_FILE)"
    else
        check_fail ".secrets file has incorrect permissions ($perms, expected $PERM_SECRET_FILE)"
    fi
fi

# Check VS Code config (macOS only)
if [[ "$OS" == "macos" ]]; then
    if [ "$QUIET" = false ]; then
        echo ""
        echo "Checking VS Code configuration..."
        echo ""
    fi
    
    VS_CODE_DIR="$HOME/Library/Application Support/Code/User"
    if [ -d "$VS_CODE_DIR" ]; then
        if [ -d "$STOW_DIR/vscode" ]; then
            while IFS= read -r -d '' file; do
                rel_path="${file#$STOW_DIR/vscode/}"
                target_file="$VS_CODE_DIR/$rel_path"
                check_symlink "$target_file" "$file" "VS Code: $rel_path"
            done
            
            # Use optimized find for VS Code files
            local vscode_files_array
            find_files_array vscode_files_array "$STOW_DIR/vscode" "-type f"
            for file in "${vscode_files_array[@]}"; do
                rel_path="${file#$STOW_DIR/vscode/}"
                target_file="$VS_CODE_DIR/$rel_path"
                check_symlink "$target_file" "$file" "VS Code: $rel_path"
            done
        else
            check_warn "VS Code config package not found in repo"
        fi
    else
        check_warn "VS Code config directory does not exist (VS Code may not be installed)"
    fi
fi

# Check Homebrew packages (macOS only)
if [[ "$OS" == "macos" ]]; then
    if [ "$QUIET" = false ]; then
        echo ""
        echo "Checking Homebrew packages..."
        echo ""
    fi
    
    if command -v brew &> /dev/null; then
        # Read Brewfile and check each package
        if [ -f "$STOW_DIR/brew/Brewfile" ]; then
            local brewfile_lines
            readarray -t brewfile_lines < "$STOW_DIR/brew/Brewfile" 2>/dev/null || true
            for line in "${brewfile_lines[@]}"; do
                # Skip comments and empty lines
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${line// }" ]] && continue
                
                # Parse different types of entries
                if [[ "$line" =~ ^brew[[:space:]]+\"(.*)\" ]]; then
                    pkg="${BASH_REMATCH[1]}"
                    [[ -z "$pkg" ]] && continue
                    
                    # Handle tap/package format
                    if [[ "$pkg" =~ / ]]; then
                        tap="${pkg%%/*}"
                        if is_tap_installed "$tap/"; then
                            check_pass "Homebrew tap: $tap"
                        else
                            check_fail "Homebrew tap: $tap (not installed)"
                        fi
                    fi
                    
                    # Check if package is installed
                    if is_brew_package_installed "$pkg"; then
                        check_pass "Homebrew package: $pkg"
                    else
                        check_fail "Homebrew package: $pkg (not installed)"
                    fi
                elif [[ "$line" =~ ^cask[[:space:]]+\"(.*)\" ]]; then
                    cask="${BASH_REMATCH[1]}"
                    [[ -z "$cask" ]] && continue
                    if is_brew_cask_installed "$cask"; then
                        check_pass "Homebrew cask: $cask"
                    else
                        check_fail "Homebrew cask: $cask (not installed)"
                    fi
                elif [[ "$line" =~ ^vscode[[:space:]]+\"(.*)\" ]]; then
                    ext="${BASH_REMATCH[1]}"
                    [[ -z "$ext" ]] && continue
                    if is_vscode_extension_installed "$ext"; then
                        check_pass "VS Code extension: $ext"
                    else
                        if command -v code &> /dev/null; then
                            check_fail "VS Code extension: $ext (not installed)"
                        else
                            check_warn "VS Code extension: $ext (code command not found)"
                        fi
                    fi
                elif [[ "$line" =~ ^tap[[:space:]]+\"(.*)\" ]]; then
                    tap="${BASH_REMATCH[1]}"
                    [[ -z "$tap" ]] && continue
                    if is_tap_installed "$tap"; then
                        check_pass "Homebrew tap: $tap"
                    else
                        check_fail "Homebrew tap: $tap (not installed)"
                    fi
                fi
            done
        fi
    else
        check_warn "Homebrew not installed"
    fi
fi

# Check Cursor extensions
if [ "$QUIET" = false ]; then
    echo ""
    echo "Checking Cursor extensions..."
    echo ""
fi

if [ -f "$STOW_DIR/cursor/extensions.txt" ]; then
    cursor_cmd=$(get_cursor_command)
    
    if [ -n "$cursor_cmd" ]; then
        local extensions_array
        readarray -t extensions_array < "$STOW_DIR/cursor/extensions.txt" 2>/dev/null || true
        for extension in "${extensions_array[@]}"; do
            # Skip empty lines and comments
            [[ "$extension" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${extension// }" ]] && continue
            
            extension=$(echo "$extension" | xargs)
            [[ -z "$extension" ]] && continue
            
            if is_cursor_extension_installed "$extension" "$cursor_cmd"; then
                check_pass "Cursor extension: $extension"
            else
                check_fail "Cursor extension: $extension (not installed)"
            fi
        done
    else
        check_warn "Cursor not found (extensions cannot be checked)"
    fi
else
    check_warn "Cursor extensions.txt not found in repo"
fi

# Generate report
if [ "$QUIET" = false ]; then
    echo ""
    echo "=========================================="
    echo "SUMMARY"
    echo "=========================================="
fi
echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
echo -e "${RED}Failed: $FAILED_CHECKS${NC}"
echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
echo "Total Checks: $TOTAL_CHECKS"
if [ "$QUIET" = false ]; then
    echo ""
fi

if [ $FAILED_CHECKS -gt 0 ]; then
    if [ "$QUIET" = false ]; then
        echo -e "${RED}FAILED CHECKS:${NC}"
        for item in "${FAILED[@]}"; do
            echo -e "  ${RED}✗${NC} $item"
        done
        echo ""
    fi
fi

if [ $WARNINGS -gt 0 ]; then
    if [ "$QUIET" = false ]; then
        echo -e "${YELLOW}WARNINGS:${NC}"
        for item in "${WARNINGS_LIST[@]}"; do
            echo -e "  ${YELLOW}⚠${NC} $item"
        done
        echo ""
    fi
fi

if [ $FAILED_CHECKS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    exit 0
elif [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "${YELLOW}✓ All critical checks passed (some warnings)${NC}"
    exit 0
else
    echo -e "${RED}✗ Some checks failed${NC}"
    exit 1
fi

