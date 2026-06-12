# bun install -g adapter. Resolves the global bin dir via `bun pm bin -g`
# (paths differ by install: ~/.bun/bin on some setups, ~/.cache/bun/bin on
# others). Top-level globals come from `bun pm ls -g`. Each package is
# isolated under its own node_modules subdir → reclaim = own.

[[ -n "${TOOLS_ATIME_BUN:-}" ]] && return 0
TOOLS_ATIME_BUN=1

_bun_pkg_dir() {
  local pkg=$1 bin_dir=$2
  local global_root="${bin_dir%/bin}/install/global/node_modules"
  if [[ -d "$global_root/$pkg" ]]; then
    printf '%s\n' "$global_root/$pkg"
    return
  fi
  # Fallback: walk any symlink from the bin entry
  local target
  target=$(readlink -f "$bin_dir/$pkg" 2>/dev/null) || return
  printf '%s\n' "$(dirname "$target")"
}

bun_rows() {
  command -v bun >/dev/null || return 0
  local bin_dir
  bin_dir=$(bun pm bin -g 2>/dev/null) || return 0
  [[ -d "$bin_dir" ]] || return 0

  local pkg pkg_dir bins max own_kb b a
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    pkg_dir=$(_bun_pkg_dir "$pkg" "$bin_dir")
    [[ -z "$pkg_dir" || ! -d "$pkg_dir" ]] && continue
    # Bins for this package: any entry under bin_dir whose target resolves
    # into the package dir.
    bins=()
    shopt -s nullglob
    for b in "$bin_dir"/*; do
      [[ -L "$b" ]] || continue
      local t
      t=$(readlink -f "$b" 2>/dev/null) || continue
      [[ "$t" == "$pkg_dir"/* ]] && bins+=("$b")
    done
    shopt -u nullglob
    max=0
    for b in "${bins[@]}"; do
      a=$(atime_of "$b") || continue
      (( a > max )) && max=$a
    done
    (( max == 0 )) && max=$(mtime_of "$pkg_dir")
    own_kb=$(size_kb_of_dir "$pkg_dir")
    emit_row bun "$max" "$pkg" 1 "$own_kb" "$own_kb"
  done < <(bun pm ls -g 2>/dev/null \
    | LC_ALL=C grep -oE '[A-Za-z@][A-Za-z0-9_./@-]+@[0-9][0-9.A-Za-z+-]*' \
    | sed 's/@[^@]*$//' \
    | sort -u)
}
