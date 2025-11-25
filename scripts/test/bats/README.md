# BATS Test Suite

This directory contains the BATS (Bash Automated Testing System) test suite for the dotfiles installation scripts.

## Prerequisites

Install BATS and required helper libraries:

### macOS

```bash
brew install bats-core
sudo git clone https://github.com/bats-core/bats-support.git /usr/local/lib/bats-support
sudo git clone https://github.com/bats-core/bats-assert.git /usr/local/lib/bats-assert
sudo git clone https://github.com/bats-core/bats-file.git /usr/local/lib/bats-file
```

### Linux

```bash
# Install BATS
git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
sudo /tmp/bats-core/install.sh /usr/local

# Install helper libraries
sudo git clone https://github.com/bats-core/bats-support.git ~/.local/lib/bats-support
sudo git clone https://github.com/bats-core/bats-assert.git ~/.local/lib/bats-assert
sudo git clone https://github.com/bats-core/bats-file.git ~/.local/lib/bats-file
```

## Running Tests

### Run all tests

```bash
./scripts/test/bats/run_tests.sh
```

Or directly with BATS:

```bash
bats scripts/test/bats/
```

### Run specific test file

```bash
bats scripts/test/bats/test_lib_core.bats
```

### Run with verbose output

```bash
bats --verbose scripts/test/bats/
```

### Run with tap output

```bash
bats --tap scripts/test/bats/
```

## Test Files

- **test_helper.bash** - Common test utilities, setup, and teardown functions
- **test_lib_core.bats** - Tests for core libraries (constants, OS detection, paths, args, verbose, shell)
- **test_lib_file.bats** - Tests for file operations and permissions
- **test_lib_temp.bats** - Tests for temporary file management
- **test_lib_errors.bats** - Tests for error handling and reporting
- **test_lib_logging.bats** - Tests for structured logging
- **test_lib_validation.bats** - Tests for input validation and sanitization
- **test_lib_stow.bats** - Tests for Stow operations and symlink management
- **test_lib_packages.bats** - Tests for package checking functions
- **test_lib_filesystem.bats** - Tests for filesystem operations and caching
- **test_lib_sync.bats** - Tests for sync operations and file comparison
- **test_lib_progress.bats** - Tests for progress indicators
- **test_lib_rollback.bats** - Tests for rollback functionality

## Test Coverage

The test suite covers:

### Critical Functionality

- ✅ Core library functions (constants, OS detection, path utilities)
- ✅ Argument parsing
- ✅ Error handling and reporting
- ✅ Logging system
- ✅ File operations and permissions
- ✅ Temporary file management
- ✅ Input validation and security

### Medium Functionality

- ✅ Stow operations and symlink management
- ✅ Package checking (with mocks)
- ✅ Filesystem operations and caching
- ✅ Sync operations
- ✅ Progress indicators
- ✅ Rollback functionality

## Writing New Tests

When adding new functionality, add corresponding tests:

1. Create or update the appropriate test file in `scripts/test/bats/`
2. Use the `load_lib` helper to source library files
3. Use BATS assertions (`assert_success`, `assert_output`, etc.)
4. Use test helper functions from `test_helper.bash`
5. Mock external commands when needed using `mock_command`

Example:

```bash
@test "my_function: does something correctly" {
    load_lib "lib-my"
    
    run my_function "arg1" "arg2"
    assert_success
    assert_output "expected output"
}
```

## Test Isolation

Each test runs in isolation:

- Uses `BATS_TEST_TMPDIR` for temporary files
- Creates isolated test environment (HOME, DOTFILES_DIR, etc.)
- Cleans up automatically after each test
- Mocks external commands to avoid side effects
