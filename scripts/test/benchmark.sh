#!/usr/bin/env bash
# Performance benchmarking script for modern shell features
# Compares zsh globs vs find, built-ins vs external commands, nameref vs eval

set -euo pipefail
# Disable any debug/trace modes that might print variable assignments
set +x

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Benchmark configuration
ITERATIONS=20
TEST_DIR="${1:-/tmp/benchmark-test}"
# Scale: Create more files to better measure performance differences
# Default: 200 directories × 100 files = 20,000 files
SCALE_DIRS="${BENCHMARK_SCALE_DIRS:-200}"
SCALE_FILES="${BENCHMARK_SCALE_FILES:-100}"

echo -e "${GREEN}Shell Performance Benchmark${NC}"
echo "================================"
echo "Test directory: $TEST_DIR"
echo "Iterations per test: $ITERATIONS"
echo ""

# Create test directory structure
setup_test_dir() {
    echo -e "${YELLOW}Setting up test directory...${NC}"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    
    # Create a directory tree with files
    # Use variables for scale to allow customization
    local total_files=0
    for i in $(seq 1 "$SCALE_DIRS"); do
        mkdir -p "$TEST_DIR/dir$i"
        for j in $(seq 1 "$SCALE_FILES"); do
            touch "$TEST_DIR/dir$i/file$j.txt"
            touch "$TEST_DIR/dir$i/file$j.sh"
            total_files=$((total_files + 2))
        done
    done
    
    echo "Created test directory with ~$total_files files ($SCALE_DIRS directories, $SCALE_FILES files per directory)"
    echo ""
}

# Benchmark function
benchmark() {
    local name="$1"
    local command="$2"
    local total=0
    
    # Output informational messages to stderr so they don't interfere with result capture
    echo -e "${YELLOW}Benchmarking: $name${NC}" >&2
    
    for ((i=1; i<=ITERATIONS; i++)); do
        local start end duration
        # Capture timestamps, ensuring no debug output leaks to stdout
        start=$(date +%s%N 2>/dev/null)
        eval "$command" > /dev/null 2>&1
        end=$(date +%s%N 2>/dev/null)
        # Calculate duration in milliseconds
        if [ -n "$start" ] && [ -n "$end" ] && [ "$start" -gt 0 ] && [ "$end" -gt 0 ]; then
            duration=$(( (end - start) / 1000000 ))
        else
            # Fallback if nanoseconds not available (use seconds * 1000)
            start=$(date +%s 2>/dev/null)
            eval "$command" > /dev/null 2>&1
            end=$(date +%s 2>/dev/null)
            duration=$(( (end - start) * 1000 ))
        fi
        total=$((total + duration))
    done
    
    local avg=$((total / ITERATIONS))
    echo -e "${GREEN}Average: ${avg}ms${NC}" >&2
    echo "" >&2
    
    # Output only the numeric result to stdout for capture
    echo "$avg"
}

