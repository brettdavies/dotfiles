# uv tool adapter. Parses `uv tool list` output; each tool gets its own venv
# at ~/.local/share/uv/tools/<tool>/ with entry-point shims symlinked into
# ~/.local/bin/. Tools are isolated → reclaim = own (no shared-dep cascade).

[[ -n "${TOOLS_ATIME_UV:-}" ]] && return 0
TOOLS_ATIME_UV=1

_uv_emit_tool() {
  local tool=$1; shift
  local entries=("$@")
  local local_bin="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}"
  local tool_dir="${UV_TOOLS_DIR:-$HOME/.local/share/uv/tools}/$tool"
  local own_kb max=0 e a
  for e in "${entries[@]}"; do
    [[ -e "$local_bin/$e" ]] || continue
    a=$(atime_of "$local_bin/$e") || continue
    [[ -z "$a" ]] && continue
    (( a > max )) && max=$a
  done
  (( max == 0 )) && max=$(atime_of "$tool_dir" 2>/dev/null) || true
  (( max == 0 )) && return
  own_kb=$(size_kb_of_dir "$tool_dir")
  emit_row uv "$max" "$tool" 1 "$own_kb" "$own_kb"
}

uv_rows() {
  command -v uv >/dev/null || return 0
  local tool="" entries=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)\ v ]]; then
      [[ -n "$tool" ]] && _uv_emit_tool "$tool" "${entries[@]}"
      tool="${BASH_REMATCH[1]}"
      entries=()
    elif [[ "$line" =~ ^-\ (.+)$ ]]; then
      entries+=("${BASH_REMATCH[1]}")
    fi
  done < <(uv tool list 2>/dev/null)
  [[ -n "$tool" ]] && _uv_emit_tool "$tool" "${entries[@]}"
}
