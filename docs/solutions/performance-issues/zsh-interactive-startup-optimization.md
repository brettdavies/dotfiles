---
title: "Interactive zsh startup optimization: 440ms to 190ms"
category: performance-issues
tags:
  - zsh
  - shell-startup
  - compinit
  - npm
  - homebrew
  - oh-my-zsh
  - cross-platform
module: shell/zsh
symptom: "Interactive zsh shell takes ~440ms to start; noticeable delay when opening new terminal tabs"
root_cause: "Three independent slowdowns: `npm config set cache` subprocess (105ms), double compinit with uncompiled dump (170ms), `brew --prefix` subprocesses (32ms)"
date: 2026-03-11
severity: medium
---

# Interactive zsh Startup Optimization: 440ms to 190ms

## Problem

Interactive zsh startup took ~440ms — noticeable as a lag when opening new terminal
tabs. Non-interactive startup (SSH commands, cron) was fast (~16ms), indicating the
cost was in interactive-only config (`.zshrc` and oh-my-zsh).

## Profiling Methodology

Used `zsh/datetime` module with `$EPOCHREALTIME` to measure each component:

```zsh
zmodload zsh/datetime
_start=$EPOCHREALTIME
# ... component under test ...
printf "%6.0fms  component\n" $(( ($EPOCHREALTIME - _start) * 1000 ))
```

Wall-clock measurements with `/usr/bin/time` for end-to-end validation.
Performance budget tests use `perl -MTime::HiRes` for millisecond precision
from bats (which runs under bash, not zsh).

## Root Causes and Fixes

### 1. `npm config set cache` in caches.sh (~105ms)

**Root cause:** `config/shell/caches.sh` called
`npm config set cache "$XDG_CACHE_HOME/npm"` on every shell startup. This spawns
the `npm` process which reads and writes `~/.npmrc` — a ~105ms operation.

**Fix:** Replace with `NPM_CONFIG_CACHE` environment variable, which npm respects natively with zero I/O:

```bash
# Before (105ms per shell start)
if command -v npm &> /dev/null; then
    npm config set cache "$XDG_CACHE_HOME/npm" 2>/dev/null || true
fi

# After (0ms)
export NPM_CONFIG_CACHE="$XDG_CACHE_HOME/npm"
```

**Belt-and-suspenders:** `~/.npmrc` still has `cache=/Users/brett/.cache/npm` from
prior `npm config set` calls. Both sources agree on the same directory.

### 2. Double compinit with uncompiled dump (~170ms)

**Root cause:** Two independent `compinit` calls happened during startup:

1. **oh-my-zsh** called `compinit -i -d ~/.zcompdump-hostname-version` (~170ms)
2. **`.zshrc`** called `compinit -C -d ~/.zsh/cache/zcompdump` (~170ms)

Additionally, oh-my-zsh's compiled `.zwc` dump was stale because a
**stale lock directory** (`~/.zcompdump-*.lock`, dated March 3) prevented
`zrecompile` from running. Oh-my-zsh uses `mkdir` as a lock — if the lock
dir exists, it silently skips recompilation. The `.zwc` was 8 days stale,
so zsh fell back to parsing the 2,040-line text dump (~170ms) instead of
loading the compiled version (~2ms).

**Fix — unified compinit:**

```zsh
# Set ZSH_COMPDUMP BEFORE sourcing oh-my-zsh, so it uses our cache path.
# This eliminates the need for a second compinit call.
export ZSH_COMPDUMP=~/.zsh/cache/zcompdump

# Move fpath additions BEFORE oh-my-zsh so its single compinit sees them.
if [[ -n "${HOMEBREW_PREFIX:-}" && -d "$HOMEBREW_PREFIX/share/zsh-completions" ]]; then
    fpath=("$HOMEBREW_PREFIX/share/zsh-completions" $fpath)
fi
fpath=($HOME/.docker/completions $fpath)

source $ZSH/oh-my-zsh.sh

# Safety net: compile the dump if oh-my-zsh's lock-dir pattern failed.
if [[ -s "$ZSH_COMPDUMP" && ( ! -s "${ZSH_COMPDUMP}.zwc" || "$ZSH_COMPDUMP" -nt "${ZSH_COMPDUMP}.zwc" ) ]]; then
    zcompile "$ZSH_COMPDUMP" 2>/dev/null
fi
```

This removed a 50-line block that had 4 near-identical branches (macOS/Linux x zstat/stat) for the duplicate compinit.

**One-time cleanup:** `rmdir ~/.zcompdump*.lock` to remove the stale lock.

### 3. `brew --prefix` subprocesses (~32ms)

