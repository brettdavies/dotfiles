---
title: "Cross-platform editor configuration via $EDITOR env var"
category: configuration-fixes
date: 2026-03-18
severity: moderate
tags:
  - yazi
  - editor
  - cross-platform
  - shell-config
  - git
  - stow
  - toml
module: stow/shell, stow/yazi, stow/git, config/git
related_files:
  - stow/shell/dot-profile
  - stow/yazi/dot-config/yazi/yazi.toml
  - stow/yazi/dot-config/yazi/keymap.toml
  - stow/git/dot-gitconfig
  - config/git/local.linux
---

# Cross-platform editor configuration via $EDITOR env var

## Problem

Yazi file manager and git had hardcoded editor references (`micro`) scattered across multiple config files.
macOS needs `code --wait` (VS Code with blocking), headless Linux needs `micro` (terminal editor). Changing
the editor required updating multiple files, and the hardcoded values were wrong on at least one platform.

Additionally, yazi lacked preview plugins -- `glow` was not installed and `ya pkg install` had not been run,
so markdown preview and smart-enter were non-functional.

## Root Cause

Three independent issues:

1. **No centralized `$EDITOR`:** Editor preference was scattered across `config/git/local.linux` and
   `yazi.toml` rather than set once in the shell profile.
2. **No platform-aware selection:** No conditional logic to choose `code --wait` on macOS vs `micro` on
   Linux.
3. **Yazi TOML quoting pitfall:** Single-quoted TOML strings (`'$EDITOR %s'`) pass `$EDITOR` literally to
   the shell, causing exit code 126. Double quotes (`"$EDITOR %s"`) are required for variable expansion.

## Solution

### 1. Platform-aware `$EDITOR` in `.profile`

`stow/shell/dot-profile` -- the single entry point for all shell environments:

```bash
case "$(uname -s)" in
    Darwin)
        if command -v code >/dev/null 2>&1; then
            EDITOR="code --wait"
        elif command -v micro >/dev/null 2>&1; then
            EDITOR=$(command -v micro)
        fi
        ;;
    *)
        if command -v micro >/dev/null 2>&1; then
            EDITOR=$(command -v micro)
        fi
        ;;
esac
if [ -n "${EDITOR:-}" ]; then
    export EDITOR
    export VISUAL=$EDITOR
fi
```

- `command -v` guards prevent errors if a binary is missing
- macOS falls back to `micro` if `code` is not installed
- `VISUAL` is set to match (some tools check `VISUAL` first)

### 2. Git delegates to `$EDITOR`

`stow/git/dot-gitconfig`:

```gitconfig
[core]
 editor = $EDITOR
```

Git passes `core.editor` through `sh -c`, so the shell expands `$EDITOR` at runtime. The literal
`$EDITOR` in the config file is intentional.

### 3. Removed redundant Linux override

`config/git/local.linux` -- removed `[core] editor = micro`. The file now contains only the signing key
override (which genuinely differs per platform):

```gitconfig
[user]
 signingkey = ~/.ssh/brett_ed25519
```

### 4. Yazi opener uses `$EDITOR` with correct quoting

`stow/yazi/dot-config/yazi/yazi.toml`:

```toml
[opener]
edit = [
  { run = "$EDITOR %s", block = true, desc = "$EDITOR", for = "unix" },
]
```

**Critical:** Must use double quotes. Single quotes `'$EDITOR %s'` cause exit 126 because yazi treats
`$EDITOR` as a literal command name.

### 5. Yazi preview plugins (one-time setup)

```bash
brew install glow        # markdown renderer for piper plugin
ya pkg install           # deploys piper, smart-enter, catppuccin-mocha from package.toml
```

## Verification

```bash
# 1. Verify $EDITOR is set
source ~/.profile && echo "EDITOR=$EDITOR"
# macOS: EDITOR=code --wait
# Linux: EDITOR=/path/to/micro

# 2. Verify git editor
git config core.editor     # Shows: $EDITOR (raw, unexpanded -- correct)
git var GIT_EDITOR          # Shows expanded value
git commit --allow-empty    # Editor opens, blocks until closed

# 3. Verify yazi editor
# Open yazi, press `e` on a file -- correct editor should open

# 4. Verify yazi markdown preview
# Navigate to a .md file in yazi -- rendered preview in right pane
```

**Testing caveat:** Claude Code sets `GIT_EDITOR=true` in its environment, which overrides
`core.editor`. Test git editor behavior outside of Claude Code sessions.

## TOML Quoting Gotcha

This is the key lesson for any TOML-configured tool in this repo:

| TOML Syntax | Behavior | Result for `$EDITOR` |
|-------------|----------|---------------------|
| `"$EDITOR %s"` | TOML basic string | `$EDITOR %s` -- variable expands at runtime |
| `'$EDITOR %s'` | TOML literal string | `$EDITOR %s` -- same string value |

Both TOML string types produce the same string (`$` has no special meaning in TOML). The expansion
depends on whether the consuming tool passes the value through a shell. Yazi shell-executes `run`
commands, so `$EDITOR` expands. But exit code 126 was observed with single quotes in practice --
matching yazi's own default syntax (double quotes) resolved it.

**When adding TOML config for any tool:** If a field needs env var expansion, verify in the tool's docs
whether the field is shell-executed or literal. Add a comment noting the quoting requirement.

## Prevention

### Single source of truth via env var

When multiple tools need the same configurable value that varies by platform, define it once in
`.profile` with platform guards. Reference the env var everywhere else.

Common candidates: `$EDITOR`, `$VISUAL`, `$PAGER`, `$MANPAGER`, `$BROWSER`.

**Anti-pattern detector:** Periodically run `rg 'micro|nano|vim|code' stow/` to find hardcoded editor
references in tool configs that should use `$EDITOR`.

### Checklist for new tools with platform-specific behavior

- [ ] Identify platform-varying values
- [ ] Check for existing env vars (`$EDITOR`, `$PAGER`, etc.) before creating new ones
- [ ] Reference env vars in tool config, not hardcoded values
- [ ] Verify config format supports variable expansion (TOML quoting, etc.)
- [ ] Test on both macOS and headless Linux
- [ ] Ensure headless compatibility (no GUI assumptions on Linux)
- [ ] Test non-interactive SSH: `ssh host 'echo $EDITOR'`

## Related Documentation

- [Cross-platform shell idiom and config hardening](../deployment-issues/cross-platform-shell-idiom-and-config-hardening.md)
  -- general cross-platform patterns (needs update: references removed `core.editor` in `local.linux`)
- [Headless Linux git signing and hook guards](../deployment-issues/headless-linux-git-signing-and-hook-guards.md)
  -- signing key override pattern (needs update: `local.linux` code block shows removed editor line)
- [Post-deployment shell config fixes](../deployment-issues/post-deployment-shell-config-fixes.md)
  -- `.profile` sourcing architecture (current, no update needed)
