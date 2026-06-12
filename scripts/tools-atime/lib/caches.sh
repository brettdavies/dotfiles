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
      [[ -n "$mtime" ]] && emit_row caches "$mtime" uv-cache 1 "$size_kb" "$size_kb"
    fi
  fi

  # bun-cache via du (no equivalent native cmd outside a project dir).
  dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
  if [[ -d "$dir" ]]; then
    mtime=$(max_mtime_under "$dir")
    [[ -z "$mtime" || "$mtime" == "0" ]] && mtime=$(mtime_of "$dir")
    size_kb=$(size_kb_of_dir "$dir")
    [[ -n "$mtime" ]] && emit_row caches "$mtime" bun-cache 1 "$size_kb" "$size_kb"
  fi
}

_caches_strip_prefix() {
  local t=$1
  t=${t#cache/}; t=${t#caches/}
  printf '%s\n' "$t"
}

caches_actions() {
  case "$(_caches_strip_prefix "$1")" in
    uv-cache)  echo "p:prune c:clean-all" ;;
    bun-cache) echo "r:rm-all" ;;
    *)         echo "" ;;
  esac
}

# caches_measure <target>  →  KB. Defers to the PM's own size command for
# uv-cache (cheap and authoritative); du for bun-cache (no native cmd).
caches_measure() {
  local target
  target=$(_caches_strip_prefix "$1")
  case "$target" in
    uv-cache)  _uv_cache_size_kb 2>/dev/null || echo 0 ;;
    bun-cache) du -sk "${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}" 2>/dev/null | awk '{print $1+0}' ;;
    *)         echo 0 ;;
  esac
}

caches_act() {
  local target action=$2
  target=$(_caches_strip_prefix "$1")
  case "$target/$action" in
    uv-cache/p|uv-cache/prune)
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: uv cache prune"; return 0
      fi
      uv cache prune
      ;;
    uv-cache/c|uv-cache/clean-all)
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: uv cache clean"; return 0
      fi
      uv cache clean
      ;;
    bun-cache/r|bun-cache/rm-all)
      local dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: trash $dir"; return 0
      fi
      command -v trash >/dev/null && trash "$dir" || rm -rf "$dir"
      ;;
    *) echo "caches_act: unknown action $target/$action" >&2; return 1 ;;
  esac
}

# caches_inspect <target>  →  TSV (<size_kb> \t <name> \t <version|"">)
# Reaches for the filesystem because no PM exposes per-package cache listing.
caches_inspect() {
  local target
  target=$(_caches_strip_prefix "$1")
  case "$target" in
    uv-cache)
      local archive_root
      archive_root="$(_uv_cache_dir 2>/dev/null)/archive-v0"
      [[ -d "$archive_root" ]] || { echo "uv archive cache not found" >&2; return 1; }
      # One row per archive-v0/<hash>/<pkg>-<ver>.dist-info/METADATA so each
      # cached version is visible separately — aggregation would hide which
      # specific version is referenced vs prunable.
      #
      # Status comes from the METADATA file's hardlink count: nlinks > 1
      # means some installed venv has it hardlinked in (referenced); nlinks
      # == 1 means nothing points at it and `uv cache prune` will remove it.
      # The host fs is ext4 — uv falls back to hardlink mode when reflink
      # isn't available, so this signal is reliable here.
      find "$archive_root" -mindepth 2 -maxdepth 4 -name METADATA -path '*.dist-info/*' 2>/dev/null \
      | while IFS= read -r meta; do
          local arch pkg ver sz nl status
          arch=$(printf '%s\n' "$meta" | sed -E 's|(/archive-v0/[^/]+)/.*|\1|')
          pkg=$(grep -m1 '^Name: '    "$meta" | cut -d' ' -f2- | tr -d '\r')
          ver=$(grep -m1 '^Version: ' "$meta" | cut -d' ' -f2- | tr -d '\r')
          sz=$(du -sk "$arch" 2>/dev/null | cut -f1)
          nl=$(nlinks_of "$meta")
          if [[ -n "$nl" ]] && (( nl > 1 )); then status=ref; else status=prune; fi
          printf '%d\t%s\t%s\t%s\n' "${sz:-0}" "$pkg" "$ver" "$status"
        done
      ;;
    bun-cache)
      local dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
      [[ -d "$dir" ]] || { echo "bun cache not found" >&2; return 1; }
      # Top-level entries are either <pkg>@<ver>@@@N (flat) or @scope (dir
      # holding the scope's packages). Aggregate by scope or unscoped name.
      shopt -s nullglob
      local d name sz
      for d in "$dir"/*/; do
        name=$(basename "${d%/}")
        if [[ "$name" != @* ]]; then
          name=$(printf '%s\n' "$name" | sed -E 's/(@[0-9][^@]*)?(@@@.*)?$//')
        fi
        sz=$(du -sk "$d" 2>/dev/null | cut -f1)
        printf '%d\t%s\t\n' "${sz:-0}" "$name"
      done \
      | awk -F'\t' 'BEGIN{OFS=FS} {sz[$2]+=$1} END {for (k in sz) print sz[k], k, ""}'
      shopt -u nullglob
      ;;
    *)
      echo "unknown cache inspect target: $target (try: uv-cache, bun-cache)" >&2
      return 1
      ;;
  esac
}
