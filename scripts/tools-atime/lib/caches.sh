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
  printf '%d\n' $((bytes / 1024))
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
  t=${t#cache/}
  t=${t#caches/}
  printf '%s\n' "$t"
}

caches_actions() {
  case "$(_caches_strip_prefix "$1")" in
    uv-cache) echo "p:prune c:clean-all" ;;
    bun-cache) echo "r:rm-all" ;;
    *) echo "" ;;
  esac
}

# caches_measure <target>  →  KB. Defers to the PM's own size command for
# uv-cache (cheap and authoritative); du for bun-cache (no native cmd).
caches_measure() {
  local target
  target=$(_caches_strip_prefix "$1")
  case "$target" in
    uv-cache) _uv_cache_size_kb 2>/dev/null || echo 0 ;;
    bun-cache) du -sk "${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}" 2>/dev/null | awk '{print $1+0}' ;;
    *) echo 0 ;;
  esac
}

caches_act() {
  local target action=$2
  target=$(_caches_strip_prefix "$1")
  case "$target/$action" in
    uv-cache/p | uv-cache/prune)
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: uv cache prune"
        return 0
      fi
      uv cache prune
      ;;
    uv-cache/c | uv-cache/clean-all)
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: uv cache clean"
        return 0
      fi
      uv cache clean
      ;;
    bun-cache/r | bun-cache/rm-all)
      local dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: trash $dir"
        return 0
      fi
      command -v trash >/dev/null && trash "$dir" || rm -rf "$dir"
      ;;
    *)
      echo "caches_act: unknown action $target/$action" >&2
      return 1
      ;;
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
      [[ -d "$archive_root" ]] || {
        echo "uv archive cache not found" >&2
        return 1
      }
      # Single find walks every file under archive-v0 once, emitting path,
      # bytes, nlinks. Awk groups by archive directory, summing total bytes
      # and the subset where nlinks == 1 (files only the cache references).
      # When it sees an archive's METADATA file it also extracts Name/Version
      # so the same pass produces (total_kb, freeable_kb, name, version).
      #
      # freeable_kb is the honest "if I drop this archive, how much disk
      # actually frees" — files hardlinked into a tool venv contribute 0
      # to freeable even though they appear in the archive's total.
      find "$archive_root" -type f -printf '%p\t%s\t%n\n' 2>/dev/null \
        | awk -F'\t' '
          function read_meta(file,   line, n, v) {
            while ((getline line < file) > 0) {
              gsub(/\r/, "", line)
              if (n == "" && line ~ /^Name: /)    n = substr(line, 7)
              if (v == "" && line ~ /^Version: /) v = substr(line, 10)
              if (n != "" && v != "") break
            }
            close(file)
            return n "\t" v
          }
          {
            match($1, /archive-v0\/[^\/]+/)
            arch = substr($1, RSTART, RLENGTH)
            total[arch] += $2
            if ($3 == 1) free[arch] += $2
            if ($1 ~ /\.dist-info\/METADATA$/ && !(arch in info)) {
              info[arch] = read_meta($1)
            }
          }
          END {
            for (k in total) {
              f = (k in free) ? free[k] : 0
              meta = (k in info) ? info[k] : "?\t?"
              printf "%d\t%d\t%s\n", int(total[k]/1024), int(f/1024), meta
            }
          }'
      ;;
    bun-cache)
      local dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
      [[ -d "$dir" ]] || {
        echo "bun cache not found" >&2
        return 1
      }
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
