# Shared helpers for tools-atime adapters. Sourced by the orchestrator and
# every lib/<manager>.sh. Idempotent — sourcing twice is a no-op.
#
# Row contract emitted by every <manager>_rows function:
#   manager \t atime \t name \t has_bin \t own_kb \t reclaim_kb

[[ -n "${TOOLS_ATIME_COMMON:-}" ]] && return 0
TOOLS_ATIME_COMMON=1

case "$(uname -s)" in
  Darwin)
    atime_of()  { stat -L -f '%a' "$1" 2>/dev/null; }
    mtime_of()  { stat -L -f '%m' "$1" 2>/dev/null; }
    nlinks_of() { stat -L -f '%l' "$1" 2>/dev/null; }
    date_fmt()  { date -r "$1" +%Y-%m-%d 2>/dev/null; }
    _max_mtime_find() {
      find "$1" -type f -print0 2>/dev/null \
        | xargs -0 stat -L -f '%m' 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print int(m)}'
    }
    ;;
  *)
    atime_of()  { stat -L -c '%X' "$1" 2>/dev/null; }
    mtime_of()  { stat -L -c '%Y' "$1" 2>/dev/null; }
    nlinks_of() { stat -L -c '%h' "$1" 2>/dev/null; }
    date_fmt()  { date -d "@$1" +%Y-%m-%d 2>/dev/null; }
    _max_mtime_find() {
      find "$1" -type f -printf '%T@\n' 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print int(m)}'
    }
    ;;
esac

human_size() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb < 1024) { printf "%dK", kb; exit }
    mb = kb / 1024
    if (mb < 100)  { printf "%.1fM", mb; exit }
    if (mb < 1024) { printf "%dM", mb; exit }
    printf "%.1fG", mb / 1024
  }'
}

