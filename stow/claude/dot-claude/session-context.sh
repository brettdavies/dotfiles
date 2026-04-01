#!/usr/bin/env bash

# Sources caches.sh to get XDG-aware paths for CARGO_HOME, BUN_INSTALL, etc.
# shellcheck source=/dev/null
[ -f ~/dotfiles/stow/shell/caches.sh ] && source ~/dotfiles/stow/shell/caches.sh

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude"
CACHE_TTL=3600  # 1 hour

# `brew list --formula` takes 1-3s; other tools (pipx, uv, cargo, bun) are fast enough live
cached() {
    local name="$1"
    local cache_file="$CACHE_DIR/$name.cache"
    shift
    if [ -f "$cache_file" ]; then
        local age now mtime
        now=$(date +%s)
        mtime=$(stat -f %m "$cache_file" 2>/dev/null) || mtime=$(stat -c %Y "$cache_file" 2>/dev/null) || mtime=0
        age=$((now - mtime))
        if [ "$age" -lt "$CACHE_TTL" ]; then
            cat "$cache_file"
            return
        fi
    fi
    mkdir -p "$CACHE_DIR"
    "$@" > "$cache_file" 2>/dev/null
    cat "$cache_file"
}

# One-per-line output wastes context window tokens; CSV is compact
to_csv() {
    local out
    out=$(paste -sd, - | sed 's/,/, /g')
    if [ -n "$out" ]; then
        echo "$out"
    else
        echo '(none)'
    fi
}

echo '=== Session Context ==='
echo "Current datetime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ''

echo '--- Homebrew CLI tools ---'
cached brew-list brew list --formula | to_csv

echo ''
echo '--- Python CLI tools (pipx) ---'
pipx list --short 2>/dev/null | to_csv

echo ''
echo '--- Python CLI tools (uv) ---'
uv tool list 2>/dev/null | to_csv

echo ''
echo '--- Rust CLI tools (cargo) ---'
{
  # Guard: empty CARGO_HOME would cause `ls "/bin"` to search the wrong path
  [ -n "$CARGO_HOME" ] && ls "$CARGO_HOME/bin" 2>/dev/null
  [ -d ~/.cargo/bin ] && ls ~/.cargo/bin 2>/dev/null
  # Exclude Rust toolchain binaries — they're not user-installed CLI tools
} | rg -v '^(cargo|rustc|rustup|rustdoc|rustfmt|rust-gdb|rust-lldb|rust-analyzer|clippy-driver|cargo-clippy|cargo-fmt|cargo-miri|rls|rust-gdbgui)$' | sort -u | to_csv

echo ''
echo '--- Bun cached CLI tools (bunx) ---'
{
  # Guard: empty BUN_INSTALL would cause `find "/install/cache"` to search the wrong path
  # caches.sh migrates to XDG but old ~/.bun caches may still exist, so check both
  [ -n "$BUN_INSTALL" ] && find "$BUN_INSTALL/install/cache" -path "*/bin/*" -type f 2>/dev/null | sed 's|.*/cache/||' | sed 's|@[0-9].*||'
  [ -d ~/.bun/install/cache ] && find ~/.bun/install/cache -path "*/bin/*" -type f 2>/dev/null | sed 's|.*/cache/||' | sed 's|@[0-9].*||'
  npm_cache="${XDG_CACHE_HOME:-$HOME/.cache}/npm"
  for pkg in "$npm_cache"/*@*@@@1; do
    [ -f "$pkg/package.json" ] && jq -e '.bin' "$pkg/package.json" >/dev/null 2>&1 && basename "$pkg" | sed 's/@[0-9].*$//'
  done
} | sort -u | to_csv

echo ''
echo '--- qmd collections ---'
if command -v qmd >/dev/null 2>&1; then
  qmd collection list 2>/dev/null || echo '(qmd: no collections configured)'
else
  echo '(qmd not installed)'
fi
