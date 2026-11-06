#!/usr/bin/env bash

# Everything below reports the host, and a tool started in a tree nobody has reviewed loads config from it: qmd runs under
# Bun, which runs the preload a bunfig.toml in its working directory names.
cd / || exit 0

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude"
INVENTORY="$CACHE_DIR/tool-inventory.cache"
CACHE_TTL=3600 # 1 hour

# Bare names on one line, because hook output rides on every API call of the session. Dependency formulas and the bunx
# cache stay out: neither says what an agent can reach for, and `bunx` runs any package anyway.
tool_inventory() {
  {
    brew leaves --installed-on-request 2>/dev/null | sed 's|.*/||'
    pipx list --short 2>/dev/null | cut -d' ' -f1
    uv tool list 2>/dev/null | sed -n 's/^- //p'
    # Rust toolchain binaries are not user-installed CLI tools
    {
      [ -d ~/.cargo/bin ] && ls ~/.cargo/bin 2>/dev/null
    } | rg -v '^(cargo|rustc|rustup|rustdoc|rustfmt|rust-gdb|rust-lldb|rust-analyzer|clippy-driver|cargo-clippy|cargo-fmt|cargo-miri|rls|rust-gdbgui)$'
  } | sort -u | paste -sd' ' -
}

# `brew leaves` takes about 0.8s
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

refresh_inventory
echo "Installed CLI tools: $(cat "$INVENTORY" 2>/dev/null)"
echo ''

echo '--- qmd collections ---'
if command -v qmd >/dev/null 2>&1; then
  qmd collection list 2>/dev/null || echo '(qmd: no collections configured)'
else
  echo '(qmd not installed)'
fi
