# Dotfiles Architecture Documentation

This document describes the architecture, organization, and design principles of the dotfiles repository.

## Overview

This repository uses a modular, library-based architecture for managing dotfiles across macOS and Linux systems. The system is designed around the Single Responsibility Principle (SRP), Don't Repeat Yourself (DRY), and Small, Testable, Atomic, Reusable (STAR) principles.

## Directory Structure

```plaintext
dotfiles/
├── install.sh                    # Main orchestrator script
├── scripts/
│   ├── lib/                      # Shared library functions
│   ├── install/                  # Installation scripts
│   ├── check/                    # Verification scripts
│   └── test/                     # Test scripts
└── stow/                         # Stow packages (dotfile configs)
```

## Core Components

### 1. Main Orchestrator (`install.sh`)

The main entry point that coordinates all installation steps:

1. **Dependency Checking** - Verifies and installs required tools (stow, shells, oh-my-zsh)
2. **Package Stowing** - Creates symlinks using GNU Stow
3. **Special Files** - Creates machine-specific files (.secrets, .lmstudio-home-pointer)
4. **Package Installation** - Installs packages from Brewfile (optional)

**Key Features:**

- Supports `--dry-run`, `--verbose`, `--sync-local`, `--merge`, `--log-file`, `--no-progress`
- Passes arguments to child scripts via array expansion
- Sets up error handling and cleanup traps

### 2. Library System (`scripts/lib/`)

The library system is organized into focused, single-responsibility modules:

#### Library Loaders

The library system provides three loader options for different use cases:

- **`loaders/minimal.sh`** - Minimal loader for simple scripts
  - Core constants and OS detection
  - Basic output functions (err, warn, info)
  - Argument parsing

- **`loaders/standard.sh`** - Standard loader for most install scripts
  - Everything in minimal loader
  - Path utilities
  - Trap handlers
  - Temporary directory management
  - Logging and verbose output
  - Progress indicators

- **`loaders/full.sh`** - Full loader with all functionality
  - Everything in standard loader
  - Shell compatibility layer (arrays, strings, zsh modules)
  - Filesystem operations
  - Package management
  - Domain operations (stow, sync)

#### Core Layer (`core/`)

- **`core/constants.sh`** - Color constants and file permission constants
- **`core/detect-os.sh`** - OS detection (macOS, Linux)
- **`core/detect-shell.sh`** - Shell detection and version checking

#### Utility Layer (`util/`)

- **`util/output.sh`** - Basic output functions (err, die, warn, info, get_call_stack)
- **`util/timestamp.sh`** - Timestamp generation
- **`util/paths.sh`** - Path utilities and common variable initialization
- **`util/args.sh`** - Common command-line argument parsing

#### Feature Layer (`feature/`)

- **`feature/traps.sh`** - Trap handlers and signal handling
- **`feature/temp.sh`** - Temporary file management (single directory per script)
- **`feature/logging.sh`** - Structured logging system
- **`feature/verbose.sh`** - Standardized verbose output helpers
- **`feature/progress.sh`** - Progress indicators using ConEmu OSC 9;4 protocol
- **`feature/validation.sh`** - Input validation and sanitization
- **`feature/rollback.sh`** - Rollback/undo functionality

#### Filesystem Layer (`fs/`)

- **`fs/file-ops.sh`** - File operations and permissions
- **`fs/find.sh`** - Optimized file system operations with directory caching
- **`fs/zsh-globs.sh`** - Zsh-specific glob operations

#### Shell Layer (`shell/`)

- **`shell/zsh-modules.sh`** - Zsh module loading
- **`shell/arrays.sh`** - Array manipulation helpers
- **`shell/strings.sh`** - String manipulation functions

#### Package Management Layer (`pkg/`)

- **`pkg/cache.sh`** - Package status caching infrastructure
- **`pkg/brew.sh`** - Homebrew package/cask checking
- **`pkg/extensions.sh`** - VS Code/Cursor extension checking
- **`pkg/version.sh`** - Version comparison functions
- **`pkg/version-constraints.sh`** - Version constraints and YAML parsing

#### Domain Layer (`domain/`)

- **`domain/stow.sh`** - Stow operations (path transformation, symlink validation)
- **`domain/sync.sh`** - Basic sync operations (file comparison, binary detection)
- **`domain/sync-backup.sh`** - Backup creation for sync operations
- **`domain/sync-merge.sh`** - Merge/diff3 operations for sync

### 3. Installation Scripts (`scripts/install/`)

Each script handles a single installation task:

- **`check-dependencies.sh`** - Installs stow, shells, oh-my-zsh
- **`stow-packages.sh`** - Creates symlinks for all stow packages
- **`create-secrets.sh`** - Creates `.secrets` file with secure permissions
- **`create-lmstudio-pointer.sh`** - Creates LM Studio pointer file
- **`install-packages.sh`** - Installs packages from Brewfile

**Common Pattern:**

1. Source appropriate loader (`loaders/minimal.sh`, `loaders/standard.sh`, or `loaders/full.sh`)
2. Parse common arguments
3. Initialize temporary directory
4. Set up trap handlers
5. Perform operations with logging
6. Clean up on exit

### 4. Verification Scripts (`scripts/check/`)

- **`check-implementation.sh`** - Verifies dotfiles are fully implemented
  - Checks dependencies
  - Validates symlinks
  - Verifies package installations
  - Generates comprehensive report

## Data Flow

### Installation Flow

```plaintext
install.sh
  ├── check-dependencies.sh
  │   └── Uses: loaders/standard.sh
  ├── stow-packages.sh
  │   └── Uses: loaders/full.sh
  ├── create-secrets.sh
  │   └── Uses: loaders/full.sh
  ├── create-lmstudio-pointer.sh
  │   └── Uses: loaders/standard.sh
  └── install-packages.sh
      └── Uses: loaders/full.sh
```

### Library Dependencies

The library system uses a layered architecture with clear dependencies:

```plaintext
Layer 0: Core (no dependencies)
  ├── core/constants.sh
  ├── core/detect-os.sh
  └── core/detect-shell.sh

Layer 1: Utilities (depend on core/)
  ├── util/output.sh → core/constants.sh, core/detect-os.sh
  ├── util/timestamp.sh
  ├── util/paths.sh → core/detect-os.sh
  └── util/args.sh → util/output.sh

Layer 2: Features (depend on core/, util/)
  ├── feature/traps.sh → util/output.sh
  ├── feature/temp.sh → util/output.sh
  ├── feature/logging.sh → util/output.sh, util/timestamp.sh
  ├── feature/verbose.sh → util/output.sh
  ├── feature/progress.sh → util/output.sh
  ├── feature/validation.sh → util/output.sh
  └── feature/rollback.sh → feature/temp.sh, feature/logging.sh

Layer 2: Filesystem (depend on core/, util/)
  ├── fs/file-ops.sh → util/output.sh
  ├── fs/find.sh → util/output.sh
  └── fs/zsh-globs.sh → core/detect-os.sh

Layer 2: Shell (depend on core/)
  ├── shell/zsh-modules.sh → core/detect-os.sh
  ├── shell/arrays.sh → core/detect-shell.sh
  └── shell/strings.sh

Layer 3: Package Management (depend on core/, util/, feature/)
  ├── pkg/cache.sh → util/output.sh, pkg/extensions.sh
  ├── pkg/brew.sh → util/output.sh
  ├── pkg/extensions.sh → util/output.sh
  ├── pkg/version.sh → util/output.sh
  └── pkg/version-constraints.sh → pkg/version.sh

Layer 3: Domain (depend on core/, util/, feature/)
  ├── domain/stow.sh → util/output.sh
  ├── domain/sync.sh → util/output.sh
  ├── domain/sync-backup.sh → util/output.sh
  └── domain/sync-merge.sh → util/output.sh
```

## Design Principles

### 1. Single Responsibility Principle (SRP)

Each library file and function has one clear purpose:

- `lib-errors.sh` only handles errors
- `lib-logging.sh` only handles logging
- `lib-temp.sh` only manages temporary files

### 2. Don't Repeat Yourself (DRY)

Common functionality is extracted to libraries:

- Argument parsing: `parse_common_args()` in `util/args.sh`
- Verbose output: `verbose_*` functions in `feature/verbose.sh`
- Error handling: `err()`, `die()`, `warn()` in `util/output.sh`

### 3. Small, Testable, Atomic, Reusable (STAR)

Functions are:

- **Small**: Focused on a single task
- **Testable**: Pure functions where possible, minimal side effects
- **Atomic**: Complete operations that can't be partially executed
- **Reusable**: Used across multiple scripts

### 4. SOLID Principles

- **S**ingle Responsibility: Each module has one job
- **O**pen/Closed: Extensible through new library files
- **L**iskov Substitution: Functions have consistent interfaces
- **I**nterface Segregation: Minimal, focused function interfaces
- **D**ependency Inversion: Scripts depend on abstractions (library functions)

## Extension Points

### Adding a New Library

1. Determine the appropriate layer (core/, util/, feature/, fs/, shell/, pkg/, domain/)
2. Create the library file in the appropriate directory
3. Source dependencies from lower layers
4. Add re-sourcing guard: `if [ -n "${LIB_<NAME>_LOADED:-}" ]; then return 0; fi`
5. Export guard: `export LIB_<NAME>_LOADED=1`
6. Add to appropriate loader(s) if it should be auto-loaded