size_kb_of_dir() {
  [[ -d "$1" ]] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

# Max atime across plain files in a single dir (non-recursive). Follows
# symlinks so install dirs that symlink into Cellar/.local/share still work.
max_atime_in_dir() {
  local dir=$1 max=0 a f
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    a=$(atime_of "$f") || continue
    (( a > max )) && max=$a
  done
  shopt -u nullglob
  (( max > 0 )) && printf '%d\n' "$max"
}

# Newest mtime across all files under a dir (recursive). Used by caches.sh
# where atime is noisy but mtime tracks "last fetched/written".
max_mtime_under() { _max_mtime_find "$1"; }

# TSV row emitter. Every adapter calls this so column order is fixed.
emit_row() {
  printf '%s\t%d\t%s\t%d\t%d\t%d\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# Short human age from epoch. "$2" overrides "now" for tests.
reclaim_age() {
  local epoch=$1 ref=${2:-$(date +%s)} days
  days=$(( (ref - epoch) / 86400 ))
  if   (( days <= 0 )); then echo "used today"
  elif (( days == 1 )); then echo "1d ago"
  else echo "${days}d ago"
  fi
}

# Inspect renderer. Reads TSV on stdin: <size_kb> \t <name> \t <extra>.
# Sorts by size desc, caps at INSPECT_LIMIT, prints a total footer.
# uv-cache uses inspect_render_freeable instead because it tracks two sizes.
inspect_render() {
  local limit=${INSPECT_LIMIT:-30} total=0 count=0 sz name extra sorted
  if (( limit > 0 )); then
    # awk -v n=…; head here would close stdin early and SIGPIPE sort under pipefail.
    sorted=$(sort -t $'\t' -k1,1nr | awk -v n="$limit" 'NR<=n')
  else
    sorted=$(sort -t $'\t' -k1,1nr)
  fi
  while IFS=$'\t' read -r sz name extra; do
    [[ -z "$sz" ]] && continue
    total=$(( total + sz ))
    count=$(( count + 1 ))
    if [[ -n "$extra" ]]; then
      printf '%-8s  %s  (%s)\n' "$(human_size "$sz")" "$name" "$extra"
    else
      printf '%-8s  %s\n' "$(human_size "$sz")" "$name"
    fi
  done <<<"$sorted"
  (( count > 0 )) && printf '%-8s  (top %d shown)\n' "$(human_size "$total")" "$count"
}

# inspect_render_freeable — for adapters that distinguish "total" from
# "would-actually-free-disk." Reads 4-col TSV (total_kb \t freeable_kb \t
# name \t version) and emits two size columns, sorted by freeable desc.
# Footer prints both top-N totals and global totals across all rows.
inspect_render_freeable() {
  local limit=${INSPECT_LIMIT:-30}
  local -a rows
  mapfile -t rows < <(sort -t $'\t' -k2,2nr)

  # Global totals across every row, not just the visible window.
  local total=0 free_total=0 r t f
  for r in "${rows[@]}"; do
    [[ -z "$r" ]] && continue
    IFS=$'\t' read -r t f _ _ <<<"$r"
    total=$(( total + t ))
    free_total=$(( free_total + f ))
  done

  printf '%-8s  %-8s  %s\n' 'TOTAL' 'FREEABLE' 'PACKAGE'
  local count=0 t_sum=0 f_sum=0 name ver ver_str cap=${#rows[@]}
  (( limit > 0 && limit < cap )) && cap=$limit
  local i
  for (( i = 0; i < cap; i++ )); do
    IFS=$'\t' read -r t f name ver <<<"${rows[$i]}"
    [[ -z "$t" ]] && continue
    t_sum=$(( t_sum + t ))
    f_sum=$(( f_sum + f ))
    count=$(( count + 1 ))
    ver_str=""
    [[ -n "$ver" && "$ver" != "?" ]] && ver_str=" ($ver)"
    printf '%-8s  %-8s  %s%s\n' \
      "$(human_size "$t")" "$(human_size "$f")" "$name" "$ver_str"
  done

  (( count == 0 )) && return
  printf '%-8s  %-8s  (top %d by freeable shown)\n' \
    "$(human_size "$t_sum")" "$(human_size "$f_sum")" "$count"
  printf '%-8s  %-8s  ALL %d archives (total / disk-freeable)\n' \
    "$(human_size "$total")" "$(human_size "$free_total")" "${#rows[@]}"
  printf '         FREEABLE counts bytes whose inode lives only in the cache (nlinks=1).\n'
  printf '         `uv cache prune` is conservative; `uv cache clean` would reclaim the max.\n'
}

inspect_render_freeable_json() {
  local limit=${INSPECT_LIMIT:-30} t f name ver first=true
  local sorted
  if (( limit > 0 )); then
    sorted=$(sort -t $'\t' -k2,2nr | awk -v n="$limit" 'NR<=n')
  else
    sorted=$(sort -t $'\t' -k2,2nr)
  fi
  printf '['
  while IFS=$'\t' read -r t f name ver; do
    [[ -z "$t" ]] && continue
    [[ "$first" == "true" ]] && first=false || printf ','
    printf '{"total_kb":%d,"freeable_kb":%d,"name":"%s","version":"%s"}' \
      "$t" "$f" "$name" "$ver"
  done <<<"$sorted"
  printf ']\n'
}

inspect_render_json() {
  local limit=${INSPECT_LIMIT:-30} sorted sz name extra first=true
  if (( limit > 0 )); then
    # awk -v n=…; using head here would close stdin early and SIGPIPE
    # `sort` under pipefail once input exceeds the cap (~450 archives).
    sorted=$(sort -t $'\t' -k1,1nr | awk -v n="$limit" 'NR<=n')
  else
    sorted=$(sort -t $'\t' -k1,1nr)
  fi
  printf '['
  while IFS=$'\t' read -r sz name extra; do
    [[ -z "$sz" ]] && continue
    [[ "$first" == "true" ]] && first=false || printf ','
    printf '{"size_kb":%d,"name":"%s","extra":"%s"}' "$sz" "$name" "$extra"
  done <<<"$sorted"
  printf ']\n'
}
