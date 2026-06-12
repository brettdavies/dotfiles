# cargo install adapter. `cargo install --list` enumerates user-installed
# crates with their binary names; binaries land in ~/.cargo/bin/. Cargo has
# no autoremove concept → reclaim = own (sum of binary sizes for the crate).
#
# On this machine `cargo install --list` is empty (rustup-shimmed cargo, no
# user crates) — adapter emits zero rows gracefully.

[[ -n "${TOOLS_ATIME_CARGO:-}" ]] && return 0
TOOLS_ATIME_CARGO=1

_cargo_emit_crate() {
  local crate=$1; shift
  local bins=("$@")
  local bin_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
  local max=0 own_kb=0 b a sz target
  for b in "${bins[@]}"; do
    [[ -e "$bin_dir/$b" ]] || continue
    a=$(atime_of "$bin_dir/$b") || continue
    (( a > max )) && max=$a
    target=$(readlink -f "$bin_dir/$b" 2>/dev/null || printf '%s' "$bin_dir/$b")
    sz=$(du -sk "$target" 2>/dev/null | awk '{print $1}')
    own_kb=$(( own_kb + ${sz:-0} ))
  done
  (( max == 0 )) && return
  emit_row cargo "$max" "$crate" 1 "$own_kb" "$own_kb"
}

cargo_rows() {
  command -v cargo >/dev/null || return 0
  local crate="" bins=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z0-9_-]+)\ v[0-9].*:$ ]]; then
      [[ -n "$crate" ]] && _cargo_emit_crate "$crate" "${bins[@]}"
      crate="${BASH_REMATCH[1]}"
      bins=()
    elif [[ "$line" =~ ^[[:space:]]+([A-Za-z0-9_.-]+)$ ]]; then
      bins+=("${BASH_REMATCH[1]}")
    fi
  done < <(cargo install --list 2>/dev/null)
  [[ -n "$crate" ]] && _cargo_emit_crate "$crate" "${bins[@]}"
}