### Adding a New Installation Script

1. Create `scripts/install/<script-name>.sh`
2. Source appropriate loader (`loaders/minimal.sh`, `loaders/standard.sh`, or `loaders/full.sh`)
3. Use `parse_common_args "$@"` for argument handling
4. Initialize temp directory: `init_temp_dir "script-name.XXXXXX"`
5. Set up traps: `setup_traps cleanup_temp_dir`
6. Use logging functions for all operations
7. Add to `install.sh` if it should run automatically

### Adding a New Stow Package

1. Create `stow/<package-name>/` directory
2. Add files with `dot-` prefix (e.g., `dot-config` → `~/.config`)
3. Package will be automatically stowed by `stow-packages.sh`

## Error Handling

### Error Propagation

1. Functions return exit codes (0 = success, non-zero = failure)
2. Critical errors use `die()` which exits the script
3. Warnings use `warn()` which logs but continues
4. All errors are logged when `--log-file` is used

### Cleanup

- Temporary directories are automatically cleaned up on exit via trap handlers
- Rollback scripts are generated for destructive operations
- Error context is preserved in logs

## Performance Optimizations

### Package Status Caching

- `lib-packages.sh` caches package installation status in associative arrays
- Reduces redundant `brew list` calls by 10-100x for large package lists

### Directory Caching

- `lib-filesystem.sh` caches directory listings
- Reduces filesystem calls for repeated operations

### Zsh-Specific Optimizations

- **Glob Qualifiers**: Uses zsh glob patterns instead of `find` for file operations
  - Example: `**/*.sh(.)` for regular files, `**/*(/)` for directories
  - Significantly faster for large directory trees
- **Built-in File Operations**: Uses `zf_*` functions from `zsh/files` module
  - `zf_mkdir`, `zf_ln`, `zf_rm`, `zf_chmod` - faster than external commands
- **Built-in Stat**: Uses `zstat` from `zsh/stat` module instead of external `stat`
- **Parameter Expansion**: Uses zsh parameter expansion flags for string operations
  - `${(s:,:)string}` for splitting, `${(j:,:)array}` for joining
  - Faster than external `tr`, `sed`, or manual loops

### Nameref Variables

- Uses nameref variables (`local -n` / `typeset -n`) instead of `eval`
- Safer and more efficient array manipulation
- Automatic fallback to `eval` for older shells

### Completion Optimization (Zsh)

- Completion caching with `zstyle ':completion:*' use-cache yes`
- Cache stored in `~/.zsh/cache`
- Conditional `compinit` execution (only rebuilds cache when needed)
- Lazy loading of completions

### Modern Shell Features

- Uses `readarray`/`mapfile` instead of `while read` loops
- Uses associative arrays for efficient lookups
- Uses Bash 4+ string manipulation features
- **Nameref Variables**: Uses `local -n` (Bash 4.3+) and `typeset -n` (zsh) for safer array manipulation
- **Zsh Glob Qualifiers**: Uses zsh glob patterns (`**/*.sh(.)`) for faster file operations
- **Zsh Built-ins**: Uses `zstat`, `zf_*` functions when available for better performance
- **Parameter Expansion**: Leverages zsh parameter expansion flags for string/array operations
- **Feature Detection**: Automatic detection of shell capabilities with graceful fallbacks

### Shell Version Support

The codebase includes comprehensive version detection and feature gates:

**Version Detection (`lib-os.sh`):**

- `get_bash_version()` - Returns major.minor version string
- `compare_bash_version()` - Compares versions
- `is_bash_5_2_plus()`, `is_bash_5_1_plus()`, etc. - Version checks
- Feature flags: `BASH_5_2_PLUS`, `BASH_5_1_PLUS`, `BASH_5_0_PLUS`, etc.

**Feature Detection (`lib-os.sh`):**

- `has_nameref_support()` - Tests for nameref variables
- `has_wait_n_support()` - Tests for `wait -n` (Bash 5.1+)
- `has_xtracefd_support()` - Tests for `BASH_XTRACEFD` (Bash 5.1+)
- `has_mapfile_null_delim()` - Tests for `mapfile -d ''` (Bash 4.4+)

**Zsh Module Loading (`lib-shell.sh`):**

- `load_zsh_modules()` - Conditionally loads zsh modules
- Modules: `zsh/files`, `zsh/stat`, `zsh/datetime`, `zsh/parameter`
- Export flags: `ZSH_FILES_LOADED`, `ZSH_STAT_LOADED`, etc.