# Run benchmarks
run_benchmarks() {
    local results=()
    
    # Test 1: File finding - find command
    if command -v find &> /dev/null; then
        local result
        result=$(benchmark "find command" "find '$TEST_DIR' -type f -name '*.sh' | wc -l")
        results+=("find:$result")
    fi
    
    # Test 2: File finding - zsh globs (if zsh)
    if [ -n "${ZSH_VERSION:-}" ]; then
        local result
        result=$(benchmark "zsh glob qualifiers" "files=(\$TEST_DIR/**/*.sh(.)); echo \${#files[@]}")
        results+=("zsh_glob:$result")
    fi
    
    # Test 3: Directory creation - external mkdir
    local result
    result=$(benchmark "external mkdir" "mkdir -p '$TEST_DIR/mkdir_test' 2>/dev/null; rmdir '$TEST_DIR/mkdir_test' 2>/dev/null")
    results+=("mkdir:$result")
    
    # Test 4: Directory creation - zsh built-in (if zsh)
    if [ -n "${ZSH_VERSION:-}" ] && zmodload zsh/files 2>/dev/null && command -v zf_mkdir &> /dev/null; then
        local result
        result=$(benchmark "zsh zf_mkdir" "zf_mkdir -p '$TEST_DIR/zf_mkdir_test' 2>/dev/null; zf_rm -r '$TEST_DIR/zf_mkdir_test' 2>/dev/null")
        results+=("zf_mkdir:$result")
    fi
    
    # Test 5: Stat command - external
    if command -v stat &> /dev/null; then
        local result
        result=$(benchmark "external stat" "stat -f '%z' '$TEST_DIR/dir1/file1.txt' 2>/dev/null || stat -c '%s' '$TEST_DIR/dir1/file1.txt' 2>/dev/null")
        results+=("stat:$result")
    fi
    
    # Test 6: Stat command - zsh built-in (if zsh)
    if [ -n "${ZSH_VERSION:-}" ] && zmodload zsh/stat 2>/dev/null; then
        local result
        result=$(benchmark "zsh zstat" "zstat -A size +size '$TEST_DIR/dir1/file1.txt' 2>/dev/null; echo \$size")
        results+=("zstat:$result")
    fi
    
    # Test 7: Array assignment - eval (larger scale)
    local result
    result=$(benchmark "array assignment (eval, 10000)" "arr=(); for i in \$(seq 1 10000); do arr+=(\$i); done")
    results+=("eval_array:$result")
    
    # Test 8: Array assignment - nameref (if supported, larger scale)
    if [ -n "${BASH_VERSION:-}" ] && [[ "${BASH_VERSION:0:1}" -ge 4 ]] && [[ "${BASH_VERSION:2:1}" -ge 3 ]]; then
        local result
        result=$(benchmark "array assignment (nameref, 10000)" "declare -n arr_ref=test_arr; test_arr=(); for i in \$(seq 1 10000); do test_arr+=(\$i); done")
        results+=("nameref_array:$result")
    fi
    
    # Test 9: String manipulation - parameter expansion (bash internal)
    local result
    result=$(benchmark "string manipulation (1000 ops)" "str='test'; for i in {1..1000}; do str=\${str//t/x}; str=\${str//x/t}; done")
    results+=("string_manip:$result")
    
    # Test 10: Pattern matching - case statement (bash internal)
    local result
    result=$(benchmark "pattern matching (1000 ops)" "for i in {1..1000}; do case \"file\$i.txt\" in *.txt) : ;; *) : ;; esac; done")
    results+=("pattern_match:$result")
    
    # Test 11: Arithmetic operations (bash internal)
    local result
    result=$(benchmark "arithmetic operations (100000 ops)" "total=0; i=1; while [ \$i -le 100000 ]; do total=\$((total + i)); i=\$((i + 1)); done")
    results+=("arithmetic:$result")
    
    # Test 12: Array iteration (bash internal)
    local result
    result=$(benchmark "array iteration (1000 elements)" "arr=(\$(seq 1 1000)); for item in \"\${arr[@]}\"; do :; done")
    results+=("array_iter:$result")
    
    # Test 13: Substring operations (bash internal)
    local result
    result=$(benchmark "substring operations (1000 ops)" "str='abcdefghijklmnopqrstuvwxyz'; for i in {1..1000}; do substr=\${str:\$((i%20)):10}; done")
    results+=("substring:$result")
    
    # Print summary
    echo -e "${GREEN}Benchmark Summary${NC}"
    echo "=================="
    for result in "${results[@]}"; do
        local name="${result%%:*}"
        local time="${result##*:}"
        printf "%-20s %6sms\n" "$name" "$time"
    done
}

# Main
main() {
    setup_test_dir
    run_benchmarks
    
    echo -e "${YELLOW}Cleaning up...${NC}"
    rm -rf "$TEST_DIR"
    echo -e "${GREEN}Done!${NC}"
}

main "$@"