**Root cause:** Two calls to `brew --prefix` in `.zshrc` (~16ms each):

- `FPATH=$(brew --prefix)/share/zsh-completions:$FPATH`
- `BREW_PREFIX=$(brew --prefix)` for libpq PATH

**Fix:** Use `$HOMEBREW_PREFIX` which is already set by `brew shellenv` in `.profile`:

```zsh
# Before (~16ms per call)
if [[ "$OSTYPE" == "darwin"* ]] && type brew &>/dev/null; then
    FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
fi

# After (0ms — env var already set)
if [[ -n "${HOMEBREW_PREFIX:-}" && -d "$HOMEBREW_PREFIX/share/zsh-completions" ]]; then
    fpath=("$HOMEBREW_PREFIX/share/zsh-completions" $fpath)
fi
```

## Results

| Environment | Before | After | Reduction |
|-------------|--------|-------|-----------|
| Interactive zsh | ~440ms | ~190ms | 57% |
| Interactive bash | ~18ms | ~18ms | — |
| Non-interactive zsh | ~16ms | ~16ms | — |
| Non-interactive bash | ~8ms | ~8ms | — |

### Remaining cost breakdown (~190ms interactive zsh)

| Component | Time | Notes |
|-----------|------|-------|
| oh-my-zsh (single compinit, compiled) | ~120ms | Structural — compinit + plugins + theme |
| autojump | ~34ms | Plugin |
| zsh-syntax-highlighting | ~8ms | Plugin |
| Everything else | ~28ms | Shell options, aliases, hooks |

## Key Insights

### compinit compiled vs uncompiled

| Dump state | Load time | Notes |
|------------|-----------|-------|
| Compiled `.zwc` present and current | ~2ms | Fast binary load |
| Compiled `.zwc` stale (older than text dump) | ~170ms | zsh falls back to text parsing |
| No `.zwc` at all | ~170ms | Always parses text |
| `compinit -C` (skip security check) | Same as above | `-C` only skips `compaudit`, not parsing |

**Lesson:** `compinit -C` is commonly recommended as "fast compinit" but it
only skips the security audit. The real speedup comes from having a
**compiled `.zwc` file** that is newer than the text dump.

### oh-my-zsh stale lock pattern

oh-my-zsh uses `mkdir "$ZSH_COMPDUMP.lock"` as a lock (atomic on all
filesystems). If zsh crashes or is killed during recompilation, the lock
dir is never cleaned up. It silently blocks all future recompilations.
The safety-net `zcompile` in `.zshrc` catches this case.

### fpath ordering matters for single compinit

If completion directories (Docker, Homebrew zsh-completions) are added to
`fpath` **after** `compinit` runs, those completions won't be registered.
Either:

- Add to `fpath` before `source oh-my-zsh.sh` (preferred — single compinit)
- Call `compinit` again after fpath changes (wasteful — double compinit)

### Environment variables vs subprocess calls

| Pattern | Time | Use when |
|---------|------|----------|
| `brew --prefix` | ~16ms | Never in shell startup — use `$HOMEBREW_PREFIX` |
| `npm config set` | ~105ms | Never in shell startup — use `NPM_CONFIG_CACHE` |
| `$HOMEBREW_PREFIX` | 0ms | Already set by `brew shellenv` in `.profile` |
| `$NPM_CONFIG_CACHE` | 0ms | npm respects this natively |

**Rule:** Never spawn a subprocess in shell startup for a value that's already available as an environment variable.

## Prevention

### Performance budget tests (enforced in CI)

```bash
@test "interactive zsh starts under 500ms" {
  ms=$(_measure_ms "zsh -i -c exit")
  echo "# interactive zsh: ${ms}ms" >&3
  [ "$ms" -lt 500 ]
}
```

Four tests cover all combinations (interactive/non-interactive x bash/zsh) with budgets:

- Non-interactive: < 200ms
- Interactive: < 500ms

These run in both bash and zsh via `bats tests/shell-config.bats`.

### Before adding to shell startup

1. **Measure first:** Time the command with `zsh/datetime` before adding to `.profile` or `.zshrc`
2. **Prefer env vars** over subprocess calls for configuration
3. **Check if the value already exists** — `brew shellenv` sets many useful variables
4. **Run compinit once** — set `ZSH_COMPDUMP` and configure `fpath` before oh-my-zsh

## Related

- `docs/solutions/performance-issues/shell-startup-secrets-loading-optimization.md` — earlier optimization of secrets loading
- `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` — zsh startup file hierarchy
- `config/shell/caches.sh` — centralized cache directory configuration
- `stow/zsh/dot-zshrc` — interactive zsh configuration
- `tests/shell-config.bats` — startup performance budget tests
