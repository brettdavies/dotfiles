# Dotfiles

> **[View Project Overview](PROJECT.md)** - High-level summary for quick reference

Personal dotfiles managed with GNU Stow for syncing across macOS and Linux machines.

## Structure

This repository uses [GNU Stow](https://www.gnu.org/software/stow/) to manage symlinks for configuration files. Each directory in `stow/` contains files that will be symlinked to your home directory.

The installation process is modular, with `install.sh` orchestrating several single-purpose scripts organized in subdirectories.

**Documentation:**

- **[FILE_TREE.md](FILE_TREE.md)** - Complete repository structure and file organization
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Architecture documentation, design principles, and extension points

**Shared Libraries** (`scripts/lib/`):

The library system uses a modular, layered architecture with three loader options:

**Loaders** (choose based on needs):

- `loaders/minimal.sh` - Minimal loader for simple scripts (colors, basic output, argument parsing)
- `loaders/standard.sh` - Standard loader for most install scripts (adds paths, traps, temp, logging, verbose, progress)
- `loaders/full.sh` - Full loader with all functionality (includes package management, filesystem, domain operations)

**Core Layer** (`core/`):

- `core/constants.sh` - Color constants and file permission constants
- `core/detect-os.sh` - OS detection (macOS, Linux)
- `core/detect-shell.sh` - Shell detection and version checking (zsh, bash)

**Utility Layer** (`util/`):

- `util/output.sh` - Basic output functions (err, die, warn, info)
- `util/timestamp.sh` - Timestamp generation
- `util/paths.sh` - Path utilities and common variable initialization
- `util/args.sh` - Common command-line argument parsing

**Feature Layer** (`feature/`):

- `feature/traps.sh` - Trap handlers and signal handling
- `feature/temp.sh` - Temporary directory management
- `feature/logging.sh` - Structured logging system
- `feature/verbose.sh` - Standardized verbose output helpers
- `feature/progress.sh` - Progress indicators using ConEmu OSC 9;4 protocol
- `feature/validation.sh` - Input validation and sanitization
- `feature/rollback.sh` - Rollback/undo functionality

**Filesystem Layer** (`fs/`):

- `fs/file-ops.sh` - File operations and permissions
- `fs/find.sh` - Optimized file system operations with directory caching
- `fs/zsh-globs.sh` - Zsh-specific glob operations

**Shell Layer** (`shell/`):

- `shell/zsh-modules.sh` - Zsh module loading
- `shell/arrays.sh` - Array manipulation helpers
- `shell/strings.sh` - String manipulation functions

**Package Management Layer** (`pkg/`):

- `pkg/cache.sh` - Package status caching infrastructure
- `pkg/brew.sh` - Homebrew package/cask checking
- `pkg/extensions.sh` - VS Code/Cursor extension checking
- `pkg/version.sh` - Version comparison functions
- `pkg/version-constraints.sh` - Version constraints and YAML parsing

**Domain Layer** (`domain/`):

- `domain/stow.sh` - Stow-specific operations and symlink checking
- `domain/sync.sh` - Basic sync operations
- `domain/sync-backup.sh` - Backup creation for sync operations
- `domain/sync-merge.sh` - Merge/diff3 operations for sync

**Installation Scripts** (`scripts/install/`):

- `check-dependencies.sh` - Installs required dependencies
- `stow-packages.sh` - Creates symlinks using `stow --dotfiles`
- `create-secrets.sh` - Creates `.secrets` file
- `create-lmstudio-pointer.sh` - Creates LM Studio pointer file
- `install-packages.sh` - Installs packages from Brewfile

**Verification Scripts** (`scripts/check/`):

- `check-implementation.sh` - Verifies dotfiles are fully implemented

**Test Scripts** (`scripts/test/`):

- `test-in-docker.sh` - Tests installation in Docker containers
- `bats/` - BATS (Bash Automated Testing System) test suite
  - `test_helper.bash` - Common test utilities and setup
  - `run_tests.sh` - Test runner script
  - `test_lib_*.bats` - Unit tests for library functions
  - Run tests with: `./scripts/test/bats/run_tests.sh` or `bats scripts/test/bats/`

**Dotfile Convention**: Files in the repository use `dot-` prefix (e.g., `dot-bashrc`) to keep them visible in file managers. The `stow --dotfiles` option automatically converts these to `.` prefixed symlinks (e.g., `.bashrc`) in your home directory.

```plaintext
stow/
├── shell/        # Shared shell configs (.profile, .telemetry.sh, .models.sh, .caches.sh)
├── zsh/          # Zsh configs (.zshrc, .zprofile, .p10k.zsh)
├── bash/         # Bash configs (.bashrc, .bash_profile)
├── git/          # Git config (.gitconfig, .config/git/*)
├── ssh/          # SSH config (.ssh/config)
├── ghostty/      # Ghostty terminal config (.config/ghostty/config)
├── gh/           # GitHub CLI config (.config/gh/config.yml, hosts.yml)
├── oh-my-zsh/    # oh-my-zsh custom files (.oh-my-zsh/custom/*)
├── vscode/       # VS Code settings (Library/Application Support/Code/User/*)
├── local/        # Local bin configs (.local/bin/env)
├── claude/       # Claude IDE configs (.claude/settings.json, statusline.sh)
├── codex/        # Codex configs (.codex/config.toml)
├── opencode/     # OpenCode configs (.config/opencode/config.json)
└── brew/         # Brewfile for Homebrew packages
```

## Initial Setup

### Prerequisites

- Git
- GNU Stow (will be installed automatically if missing)
- Homebrew (macOS only - for package installation)
- yq 4.0+ (will be installed/upgraded automatically if needed - required for `generate-brewfile.sh`)
- `diff3` (part of `diffutils` package) - Required only if using `--sync-local --merge` mode. Will be prompted to install automatically if missing.

**Check prerequisites**:

   ```bash
   echo "Checking prerequisites..."; echo "----"; MISSING=0; for cmd in git stow; do command -v $cmd >/dev/null 2>&1 && echo "✓ $cmd" || (echo "✗ $cmd missing" && MISSING=$((MISSING+1))); done; [[ "$OSTYPE" == "darwin"* ]] && (command -v brew >/dev/null 2>&1 && echo "✓ homebrew" || (echo "✗ homebrew missing" && MISSING=$((MISSING+1)))) || echo "○ homebrew (not required on Linux)"; command -v diff3 >/dev/null 2>&1 && echo "✓ diff3" || echo "⚠ diff3 missing (required for --merge mode)"; echo "----"; [ $MISSING -eq 0 ] && echo "✓ All required prerequisites installed" || echo "✗ Some prerequisites are missing"
   ```

### Installation

1. Clone this repository:

   ```bash
   git clone <your-repo-url> ~/dotfiles
   cd ~/dotfiles
   ```

2. Run the install script:

   ```bash
   ./install.sh
   ```

   **Installation Options**:
   - `./install.sh` - Run full installation
   - `./install.sh --dry-run` - Preview what would be done without making changes
   - `./install.sh --check` - Check current implementation status (no installation)
   - `./install.sh --verbose` or `-v` - Show detailed output
   - `./install.sh --sync-local` - Sync local changes back into repository before installation
   - `./install.sh --sync-local --merge` - Sync with merge mode (merges conflicts instead of overwriting)
   - `./install.sh --log-file FILE` - Enable logging to a file (for debugging and audit trails)

The script orchestrates several modular scripts in the `scripts/install/` directory:

- **check-dependencies.sh**: Installs GNU Stow, shells (zsh/bash), yq 4.0+, and oh-my-zsh if missing
- **stow-packages.sh**: Creates symlinks for all configuration files using `stow --dotfiles`
- **create-secrets.sh**: Creates an empty `.secrets` file with proper permissions (600)
- **create-lmstudio-pointer.sh**: Creates `.lmstudio-home-pointer` if LM Studio is installed (optional)
- **install-packages.sh**: Optionally installs packages from Brewfile (macOS: via Homebrew, Linux: via package manager) and sets up oh-my-zsh plugins/themes

**Note**: See [FILE_TREE.md](FILE_TREE.md) for the complete repository structure and file organization.

**Note**: The installer uses `stow --dotfiles` which automatically converts `dot-*` prefixed files in the repository to `.*` prefixed symlinks in your home directory. This keeps files visible in the repository while creating proper hidden dotfiles.

### Verifying Installation

After installation, you can verify that everything is set up correctly:

   ```bash
   ./install.sh --check
   ```

Or run the verification script directly:

   ```bash
   ./scripts/check/check-implementation.sh
   ```

The verification script checks:

- Dependencies (stow, shells, oh-my-zsh)
- All stow package symlinks
- Special files (.secrets with correct permissions)
- Homebrew packages (macOS only)
- VS Code extensions (macOS only)
- Cursor extensions

Options for `check-implementation.sh`:

- `--quiet` or `-q` - Suppress output except for summary
- `--verbose` or `-v` - Show detailed output for each check
- `--output FILE` or `-o FILE` - Save results to a file

### Manual Installation (if you prefer)

If you don't want to use the install script, you can manually stow each package:

   ```bash
   cd ~/dotfiles/stow
   stow -t ~ shell zsh bash git ssh ghostty gh oh-my-zsh
   ```

For VS Code on macOS:

   ```bash
   stow -t ~/Library/Application\ Support/Code/User -d ~/dotfiles/stow vscode
   ```

## Updating

### Syncing Changes from Repository

After making changes to your dotfiles in the repository:

1. Commit and push changes:

   ```bash
   cd ~/dotfiles
   git add .
   git commit -m "Update dotfiles"
   git push
   ```

2. On other machines, pull the latest changes:

   ```bash
   cd ~/dotfiles
   git pull
   ```

3. Restow packages if needed:

   ```bash
   cd ~/dotfiles/stow
   stow -t ~ -R shell zsh bash git ssh ghostty gh oh-my-zsh
   ```

   Or simply run the install script again:

   ```bash
   ./install.sh
   ```

### Syncing Local Changes Back to Repository

If you've made local changes to your dotfiles and want to sync them back into the repository:

1. **Preview what would be synced** (recommended first step):

   ```bash
   ./install.sh --sync-local --dry-run
   ```

2. **Sync with overwrite mode** (replaces repo files with local versions):

   ```bash
   ./install.sh --sync-local
   ```

3. **Sync with merge mode** (attempts to merge changes, creates conflict markers if needed):

   ```bash
   ./install.sh --sync-local --merge
   ```

   **Merge Mode Requirements**:
   - Merge mode requires `diff3` (part of `diffutils` package)
   - If `diff3` is not installed, the script will prompt to install it automatically
   - Merge mode uses git-based three-way merging: it uses the last committed version from git HEAD as the base file for more accurate merges
   - If a file is not tracked by git, an empty file is used as the base

4. **Review and commit the synced changes**:

   ```bash
   git status
   git diff
   git add .
   git commit -m "Sync local changes"
   git push
   ```

**Notes**:

- The sync feature only syncs text files. Binary files are automatically skipped.
- Files that are already correctly symlinked are also skipped.
- Merge mode requires `diff3`. Installation commands:

  - macOS: `brew install diffutils`
  - Linux: `sudo apt-get install diffutils` (Debian/Ubuntu) or equivalent for your distribution

## Included Configurations

### Shell Configs

- **Zsh**: `.zshrc`, `.zprofile`, `.p10k.zsh` (Powerlevel10k theme)
- **Bash**: `.bashrc`, `.bash_profile`

These files may reference each other (e.g., `.zshrc` may source `.secrets`). The symlink structure preserves these relationships.

### oh-my-zsh

- **oh-my-zsh**: Automatically installed if not present
- **Plugins**: The following plugins are installed via Homebrew and symlinked:
  - `zsh-autosuggestions` - Auto-suggestions as you type
  - `zsh-syntax-highlighting` - Syntax highlighting for commands
  - `zsh-completions` - Additional completions
- **Themes**: `powerlevel10k` theme is installed via Homebrew and symlinked

The install script automatically creates symlinks from brew packages to `~/.oh-my-zsh/custom/plugins/` and `~/.oh-my-zsh/custom/themes/`. These symlinks are created after brew packages are installed.

### Git

- `.gitconfig` - Global git configuration
- `.config/git/allowed_signers` - SSH allowed signers for GPG
- `.config/git/ignore` - Global git ignore patterns

### SSH

- `.ssh/config` - SSH host configurations

**Note**: SSH private keys are NOT included and should be managed separately.

### Terminal

- **Ghostty**: `.config/ghostty/config` - Ghostty terminal configuration

### GitHub CLI

- `.config/gh/config.yml` - GitHub CLI configuration
- `.config/gh/hosts.yml` - GitHub CLI hosts configuration

### VS Code

- `Library/Application Support/Code/User/settings.json` - VS Code user settings (macOS only)

### Local Bin

- `.local/bin/env` - Local bin environment configuration (cross-platform)
- `scripts/sync/sync_dev_to_icloud.sh` - Script to sync `~/dev` to iCloud Drive using rsync with hardlinks (**macOS only** - LaunchAgent points directly to it)

### Claude IDE

- `.claude/settings.json` - Claude IDE settings
- `.claude/statusline.sh` - Claude IDE statusline script

### Codex

- `.codex/config.toml` - Codex configuration

### OpenCode

- `.config/opencode/config.json` - OpenCode configuration

### Shell Configuration

- `.profile` - Shared shell profile (sourced by both bash and zsh)
- `.telemetry.sh` - Telemetry and analytics disable settings (sourced by `.profile`)
- `.models.sh` - AI/ML model directory configurations (sourced by `.profile`)
- `.caches.sh` - Package manager and tool cache directory configurations (sourced by `.profile`)
- `.shell-functions` - Shell utility functions

The telemetry file contains environment variables to disable telemetry for various tools (Gatsby, Homebrew, Steam, etc.). All shell configuration files are automatically sourced by `.profile` for both bash and zsh.

### Homebrew

- `stow/brew/Brewfile` - List of Homebrew packages to install

The Brewfile includes oh-my-zsh plugins and themes:

- `powerlevel10k` - Zsh theme
- `zsh-autosuggestions` - Zsh plugin
- `zsh-syntax-highlighting` - Zsh plugin
- `zsh-completions` - Zsh plugin

To update the Brewfile:

   ```bash
   cd ~/dotfiles/stow/brew
   brew bundle dump --force
   ```

## iCloud Drive Sync (macOS Only)

This repository includes an automated sync solution that syncs your `~/dev` directory to iCloud Drive using hardlinks. This allows files to exist in both locations while sharing disk space.

### Features

- **Automatic Sync**: Syncs every 5 minutes via macOS LaunchAgent
- **Hardlinks**: Uses `rsync --link-dest` to create hardlinks, saving disk space
- **Bidirectional**: Files exist in both `~/dev` and iCloud Drive
- **Persistent**: Automatically starts on login and runs in the background

### Components

1. **Sync Script**: `~/dotfiles/scripts/sync/sync_dev_to_icloud.sh`
   - Located in the `scripts/sync/` directory (outside of stow)
   - Uses `rsync` with `--link-dest` to create hardlinks
   - Syncs from `~/dev` to `~/Library/Mobile Documents/com~apple~CloudDocs/dev`
   - Handles new files, deletions, moves, and renames

2. **LaunchAgent**: `~/Library/LaunchAgents/com.user.devtosync.plist`
   - Points directly to the script in the dotfiles repository
   - Runs sync script every 5 minutes (300 seconds)
   - Runs immediately on login (`RunAtLoad: true`)
   - Logs to `~/dotfiles/scripts/sync/logs/devtosync.log`

### Installation

The LaunchAgent is automatically installed when you run `./install.sh` on macOS. It will **not** be installed on Linux systems.

### Manual Setup (if needed)

If you need to manually load the LaunchAgent:

```bash
launchctl load ~/Library/LaunchAgents/com.user.devtosync.plist
```

To unload (stop syncing):

```bash
launchctl unload ~/Library/LaunchAgents/com.user.devtosync.plist
```

### Logs

Sync logs are written to:

- Standard output: `~/dotfiles/scripts/sync/logs/devtosync.log`
- Standard error: `~/dotfiles/scripts/sync/logs/devtosync.error.log`

### Important Notes

- **macOS Only**: This feature requires macOS and iCloud Drive. It will not work on Linux.
- **Hardlinks**: Files are hardlinked, meaning they share the same disk space. Deleting from one location doesn't delete from the other until both links are removed.
- **iCloud Sync Time**: Large files may take time to upload to iCloud. The sync script creates the files locally immediately, but iCloud upload happens asynchronously.
- **Disk Space**: Hardlinks save disk space since files share the same inode. However, iCloud may treat hardlinks as separate files in the cloud.

### Troubleshooting

1. **Check if service is running**:

   ```bash
   launchctl list | grep com.user.devtosync
   ```

2. **View recent sync activity**:

   ```bash
   tail -20 ~/dotfiles/scripts/sync/logs/devtosync.log
   ```

3. **Check for errors**:

   ```bash
   cat ~/dotfiles/scripts/sync/logs/devtosync.error.log
   ```

4. **Manually trigger a sync**:

   ```bash
   ~/dotfiles/scripts/sync/sync_dev_to_icloud.sh
   ```

5. **Verify hardlinks are working**:

   ```bash
   # Check if files share the same inode
   stat -f %i ~/dev/some-file
   stat -f %i ~/Library/Mobile\ Documents/com~apple~CloudDocs/dev/some-file
   # If inode numbers match, hardlinks are working
   ```

## Secrets Management

Sensitive files are encrypted using `git-crypt` with symmetric key encryption. The following files are encrypted:

- `stow/secrets/dot-secrets` - Primary secrets file (API keys, tokens, passwords)
- `stow/ssh/dot-ssh/config` - SSH host configurations
- `stow/git/dot-config/git/allowed_signers` - SSH allowed signers

### Setup

1. **First-time setup:**
   - The install script will automatically install `git-crypt` if needed
   - Copy your git-crypt key file to `~/.config/git-crypt/key`
   - The install script will automatically unlock encrypted files during installation

2. **On new machines:**
   - Clone the repository
   - Copy your git-crypt key file to `~/.config/git-crypt/key`
   - Run the install script - it will automatically unlock encrypted files

3. **Key file backup:**
   - **IMPORTANT:** Backup your git-crypt key file (`~/.config/git-crypt/key`) to a password manager
   - This key file is required to decrypt the encrypted files
   - Store it securely - if lost, you cannot decrypt the files

### Automatic Unlock

Git hooks automatically unlock encrypted files on `git checkout` and `git pull` operations, making encryption/decryption transparent during normal git operations.

**Note:** The git-crypt key file should be stored securely (password manager recommended) and backed up. Never commit the key file to the repository.

## Cross-Platform Compatibility

These dotfiles are designed to work on both **macOS** and **Linux**. The install script detects the OS and handles differences automatically.

### macOS-Specific Notes

- **VS Code settings**: Only installed on macOS (uses `Library/Application Support/Code/User`)
- **1Password SSH signing**: The `.gitconfig` includes a macOS path for 1Password SSH signing (`/Applications/1Password.app/...`). On Linux, you may need to adjust this path or comment it out if using a different SSH signing method.
- **1Password SSH agent**: The `.ssh/config` includes macOS-specific 1Password agent path. On Linux, comment it out or adjust as needed.
- **iCloud Drive Sync**: A LaunchAgent (`com.user.devtosync.plist`) is configured to automatically sync `~/dev` to iCloud Drive every 5 minutes using `rsync` with hardlinks. This feature is **macOS-only** and will not be installed on Linux systems. See [iCloud Drive Sync](#icloud-drive-sync) section for details.

### Linux-Specific Notes

- **VS Code**: On Linux, VS Code settings are typically in `~/.config/Code/User/` (not handled by this repo currently)
- **1Password**: Linux users may need to adjust 1Password paths in `.gitconfig` and `.ssh/config`
- **Package Management**: Linux users install the same packages via their distribution's package manager (apt/yum/dnf/apk). The install script automatically detects and uses the appropriate package manager.
- **oh-my-zsh plugins/themes**: On Linux, these are installed via git clone (same as macOS, just different installation method)
- **Special tools**: Some tools (bun, uv, gh, ast-grep) may need manual installation or use official installers - the script will prompt if needed

### Portable Features

- All shell configs use `$HOME` or `~` instead of hardcoded paths
- OS detection handles stat command differences (`stat -f` on macOS, `stat -c` on Linux)
- Path modifications are conditional and use environment variables
- Homebrew is macOS-only and properly gated by OS checks

## Model Location Configurations

The dotfiles include configurations for model locations (e.g., HuggingFace, Ollama, PyTorch) that point to `~/models`. These are configured in:

- `.local/bin/env` - Environment variables for model paths
- `.lmstudio-home-pointer` - LM Studio home directory pointer (created automatically if LM Studio is installed)

The `.lmstudio-home-pointer` file is only created if LM Studio is detected (via `lms` command or `~/.lmstudio` directory).

## Adding New Configurations

To add a new configuration:

1. Create a new directory in `stow/`:

   ```bash
   mkdir -p ~/dotfiles/stow/newconfig
   ```

2. Copy your config file(s) to the new directory, maintaining the directory structure. **Important**: For dotfiles (files starting with `.`), rename them to use `dot-` prefix in the repository (e.g., `.newconfig` → `dot-newconfig`). The `stow --dotfiles` option will automatically restore the `.` prefix when creating symlinks:

   ```bash
   cp ~/.newconfig ~/dotfiles/stow/newconfig/dot-newconfig
   ```

3. Add the package to `scripts/install/stow-packages.sh` by adding a call to `stow_package`:

   ```bash
   echo "  - New config"
   stow_package newconfig
   ```

4. Commit and push:

   ```bash
   cd ~/dotfiles
   git add stow/newconfig scripts/install/stow-packages.sh
   git commit -m "Add newconfig"
   git push
   ```

**Note**: The `stow_package` function in `scripts/install/stow-packages.sh` handles the `stow --dotfiles` command automatically. For special cases (like VS Code), see the exceptions documented in that script.

## Features and Improvements

### Error Handling and Logging

The scripts include comprehensive error handling and structured logging:

- **Error Reporting**: Functions like `err()`, `die()`, `warn()`, and `info()` provide consistent error messages with context
- **Structured Logging**: Use `--log-file FILE` to enable logging to a file for debugging and audit trails
- **Automatic Cleanup**: Temporary files and directories are automatically tracked and cleaned up on exit
- **Graceful Shutdown**: Scripts handle interrupts (Ctrl+C) and termination signals gracefully

### Performance Optimizations

- **Package Status Caching**: Package installation status is cached using associative arrays, providing 10-100x faster checks for large package lists
- **Efficient File Operations**: Optimized file system operations reduce redundant system calls

### Modern Shell Features

The scripts leverage modern shell features where available:

- **Modular Library Architecture**: Core functionality is split into focused, single-responsibility libraries
- **Associative Arrays**: Used for package status caching (Bash 4+ or zsh typeset -A)
- **Zsh Optimizations**: Automatic detection and use of zsh-specific features for better performance
- **Improved Error Handling**: Comprehensive trap handlers for cleanup and error reporting
- **Cross-Platform Compatibility**: Works on both macOS and Linux with automatic OS detection
- **Bash 3.2 Compatibility**: Fallbacks for older Bash versions (e.g., macOS default)

#### Shell Version Requirements

The codebase is optimized for modern shells while maintaining backward compatibility:

**Bash:**

- **Bash 5.2+**: Full feature support (namerefs, wait -n, BASH_XTRACEFD, mapfile -d)
- **Bash 5.1+**: Most features supported (wait -n, BASH_XTRACEFD)
- **Bash 5.0+**: Enhanced features available
- **Bash 4.4+**: mapfile with null delimiter support
- **Bash 4.3+**: Nameref variable support
- **Bash 4.0+**: Associative arrays, readarray
- **Bash 3.2**: Basic functionality with fallbacks

**Zsh:**

- **Zsh 5.9+**: All features supported
- **Zsh 5.1+**: Parameter expansion flags (:u, :l)
- **Zsh 5.0.8+**: HIST_FCNTL_LOCK for better history locking
- **Zsh 5.0+**: All zsh modules and glob qualifiers

#### Tool Version Requirements

**yq:**

- **yq 4.0+**: Required for `generate-brewfile.sh` script (uses yq v4 syntax)
- The `check-dependencies.sh` script automatically checks and installs/upgrades yq if needed
- yq v3 is not supported due to syntax differences (e.g., `-c` flag removed in v4)

#### Advanced Features

**Bash 5.2+ Features:**

- Nameref variables (`local -n`) for safer array manipulation
- `wait -n` for waiting on any background process
- `BASH_XTRACEFD` for separated debug output
- Enhanced error context with `BASH_LINENO` arrays

**Zsh Features:**

- **Zsh Modules**: Automatically loads `zsh/files`, `zsh/stat`, `zsh/datetime`, `zsh/parameter` for built-in operations
- **Glob Qualifiers**: Uses zsh glob qualifiers (`**/*.sh(.)`) for faster file finding
- **Parameter Expansion**: Advanced parameter expansion flags (`${(s:,:)string}`, `${(j:,:)array}`)
- **Built-in File Operations**: Uses `zf_*` functions and `zstat` for better performance

**Error Handling:**

- RETURN trap support for function-level cleanup
- Enhanced error messages with call stack information
- Debug tracing with `--debug` flag and `BASH_XTRACEFD`
- Better error context using `FUNCNAME`/`funcfiletrace` arrays

**Terminal Integration:**

- OSC 7 support for current directory reporting (Ghostty and other modern terminals)
- OSC 9;4 protocol for progress indicators
- Enhanced Ghostty configuration with modern features

## Troubleshooting

### General Debugging

1. **Use verbose mode** to see detailed output:

   ```bash
   ./install.sh --verbose
   ```

2. **Enable logging** to capture all operations:

   ```bash
   ./install.sh --log-file install.log
   ```

3. **Check implementation status**:

   ```bash
   ./install.sh --check
   ```

4. **Preview changes** before making them:

   ```bash
   ./install.sh --dry-run --verbose
   ```

### Common Issues

#### Scripts can't find libraries

**Error**: `Error: Cannot find loaders/full.sh` (or similar)

**Solution**:

- Ensure you're running scripts from the dotfiles directory
- Check that `scripts/lib/loaders/full.sh` (or `standard.sh`/`minimal.sh`) exists
- Verify `SCRIPTS_DIR` is set correctly in the script

#### Permission errors

**Error**: `Permission denied` when creating files or directories

**Solution**:

- Check file permissions on scripts (should be executable: `chmod +x install.sh`)
- Verify write permissions in target directories (e.g., `~/.config`)
- On Linux, may need `sudo` for system-wide installations (not typically needed for dotfiles)

#### Symlinks not working

**Symptom**: Files aren't being symlinked correctly

**Solution**:

1. Check if files already exist (not symlinks):

   ```bash
   ls -la ~/.zshrc
   ```

2. If file exists and isn't a symlink, backup and remove it:

   ```bash
   mv ~/.zshrc ~/.zshrc.backup
   ```

3. Restow the package:

   ```bash
   cd ~/dotfiles/stow
   stow -t ~ -R <package-name>
   ```

4. Or run the install script again:

   ```bash
   ./install.sh
   ```

#### Conflicts with existing files

**Symptom**: Stow skips files that already exist

**Solution**:

- **Option 1**: Backup and remove existing files manually
- **Option 2**: Use `--sync-local` to merge local changes into the repo:

  ```bash
  ./install.sh --sync-local --merge
  ```

- **Option 3**: Use `stow --override` (be careful - this will overwrite!):

  ```bash
  cd ~/dotfiles/stow
  stow -t ~ --override <package-name>
  ```

#### VS Code settings not updating

**Symptom**: VS Code settings changes aren't reflected

**Solution**:

1. Verify the stow package is correctly set up:

   ```bash
   ls -la ~/Library/Application\ Support/Code/User/settings.json
   ```

2. Check if it's a symlink pointing to the repo:

   ```bash
   readlink ~/Library/Application\ Support/Code/User/settings.json
   ```

3. If not a symlink, remove and restow:

   ```bash
   cd ~/dotfiles/stow/vscode
   stow -t ~/Library/Application\ Support/Code/User .
   ```

#### oh-my-zsh plugins/themes not working

**Symptom**: Plugins or themes aren't loading in zsh

**Solution**:

1. Verify brew packages are installed (macOS):

   ```bash
   brew bundle --file=~/dotfiles/stow/brew/Brewfile
   ```

2. Check symlinks exist:

   ```bash
   ls -la ~/.oh-my-zsh/custom/plugins/
   ls -la ~/.oh-my-zsh/custom/themes/
   ```

3. Verify plugins are enabled in `.zshrc`:

   ```bash
   grep "plugins=" ~/.zshrc
   ```

4. On Linux, verify plugins/themes were installed via git:

   ```bash
   ls -la ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
   ```

5. Restart your terminal or reload zsh:

   ```bash
   source ~/.zshrc
   ```

#### Package installation failures

**Symptom**: Packages fail to install via Homebrew or package manager

**Solution**:

1. Check if package manager is working:

   ```bash
   brew doctor  # macOS
   sudo apt-get update  # Linux
   ```

2. Review verbose output:

   ```bash
   ./install.sh --verbose
   ```

3. Check log file if logging was enabled:

   ```bash
   cat install.log
   ```

4. Install packages manually if needed:

   ```bash
   brew install <package-name>  # macOS
   sudo apt-get install <package-name>  # Linux
   ```

#### Sync-local merge conflicts

**Symptom**: Merge mode creates conflict markers in files

**Solution**:

1. Review the conflicted files:

   ```bash
   git status
   git diff
   ```

2. Manually resolve conflicts using your editor
3. Remove conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
4. Test the merged configuration
5. Commit the resolved files:

   ```bash
   git add .
   git commit -m "Resolve merge conflicts"
   ```

#### Temporary file cleanup issues

**Symptom**: Temporary files aren't being cleaned up

**Solution**:

- Temporary files are automatically cleaned up on script exit
- If script is interrupted (Ctrl+C), cleanup should still run via trap handlers
- Manual cleanup if needed:

  ```bash
  rm -rf /tmp/dotfiles.*
  ```

### Getting Help

1. **Check the logs**: If you used `--log-file`, review the log file for detailed error messages
2. **Run with verbose mode**: `./install.sh --verbose` shows detailed output
3. **Check implementation status**: `./install.sh --check` verifies current state
4. **Review architecture docs**: See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system design details

## License

Personal dotfiles - use at your own risk.
