# Dotfiles Project Instructions

## Library System

The library lives in `scripts/lib/` and is organized into 4 dependency layers:

```
Layer 0: core/         No dependencies (constants, OS/shell detection)
Layer 1: util/         Depends on core/ (output, paths, args, timestamp)
Layer 2: feature/      Depends on core/, util/ (traps, temp, logging, verbose, progress, validation, rollback)
         fs/           Depends on core/, util/ (file-ops, find, zsh-globs)
         shell/        Depends on core/ (arrays, strings, zsh-modules)
Layer 3: pkg/          Depends on core/, util/, feature/ (brew, cache, extensions, version, version-constraints)
         domain/       Depends on core/, util/, feature/ (stow, sync, sync-backup, sync-merge)
```

**Guard pattern** — every library file must use a re-sourcing guard:

```bash
if [ -n "${LIB_<NAME>_LOADED:-}" ]; then
    return 0
fi
export LIB_<NAME>_LOADED=1
```

**Loaders** — scripts source a single loader, not individual libraries:

| Loader | Use case | Includes |
|--------|----------|----------|
| `loaders/minimal.sh` | Simple scripts | Core + output + args |
| `loaders/standard.sh` | Most install scripts | Minimal + paths, traps, temp, logging, verbose, progress |
| `loaders/full.sh` | Complex scripts | Standard + shell compat, filesystem, packages, domain |

Always choose the smallest sufficient loader. Never source individual library files directly from scripts — only loaders.

---

## Script Pattern

Every script in `scripts/` follows this template:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve SCRIPTS_DIR relative to this script's location
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS_DIR/lib/loaders/standard.sh"

# Parse common arguments (--dry-run, --verbose, --log-file, etc.)
parse_common_args "$@"

# Initialize temp directory (cleaned up automatically by trap)
init_temp_dir "script-name.XXXXXX" >/dev/null
setup_traps cleanup_temp_dir

# --- Script logic here ---
```

Key points:

- `SCRIPTS_DIR` is always resolved relative to the script, never hardcoded.
- `parse_common_args` handles `--dry-run`, `--verbose`, `--sync-local`, `--merge`, `--log-file`, `--no-progress`.
- `init_temp_dir` + `setup_traps` ensures cleanup on exit/error.

---

## Error Handling

Use the output functions from `util/output.sh`. Never use raw `echo` for operational messages.

| Function | Purpose | Behavior |
|----------|---------|----------|
| `die "msg"` | Fatal error | Prints to stderr with call stack, exits script |
| `err "msg"` | Recoverable error | Prints to stderr, returns exit code (use with `\|\| return 1`) |
| `warn "msg"` | Warning | Prints to stderr, continues |
| `info "msg"` | Informational | Prints to stdout |

All output functions include script name and timestamp automatically.

---

## Stow Packages

Packages live in `stow/<package-name>/`. Files use the `dot-` prefix convention:

- `stow/git/dot-config/git/ignore` becomes `~/.config/git/ignore`
- `stow/zsh/dot-zshrc` becomes `~/.zshrc`

Stow's `--dotfiles` flag converts `dot-` to `.` automatically.

To add a new package:

1. Create `stow/<package-name>/` with `dot-` prefixed files
2. The package is auto-discovered by `scripts/install/stow-packages.sh`

---

## Shell Config Chain

`.profile` is symlinked to `stow/shell/dot-profile` and sets `DOTFILES_SHELL_DIR` pointing to the stow/shell directory. Helper files are sourced directly from the repo — no symlink needed for individual shell helpers:

```text
~/.profile (symlink) --> stow/shell/dot-profile
  sources: config/shell/*.sh (telemetry, models, caches, python, paths, etc.)
  sources: ~/.secrets (git-crypt encrypted, tokens + API keys)
  sets up: Homebrew, PATH, Cargo, GPG_TTY

~/.zshenv (symlink) --> stow/zsh/dot-zshenv
  sources: ~/.profile (if not already loaded)
  PURPOSE: ensures non-interactive zsh (SSH commands, cron) has environment

~/.bashrc (symlink) --> stow/bash/dot-bashrc
  sources: ~/.profile (if not already loaded)
  INTERACTIVE GUARD: case $- in *i*) ;; *) return;; esac
  sources: $DOTFILES_SHELL_DIR/shell-functions (interactive only)
  sets up: history, completion, prompt, aliases, OSC 7

~/.zshrc (symlink) --> stow/zsh/dot-zshrc
  sources: ~/.profile (redundant with .zshenv, sentinel guard skips)
  INTERACTIVE GUARD: [[ $- == *i* ]] || return
  sources: $DOTFILES_SHELL_DIR/shell-functions (interactive only)
  sets up: oh-my-zsh, history, modules, completions, p10k
```

**Critical:** `.zshenv` is the ONLY file zsh sources for non-interactive invocations. Without it, `ssh host 'command'` with zsh as default shell gets zero environment. See `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` for the full zsh vs bash startup file reference.

---

## Shell Compatibility

**Targets:** Bash 3.2-5.2+, Zsh 5.0+

Feature detection functions from `core/detect-shell.sh`:

- `is_bash`, `is_zsh` — shell type checks
- `is_bash_5_2_plus`, `is_bash_5_1_plus`, `is_bash_5_0_plus`, etc. — version gates
- `has_nameref_support`, `has_wait_n_support`, `has_mapfile_null_delim` — capability checks

Rules:

- Zsh-only features (glob qualifiers, `zf_*` builtins, parameter expansion flags) must be gated behind `is_zsh`.
- Use `has_nameref_support` before using `local -n` / `typeset -n`.
- Default to POSIX-compatible constructs unless a version gate confirms the feature is available.

---

## Testing

Tests use BATS (Bash Automated Testing System) in `scripts/test/bats/`.

**Naming convention:** `test_<layer>_<module>.bats` (e.g., `test_core_constants.bats`, `test_feature_temp.bats`)

**Test helper:** `test_helper.bash` provides common setup/teardown and sources the appropriate loader.

**Run tests:**

```bash
# All tests
./scripts/test/bats/run_tests.sh

# Single test file
bats scripts/test/bats/test_util_output.bats
```

When modifying a library file, run its corresponding test file to verify changes.

---

## Performance

- **Caching:** Use `pkg/cache.sh` for package status lookups. Cache directory listings with `fs/find.sh`.
- **Zsh builtins:** Prefer `zf_mkdir`, `zf_ln`, `zf_rm`, `zf_chmod` and `zstat` over external commands (gated behind `is_zsh` + module load checks).
- **Namerefs:** Prefer `local -n` / `typeset -n` over `eval` for array manipulation (gated behind `has_nameref_support`).
- **Permission constants:** Use `PERM_SECRET_FILE`, `PERM_SECRET_DIR`, `PERM_EXECUTABLE`, `PERM_REGULAR_FILE` from `core/constants.sh` instead of raw octal strings.
- **Benchmarks:** Run `scripts/test/benchmark.sh` to measure performance of different implementations.

---

## Reference

- Full architecture: `docs/ARCHITECTURE.md`
- Performance details: `docs/PERFORMANCE.md`
