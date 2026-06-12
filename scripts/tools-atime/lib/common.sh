# Shared helpers for tools-atime adapters. Sourced by the orchestrator and
# every lib/<manager>.sh. Idempotent — sourcing twice is a no-op.
#
# Row contract emitted by every <manager>_rows function:
#   manager \t atime \t name \t has_bin \t own_kb \t reclaim_kb

[[ -n "${TOOLS_ATIME_COMMON:-}" ]] && return 0
TOOLS_ATIME_COMMON=1

case "$(uname -s)" in
  Darwin)
    atime_of() { stat -L -f '%a' "$1" 2>/dev/null; }
    mtime_of() { stat -L -f '%m' "$1" 2>/dev/null; }
    date_fmt() { date -r "$1" +%Y-%m-%d 2>/dev/null; }
    _max_mtime_find() {
      find "$1" -type f -print0 2>/dev/null \
        | xargs -0 stat -L -f '%m' 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print int(m)}'
    }
    ;;
  *)
    atime_of() { stat -L -c '%X' "$1" 2>/dev/null; }
    mtime_of() { stat -L -c '%Y' "$1" 2>/dev/null; }
    date_fmt() { date -d "@$1" +%Y-%m-%d 2>/dev/null; }
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

# Inspect renderer. Reads <size_kb> \t <name> \t <extra> on stdin, sorts by
# size desc, caps at INSPECT_LIMIT (0 = no cap), emits table.
inspect_render() {
  local limit=${INSPECT_LIMIT:-30} total=0 count=0 sz name extra
  local sorted
  if (( limit > 0 )); then
    sorted=$(sort -t $'\t' -k1,1nr | head -n "$limit")
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
  (( count > 0 )) && printf '%-8s  %s\n' "$(human_size "$total")" "(top $count shown)"
}

inspect_render_json() {
  local limit=${INSPECT_LIMIT:-30} sorted sz name extra first=true
  if (( limit > 0 )); then
    sorted=$(sort -t $'\t' -k1,1nr | head -n "$limit")
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
