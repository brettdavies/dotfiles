# Ephemeral cache adapter. Not "leaves" — these are auto-managed download
# caches whose entire footprint is reclaimable. atime is the newest mtime
# under the cache (proxy for "last warmed"); size_kb == reclaim_kb because
# deleting the cache reclaims everything inside.

[[ -n "${TOOLS_ATIME_CACHES:-}" ]] && return 0
TOOLS_ATIME_CACHES=1

# Each entry: <label>:<path>. Add more managers here as they show up.
_CACHE_TARGETS=(
  "uv-cache:${UV_CACHE_DIR:-$HOME/.cache/uv}"
  "bun-cache:${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
)

caches_rows() {
  local entry label dir mtime size_kb
  for entry in "${_CACHE_TARGETS[@]}"; do
    label=${entry%%:*}
    dir=${entry#*:}
    [[ -d "$dir" ]] || continue
    mtime=$(max_mtime_under "$dir")
    [[ -z "$mtime" || "$mtime" == "0" ]] && mtime=$(mtime_of "$dir")
    [[ -z "$mtime" ]] && continue
    size_kb=$(size_kb_of_dir "$dir")
    emit_row cache "$mtime" "$label" 1 "$size_kb" "$size_kb"
  done
}
