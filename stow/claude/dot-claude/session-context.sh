#!/usr/bin/env bash

# Everything below reports the host, and a tool started in a tree nobody has reviewed loads config from it: qmd runs under
# Bun, which runs the preload a bunfig.toml in its working directory names.
cd / || exit 0

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude"
INVENTORY="$CACHE_DIR/tool-inventory.cache"
CACHE_TTL=3600 # 1 hour

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

tool_inventory() {
  echo '--- Homebrew CLI tools ---'
  brew list --formula 2>/dev/null | to_csv

  echo ''
  echo '--- Python CLI tools (pipx) ---'
  pipx list --short 2>/dev/null | to_csv

  echo ''
  echo '--- Python CLI tools (uv) ---'
  uv tool list 2>/dev/null | to_csv

  echo ''
  echo '--- Rust CLI tools (cargo) ---'
  {
    [ -d ~/.cargo/bin ] && ls ~/.cargo/bin 2>/dev/null
    # Exclude Rust toolchain binaries — they're not user-installed CLI tools
  } | rg -v '^(cargo|rustc|rustup|rustdoc|rustfmt|rust-gdb|rust-lldb|rust-analyzer|clippy-driver|cargo-clippy|cargo-fmt|cargo-miri|rls|rust-gdbgui)$' | sort -u | to_csv

  echo ''
  echo '--- Bun cached CLI tools (bunx) ---'
  {
    [ -d ~/.bun/install/cache ] && find ~/.bun/install/cache -path "*/bin/*" -type f 2>/dev/null | sed 's|.*/cache/||' | sed 's|@[0-9].*||'
    npm_cache="${XDG_CACHE_HOME:-$HOME/.cache}/npm"
    for pkg in "$npm_cache"/*@*@@@1; do
      [ -f "$pkg/package.json" ] && jq -e '.bin' "$pkg/package.json" >/dev/null 2>&1 && basename "$pkg" | sed 's/@[0-9].*$//'
    done
  } | sort -u | to_csv
}

# `brew list --formula` takes 1-3s
refresh_inventory() {
  if [ -f "$INVENTORY" ]; then
    local now mtime
    now=$(date +%s)
    # GNU first. On GNU coreutils `stat -f` means --file-system, so `%m` is read
    # as a filename operand: it fails, but the file's filesystem report still
    # goes to stdout. Separate assignments save this one, since the second
    # overwrites the blob, but the order removes a wasted call and the trap.
    mtime=$(stat -c %Y "$INVENTORY" 2>/dev/null) || mtime=$(stat -f %m "$INVENTORY" 2>/dev/null) || mtime=0
    [ $((now - mtime)) -lt "$CACHE_TTL" ] && return
  fi
  mkdir -p "$CACHE_DIR"
  tool_inventory >"$INVENTORY.$$" 2>/dev/null
  mv -f "$INVENTORY.$$" "$INVENTORY"
}

echo '=== Session Context ==='
echo "Current datetime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ''

# Hook output rides on every API call of the session, and the listing is about 2k tokens, so only its path goes out
refresh_inventory
echo "Installed CLI tools (brew, pipx, uv, cargo, bunx): $INVENTORY"
echo ''

echo '--- qmd collections ---'
if command -v qmd >/dev/null 2>&1; then
  qmd collection list 2>/dev/null || echo '(qmd: no collections configured)'
else
  echo '(qmd not installed)'
fi