## Cross-Platform Compatibility

### OS Detection

- Detects macOS and Linux automatically
- Uses `detect_os()` function for consistent OS identification

### Path Handling

- Uses `normalize_path()` for consistent path resolution
- Handles both absolute and relative paths
- Works with symlinks correctly

### Command Availability

- Checks for command availability before use
- Provides fallbacks for missing commands
- Uses cross-platform alternatives (e.g., `stat` with different flags)

## Security Considerations

### File Permissions

- Secret files: 600 (read/write owner only)
- Secret directories: 700 (read/write/execute owner only)
- Constants defined in `core/constants.sh` for consistency

### Path Validation

- `lib-validation.sh` prevents path traversal attacks
- Validates all user-provided paths
- Sanitizes filenames before operations

### Temporary Files

- Created with secure permissions
- Automatically cleaned up on exit
- Stored in system temp directory with unique names

## Testing Strategy

### Unit Testing (Planned)

- BATS (Bash Automated Testing System) framework
- Tests for library functions
- Mock external dependencies

### Integration Testing

- `test-in-docker.sh` - Tests full installation in Docker containers
- `check-implementation.sh` - Verifies installation correctness

## Logging

### Structured Logging

- Timestamped entries
- Log levels (INFO, WARN, ERROR, DEBUG)
- Script name included in each entry
- Optional file logging via `--log-file`

### Log Format

```plaintext
[LEVEL] [script-name] (timestamp): message
```

Example:

```plaintext
[INFO] [stow-packages.sh] (2024-01-15 10:30:45): Creating symlinks...
[WARN] [stow-packages.sh] (2024-01-15 10:30:46): Skipping binary file: .config/file.bin
```

## Error Handling Enhancements

### Modern Error Handling Features

- **RETURN Trap**: Function-level cleanup and error tracking
- **BASH_XTRACEFD**: Separated debug output (Bash 5.1+)
- **Enhanced Error Context**: Call stack information in error messages
  - Uses `FUNCNAME` array (Bash) or `funcfiletrace` (zsh)
  - Includes file names and line numbers
- **Debug Tracing**: `--debug` flag with optional log file
- **Wait -n Support**: Wait for any background process (Bash 5.1+)

### Error Reporting

- `get_call_stack()` - Builds human-readable function call stack
- Enhanced `die()` and `handle_error()` with call stack information
- Better line number reporting using `BASH_LINENO` array

## Terminal Integration

### OSC Protocols

- **OSC 7**: Current directory reporting for terminal integration
  - Implemented in `.zshrc` (precmd hook) and `.bashrc` (PROMPT_COMMAND)
  - Format: `\033]7;file://hostname/path\033\\`
- **OSC 9;4**: Progress indicators (ConEmu protocol)
  - Used in `lib-progress.sh` for standardized progress reporting

### Ghostty Enhancements

- Enhanced Ghostty configuration with modern features
- Shell integration enabled (auto-detects shell and provides enhanced terminal features)
- Window titles are automatically set by Ghostty when shell-integration is enabled
  - Uses OSC 7 directory reporting (implemented in `.zshrc` and `.bashrc`)
  - Shows current directory and command information automatically

## Future Enhancements

### Planned Features

1. **Machine-Specific Overrides** - Support for `stow/local/` directory
2. **Conditional Package Installation** - OS/architecture-based conditionals
3. **Parallel Processing** - Parallel package checks and installations
4. **Automated Testing Framework** - Comprehensive BATS test suite
5. **Performance Benchmarking** - Benchmark scripts for optimization validation

## Troubleshooting

### Common Issues

1. **Scripts can't find libraries**
   - Ensure `SCRIPTS_DIR` is set correctly
   - Check that the appropriate loader exists at `$SCRIPTS_DIR/lib/loaders/`

2. **Permission errors**
   - Check file permissions on scripts (should be executable)
   - Verify write permissions in target directories

3. **Symlink conflicts**
   - Use `--sync-local` to merge local changes
   - Use `--dry-run` to preview changes
   - Check `check-implementation.sh` for detailed status

4. **Package installation failures**
   - Check `--verbose` output for details
   - Review log file if `--log-file` was used
   - Verify package manager is installed and working

### Debug Mode

- Use `--verbose` for detailed output
- Use `--log-file` to capture all operations
- Use `--dry-run` to preview without making changes

## Contributing

When contributing:

1. Follow SRP, DRY, STAR, and SOLID principles
2. Add comprehensive function documentation
3. Use logging functions instead of `echo` for operations
4. Initialize temp directories and set up traps
5. Test on both macOS and Linux
6. Update this documentation if architecture changes
