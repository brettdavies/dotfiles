# Dotfiles

Personal dotfiles managed with GNU Stow for syncing across macOS and Linux machines.

## Structure

This repository uses [GNU Stow](https://www.gnu.org/software/stow/) to manage symlinks for configuration files. Each directory in `stow/` contains files that will be symlinked to your home directory.

The installation process is modular, with `install.sh` orchestrating several single-purpose scripts in the `scripts/` directory:

**Shared Libraries** (modular function libraries):

- `lib-core.sh` - Core functions (OS detection, colors, argument parsing, verbose output)
- `lib-file.sh` - File operations and permissions
- `lib-packages.sh` - Package checking (Homebrew, VS Code, Cursor)
- `lib-stow.sh` - Stow-specific operations and symlink checking
- `lib-sync.sh` - Sync operations for bidirectional updates

**Installation Scripts**:

- `check-dependencies.sh` - Installs required dependencies
- `stow-packages.sh` - Creates symlinks using `stow --dotfiles`
- `create-secrets.sh` - Creates `.secrets` file
- `create-lmstudio-pointer.sh` - Creates LM Studio pointer file
- `install-packages.sh` - Installs packages from Brewfile

**Verification Scripts**:

- `check-implementation.sh` - Verifies dotfiles are fully implemented
- `test-in-docker.sh` - Tests installation in Docker containers

**Dotfile Convention**: Files in the repository use `dot-` prefix (e.g., `dot-bashrc`) to keep them visible in file managers. The `stow --dotfiles` option automatically converts these to `.` prefixed symlinks (e.g., `.bashrc`) in your home directory.

```plaintext
stow/
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
├── telemetry/    # Telemetry settings (.telemetry.sh)
└── brew/         # Brewfile for Homebrew packages
```

## Initial Setup

### Prerequisites

- Git
- GNU Stow (will be installed automatically if missing)
- Homebrew (macOS only - for package installation)
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

The script orchestrates several modular scripts in the `scripts/` directory:

- **check-dependencies.sh**: Installs GNU Stow, shells (zsh/bash), and oh-my-zsh if missing
- **stow-packages.sh**: Creates symlinks for all configuration files using `stow --dotfiles`
- **create-secrets.sh**: Creates an empty `.secrets` file with proper permissions (600)
- **create-lmstudio-pointer.sh**: Creates `.lmstudio-home-pointer` if LM Studio is installed (optional)
- **install-packages.sh**: Optionally installs packages from Brewfile (macOS: via Homebrew, Linux: via package manager) and sets up oh-my-zsh plugins/themes

**Note**: The installer uses `stow --dotfiles` which automatically converts `dot-*` prefixed files in the repository to `.*` prefixed symlinks in your home directory. This keeps files visible in the repository while creating proper hidden dotfiles.

### Verifying Installation

After installation, you can verify that everything is set up correctly:

   ```bash
   ./install.sh --check
   ```

Or run the verification script directly:

   ```bash
   ./scripts/check-implementation.sh
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
   stow -t ~ zsh bash git ssh ghostty gh oh-my-zsh
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
   stow -t ~ -R zsh bash git ssh ghostty gh oh-my-zsh
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

- `.local/bin/env` - Local bin environment configuration

### Claude IDE

- `.claude/settings.json` - Claude IDE settings
- `.claude/statusline.sh` - Claude IDE statusline script

### Codex

- `.codex/config.toml` - Codex configuration

### OpenCode

- `.config/opencode/config.json` - OpenCode configuration

### Telemetry

- `.telemetry.sh` - Telemetry and analytics disable settings (sourced by `.profile`)

This file contains environment variables to disable telemetry for various tools (Gatsby, Homebrew, Steam, etc.). It's automatically sourced by `.profile` for both bash and zsh.

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

## Secrets Management

The `.secrets` file is created empty with 600 permissions. This file is **not** tracked in git (see `.gitignore`).

**Important**: Never commit secrets to this repository. The `.secrets` file should be managed separately on each machine.

## Cross-Platform Compatibility

These dotfiles are designed to work on both **macOS** and **Linux**. The install script detects the OS and handles differences automatically.

### macOS-Specific Notes

- **VS Code settings**: Only installed on macOS (uses `Library/Application Support/Code/User`)
- **1Password SSH signing**: The `.gitconfig` includes a macOS path for 1Password SSH signing (`/Applications/1Password.app/...`). On Linux, you may need to adjust this path or comment it out if using a different SSH signing method.
- **1Password SSH agent**: The `.ssh/config` includes macOS-specific 1Password agent path. On Linux, comment it out or adjust as needed.

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

3. Add the package to `scripts/stow-packages.sh` by adding a call to `stow_package`:

   ```bash
   echo "  - New config"
   stow_package newconfig
   ```

4. Commit and push:

   ```bash
   cd ~/dotfiles
   git add stow/newconfig scripts/stow-packages.sh
   git commit -m "Add newconfig"
   git push
   ```

**Note**: The `stow_package` function in `scripts/stow-packages.sh` handles the `stow --dotfiles` command automatically. For special cases (like VS Code), see the exceptions documented in that script.

## Troubleshooting

### Symlinks not working

If symlinks aren't created correctly, you can restow:

```bash
cd ~/dotfiles/stow
stow -t ~ -R <package-name>
```

### Conflicts with existing files

If a file already exists and isn't a symlink, stow will skip it. You can either:

- Backup and remove the existing file
- Use `stow --override` to force (be careful!)

### VS Code settings not updating

Make sure you're stowing from the correct directory:

```bash
cd ~/dotfiles/stow/vscode
stow -t ~/Library/Application\ Support/Code/User .
```

### oh-my-zsh plugins/themes not working

If plugins or themes aren't loading:

1. Make sure brew packages are installed:

   ```bash
   brew bundle --file=~/dotfiles/stow/brew/Brewfile
   ```

2. Verify symlinks exist:

   ```bash
   ls -la ~/.oh-my-zsh/custom/plugins/
   ls -la ~/.oh-my-zsh/custom/themes/
   ```

3. Check that plugins are enabled in `.zshrc`:

   ```bash
   grep "plugins=" ~/.zshrc
   ```

4. Restart your terminal or run `source ~/.zshrc`

## License

Personal dotfiles - use at your own risk.
