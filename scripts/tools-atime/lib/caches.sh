# Ephemeral cache adapter. Not "leaves" — these are auto-managed download
# caches whose entire footprint is reclaimable. atime is the newest mtime
# under the cache (proxy for "last warmed"); size_kb == reclaim_kb because
# deleting the cache reclaims everything inside.
#
# Size comes from the manager's own subcommand when available — falls back
# to du only if the manager isn't installed or doesn't expose a size cmd.

[[ -n "${TOOLS_ATIME_CACHES:-}" ]] && return 0
TOOLS_ATIME_CACHES=1

# `uv cache size` returns bytes on stdout, emits an experimental warning on
# stderr unless --preview-features is passed. Convert bytes → KB.
_uv_cache_size_kb() {
  command -v uv >/dev/null || return 1
  local bytes
  bytes=$(uv cache size --preview-features cache-size 2>/dev/null) || return 1
  [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]] && return 1
  printf '%d\n' $(( bytes / 1024 ))
}

# uv cache dir is canonical; ask uv where it lives instead of guessing.
_uv_cache_dir() {
  command -v uv >/dev/null || return 1
  uv cache dir 2>/dev/null
}

# Each entry: <label>:<path>. bun has no clean "global cache size" subcommand
# (`bun pm cache` requires a package.json context) — du stands in there.
caches_rows() {
  local dir mtime size_kb

  # uv-cache via uv's own subcommands.
  if dir=$(_uv_cache_dir) && [[ -d "$dir" ]]; then
    mtime=$(max_mtime_under "$dir")
    [[ -z "$mtime" || "$mtime" == "0" ]] && mtime=$(mtime_of "$dir")
    if size_kb=$(_uv_cache_size_kb); then
      [[ -n "$mtime" ]] && emit_row cache "$mtime" uv-cache 1 "$size_kb" "$size_kb"
    fi
  fi

  # bun-cache via du (no equivalent native cmd outside a project dir).
  dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
  if [[ -d "$dir" ]]; then
    mtime=$(max_mtime_under "$dir")
    [[ -z "$mtime" || "$mtime" == "0" ]] && mtime=$(mtime_of "$dir")
    size_kb=$(size_kb_of_dir "$dir")
    [[ -n "$mtime" ]] && emit_row cache "$mtime" bun-cache 1 "$size_kb" "$size_kb"
  fi
}
