#!/usr/bin/env bash
# BATS test runner script
# Runs all BATS tests in the test directory
# Automatically writes results to scripts/test/results/ with standardized naming

set -euo pipefail

# Get the directory where this script is located
# Support both bash (BASH_SOURCE) and zsh (%x)
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # Bash
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${ZSH_VERSION:-}" ]; then
    # Zsh - use %x expansion
    SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    # Fallback
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
TEST_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/scripts/test/results"

# Source timestamp helpers (if available)
if [ -f "$REPO_ROOT/scripts/lib/util/timestamp.sh" ]; then
    source "$REPO_ROOT/scripts/lib/util/timestamp.sh" 2>/dev/null || true
fi

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# Check if BATS is installed
if ! command -v bats &> /dev/null; then
    echo "Error: BATS is not installed." >&2
    echo "Install with: brew install bats-core (macOS) or see https://github.com/bats-core/bats-core" >&2
    exit 1
fi

# Check if bats-support and bats-assert are installed
if [ ! -d "/usr/local/lib/bats-support" ] && [ ! -d "$HOME/.local/lib/bats-support" ]; then
    echo "Warning: bats-support and bats-assert may not be installed." >&2
    echo "Install with: git clone https://github.com/bats-core/bats-support.git /usr/local/lib/bats-support" >&2
    echo "             git clone https://github.com/bats-core/bats-assert.git /usr/local/lib/bats-assert" >&2
    echo "             git clone https://github.com/bats-core/bats-file.git /usr/local/lib/bats-file" >&2
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Detect shell and version for filename
detect_shell_info() {
    local shell_name
    local shell_version
    
    if [ -n "${ZSH_VERSION:-}" ]; then
        shell_name="zsh"
        # Extract version from ZSH_VERSION (format: "5.9" or "5.9.0")
        # Get major.minor.patch, defaulting patch to 0 if not present
        local major="${ZSH_VERSION%%.*}"
        local rest="${ZSH_VERSION#*.}"
        local minor="${rest%%.*}"
        local patch="${rest#*.}"
        patch="${patch%%.*}"
        # If patch is same as rest, it means there was no patch version
        if [ "$patch" = "$rest" ]; then
            patch="0"
        fi
        shell_version="${major}.${minor}.${patch}"
    elif [ -n "${BASH_VERSION:-}" ]; then
        shell_name="bash"
        # Extract version from BASH_VERSION (format: "5.3.3(1)-release")
        # Get major.minor.patch
        local major="${BASH_VERSION%%.*}"
        local rest="${BASH_VERSION#*.}"
        local minor="${rest%%.*}"
        local patch_rest="${rest#*.}"
        local patch="${patch_rest%%[^0-9]*}"
        # If patch extraction failed, try alternative method
        if [ -z "$patch" ] || [ "$patch" = "$patch_rest" ]; then
            # Fallback: just use major.minor
            shell_version="${major}.${minor}"
        else
            shell_version="${major}.${minor}.${patch}"
        fi
    else
        # Fallback: try to detect from $0 or SHELL
        if [ -n "${SHELL:-}" ]; then
            shell_name=$(basename "$SHELL")
            # Try to get version from shell command
            if command -v "$shell_name" >/dev/null 2>&1; then
                # Try to extract version (major.minor.patch or major.minor)
                shell_version=$("$shell_name" --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "unknown")
            else
                shell_version="unknown"
            fi
        else
            shell_name="unknown"
            shell_version="unknown"
        fi
    fi
    
    echo "$shell_name $shell_version"
}

# Get shell info
SHELL_INFO=$(detect_shell_info)
SHELL_NAME=$(echo "$SHELL_INFO" | cut -d' ' -f1)
SHELL_VERSION=$(echo "$SHELL_INFO" | cut -d' ' -f2)

# Get epoch timestamp for uniqueness and sorting
# Use get_epoch_timestamp if available (from lib-shell.sh), otherwise fallback to date
if command -v get_epoch_timestamp &> /dev/null; then
    TIMESTAMP=$(get_epoch_timestamp)
else
    TIMESTAMP=$(date +%s)
fi

# Generate standardized result filename: {shell}-{version}-test-results-{epoch}.txt
# Example: bash-5.3.3-test-results-1700832000.txt, zsh-5.9.0-test-results-1700832000.txt
RESULT_FILE="$RESULTS_DIR/${SHELL_NAME}-${SHELL_VERSION}-test-results-${TIMESTAMP}.txt"

echo -e "${GREEN}Running BATS tests...${NC}"
echo -e "${YELLOW}Shell: $SHELL_NAME $SHELL_VERSION${NC}"
echo -e "${YELLOW}Results will be written to: $RESULT_FILE${NC}"
echo ""

# Determine which test files to run
if [ $# -gt 0 ]; then
    # If arguments provided, use them as test files
    TEST_FILES=("$@")
    echo "Running specific test file(s): ${TEST_FILES[*]}" >&2
else
    # Otherwise, run all tests in the test directory
    TEST_FILES=("$TEST_DIR"/*.bats)
    echo "Running all tests in $TEST_DIR" >&2
fi

# Run BATS tests and capture output to both terminal and results file
# Write directly to results file using tee

    # Use get_timestamp if available, otherwise fallback to date
start_time=""
    if command -v get_timestamp &> /dev/null; then
        start_time=$(get_timestamp)
    else
        start_time=$(date '+%Y-%m-%d %H:%M:%S')
    fi
{
    echo "Test run started: $start_time"
    echo "Shell: $SHELL_NAME $SHELL_VERSION"
    echo "Test files: ${TEST_FILES[*]}"
    echo "---"
    echo ""
    
    # Run tests and capture both output and exit code, writing to both results file and terminal
    bats "${TEST_FILES[@]}" 2>&1
    TEST_EXIT_CODE=$?
    
    echo ""
    echo "---"
    # Use get_timestamp if available, otherwise fallback to date
    end_time=""
    if command -v get_timestamp &> /dev/null; then
        end_time=$(get_timestamp)
    else
        end_time=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    echo "Test run completed: $end_time"
    echo "Exit code: $TEST_EXIT_CODE"
} | tee "$RESULT_FILE"

# Display final status
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo -e "${GREEN}Results saved to: $RESULT_FILE${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some tests failed${NC}"
    echo -e "${RED}Results saved to: $RESULT_FILE${NC}"
    exit 1
fi

