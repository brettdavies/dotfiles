# Performance Documentation

This document describes the performance characteristics of various shell operations and provides recommendations for optimal performance.

## Overview

The dotfiles codebase includes multiple implementations of common operations, optimized for different shell versions and capabilities. This document provides guidance on which implementations to use and their performance characteristics.

## Benchmarking

A benchmark script is available at `scripts/test/benchmark.sh` to measure performance of different implementations:

```bash
./scripts/test/benchmark.sh [test_directory]
```

The script compares:

- Zsh glob qualifiers vs `find` command
- Zsh built-in file operations vs external commands
- Nameref array assignment vs eval
- Zsh built-in stat vs external stat

## Performance Characteristics

### File Finding Operations

**Zsh Glob Qualifiers** (Recommended for zsh):

- **Performance**: Significantly faster than `find` for large directory trees
- **Use Case**: When running under zsh with `zsh/files` module loaded
- **Example**: `**/*.sh(.)` for regular files
- **Advantages**:
  - No external process spawning
  - Built-in pattern matching
  - Efficient directory traversal
- **Limitations**: Only available in zsh

**Find Command** (Fallback):

- **Performance**: Slower but more portable
- **Use Case**: Bash or when zsh globs are not available
- **Example**: `find . -type f -name "*.sh"`
- **Advantages**:
  - Works in all shells
  - More flexible options
- **Limitations**: Requires external process

**Recommendation**: Use zsh glob qualifiers when available, fall back to `find` otherwise.

### File Operations

**Zsh Built-in Functions** (`zf_*`):

- **Performance**: Faster than external commands (no process spawning)
- **Functions**: `zf_mkdir`, `zf_ln`, `zf_rm`, `zf_chmod`
- **Use Case**: When running under zsh with `zsh/files` module loaded
- **Advantages**:
  - No fork/exec overhead
  - Faster for many operations
- **Limitations**: Only available in zsh

**External Commands** (Fallback):

- **Performance**: Slower due to process spawning
- **Use Case**: Bash or when zsh built-ins are not available
- **Advantages**:
  - Works in all shells
  - Standard POSIX commands
- **Limitations**: Process overhead

**Recommendation**: Use zsh built-ins when available, fall back to external commands otherwise.

### Stat Operations

**Zsh Built-in `zstat`**:

- **Performance**: Faster than external `stat` command
- **Use Case**: When running under zsh with `zsh/stat` module loaded
- **Advantages**:
  - No process spawning
  - Direct system call access
- **Limitations**: Only available in zsh

**External `stat` Command** (Fallback):

- **Performance**: Slower due to process spawning
- **Use Case**: Bash or when zsh built-in is not available
- **Advantages**:
  - Works in all shells
  - Cross-platform (macOS `stat -f`, Linux `stat -c`)
- **Limitations**: Process overhead

**Recommendation**: Use `zstat` when available, fall back to external `stat` otherwise.

### Array Operations

**Nameref Variables** (Bash 4.3+ / zsh):

- **Performance**: Slightly faster and safer than `eval`
- **Use Case**: When nameref support is available
- **Advantages**:
  - No eval overhead
  - Type safety
  - Better error messages
- **Limitations**: Requires Bash 4.3+ or zsh

**Eval** (Fallback):

- **Performance**: Slower due to string parsing
- **Use Case**: Bash 3.2 or earlier
- **Advantages**:
  - Works in all shells
  - Universal compatibility
- **Limitations**: Security concerns, slower performance

**Recommendation**: Use nameref when available, fall back to eval for older shells.

### Parameter Expansion

**Zsh Parameter Expansion Flags**:

- **Performance**: Significantly faster than external commands
- **Use Case**: String/array operations in zsh
- **Examples**:
  - `${(s:,:)string}` - Split string
  - `${(j:,:)array}` - Join array
  - `${string:u}` - Uppercase (zsh 5.1+)
  - `${string:l}` - Lowercase (zsh 5.1+)
- **Advantages**:
  - No external process
  - Built-in operations
- **Limitations**: Only available in zsh

**External Commands** (Fallback):

- **Performance**: Slower due to process spawning
- **Use Case**: Bash or older zsh
- **Examples**: `tr`, `sed`, manual loops
- **Advantages**:
  - Works in all shells
  - Standard tools
- **Limitations**: Process overhead

**Recommendation**: Use zsh parameter expansion when available, fall back to external commands otherwise.

## Performance Optimization Tips

1. **Use zsh when possible**: Zsh provides many built-in optimizations
2. **Load zsh modules**: Modules like `zsh/files` and `zsh/stat` provide faster operations
3. **Use glob qualifiers**: Zsh glob qualifiers are faster than `find` for file operations
4. **Prefer nameref over eval**: Nameref variables are safer and slightly faster
5. **Cache results**: Directory and package caches reduce redundant operations
6. **Batch operations**: Group operations when possible to reduce overhead

## Benchmark Results

*Note: Actual benchmark results will vary based on system, shell version, and workload. Run `scripts/test/benchmark.sh` on your system for specific measurements.*

### Typical Performance Improvements

- **Zsh globs vs find**: 2-5x faster for large directory trees
- **Zsh built-ins vs external commands**: 1.5-3x faster
- **Nameref vs eval**: 10-20% faster
- **Zsh parameter expansion vs external commands**: 3-10x faster

## Testing Performance

To test performance on your system:

```bash
# Run benchmarks
./scripts/test/benchmark.sh

# Or specify a test directory
./scripts/test/benchmark.sh /tmp/my-test-dir
```

The benchmark script will:

1. Create a test directory structure
2. Run each operation multiple times
3. Calculate average execution time
4. Display a summary of results

## Conclusion

The codebase automatically selects the fastest available implementation based on shell capabilities. When running under zsh with modules loaded, you'll get the best performance. When running under bash or older shells, the code gracefully falls back to compatible implementations.

For best performance:

- Use zsh 5.9+ with all modules loaded
- Use Bash 5.2+ for best bash performance
- Ensure zsh modules are loaded (automatic in `.zshrc`)
