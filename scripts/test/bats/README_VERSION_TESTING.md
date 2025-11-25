# Testing with Different Shell Versions

This document explains how to test the codebase with different shell versions to verify fallback mechanisms work correctly.

## Overview

The codebase includes fallback mechanisms for different shell versions:

- **Bash 5.2+**: Full feature support
- **Bash 4.3+**: Nameref support
- **Bash 4.0+**: Associative arrays, readarray
- **Bash 3.2**: Basic functionality with eval fallbacks
- **Zsh**: Zsh-specific optimizations with fallbacks to standard commands

## Testing Fallback Behavior

### Running Tests with Different Shell Versions

The BATS tests are designed to work with the shell that runs them. To test fallback behavior, you need to run the tests with different shell versions.

#### Testing with Different Bash Versions

```bash
# Test with Bash 5.2+ (if available)
bash5.2 scripts/test/bats/run_tests.sh

# Test with Bash 4.4
bash4.4 scripts/test/bats/run_tests.sh

# Test with Bash 4.0
bash4.0 scripts/test/bats/run_tests.sh

# Test with Bash 3.2 (macOS default)
/usr/bin/bash scripts/test/bats/run_tests.sh
```

#### Testing with Zsh

```bash
# Test with zsh
zsh scripts/test/bats/run_tests.sh
```

### Using Docker for Version Testing

You can use Docker to test with specific shell versions:

```bash
# Test with Bash 5.2
docker run --rm -v "$(pwd):/workspace" -w /workspace bash:5.2 bash scripts/test/bats/run_tests.sh

# Test with Bash 4.4
docker run --rm -v "$(pwd):/workspace" -w /workspace bash:4.4 bash scripts/test/bats/run_tests.sh

# Test with Bash 3.2 (Alpine Linux)
docker run --rm -v "$(pwd):/workspace" -w /workspace alpine:latest sh -c "apk add bash bats && bash scripts/test/bats/run_tests.sh"
```

### Manual Fallback Testing

To manually verify fallback behavior:

1. **Test nameref fallback**:

   ```bash
   # In Bash 3.2 (no nameref support)
   /usr/bin/bash -c 'source scripts/lib/lib-shell.sh; read_lines_into_array arr "/etc/passwd"; echo ${#arr[@]}'
   ```

2. **Test zsh glob fallback**:

   ```bash
   # In bash (no zsh globs)
   bash -c 'source scripts/lib/lib-filesystem.sh; find_files_in_dir "/tmp" "-type f"; echo ${#FIND_RESULTS[@]}'
   ```

3. **Test zsh built-in fallback**:

   ```bash
   # In bash (no zsh built-ins)
   bash -c 'source scripts/lib/lib-file.sh; get_file_permissions "/etc/passwd"'
   ```

## Test Coverage

The test suite includes:

1. **Version Detection Tests** (`test_lib_os_advanced.bats`):
   - Tests version detection functions
   - Tests feature detection functions
   - Verifies correct version reporting

2. **Fallback Tests** (in various test files):
   - `read_lines_into_array` works with nameref and eval fallback
   - `find_files_in_dir` works with zsh globs and find fallback
   - `get_file_permissions` works with zstat and external stat
   - Parameter expansion helpers work with zsh flags and external commands

3. **Cross-Platform Tests**:
   - Tests verify functions work on both macOS and Linux
   - Tests verify functions work with different shell versions

## Expected Behavior

### When Advanced Features Are Available

- Functions use the fastest/most efficient implementation
- Nameref variables are used instead of eval
- Zsh glob qualifiers are used instead of find
- Zsh built-ins are used instead of external commands

### When Advanced Features Are Not Available

- Functions gracefully fall back to compatible implementations
- Eval is used when nameref is not available
- Find command is used when zsh globs are not available
- External commands are used when zsh built-ins are not available
- Results are identical regardless of implementation used

## Verifying Fallback Behavior

To verify that fallbacks work correctly:

1. Run tests with a shell version that doesn't support advanced features
2. Verify that tests pass (proving fallback works)
3. Compare results with tests run on a shell with full feature support
4. Verify that results are identical

## Continuous Integration

For CI/CD, consider:

1. Running tests with multiple shell versions
2. Using a matrix build to test Bash 3.2, 4.0, 4.4, 5.0, 5.2, and zsh
3. Verifying that all tests pass across all versions

Example GitHub Actions matrix:

```yaml
strategy:
  matrix:
    shell: [bash3.2, bash4.0, bash4.4, bash5.0, bash5.2, zsh]
```

## Notes

- Some tests use `skip` when features aren't available - this is expected
- Tests that verify fallback behavior should NOT skip - they test that fallbacks work
- The test suite is designed to pass regardless of shell version
- All functions should produce identical results regardless of implementation used
