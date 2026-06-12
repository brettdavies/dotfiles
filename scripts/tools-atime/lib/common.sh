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

# Inspect renderer. Reads TSV on stdin: <size_kb> \t <name> \t <extra> with an
# optional 4th field <status> ("ref" | "prune"). When any row carries status
# the renderer adds a STATUS column and a bucket-totals footer.
inspect_render() {
  local limit=${INSPECT_LIMIT:-30} total=0 ref_total=0 prune_total=0 count=0
  local sz name extra status sorted has_status=false
  if (( limit > 0 )); then
    # awk -v n=…; using head here would close stdin early and SIGPIPE
    # `sort` under pipefail once input exceeds the cap (~450 archives).
    sorted=$(sort -t $'\t' -k1,1nr | awk -v n="$limit" 'NR<=n')
  else
    sorted=$(sort -t $'\t' -k1,1nr)
  fi
  # Detect status mode by peeking at the 4th column. No early exit — it would
  # SIGPIPE the upstream printf under pipefail.
  if printf '%s' "$sorted" | awk -F'\t' 'BEGIN{r=1} $4!=""{r=0} END{exit r}'; then
    has_status=true
  fi

  while IFS=$'\t' read -r sz name extra status; do
    [[ -z "$sz" ]] && continue
    total=$(( total + sz ))
    count=$(( count + 1 ))
    if [[ "$has_status" == "true" ]]; then
      case "$status" in
        ref)   ref_total=$(( ref_total + sz )) ;;
        prune) prune_total=$(( prune_total + sz )) ;;
      esac
      local extra_str=""
      [[ -n "$extra" ]] && extra_str="  ($extra)"
      printf '%-8s  %-5s  %s%s\n' "$(human_size "$sz")" "$status" "$name" "$extra_str"
    else
      if [[ -n "$extra" ]]; then
        printf '%-8s  %s  (%s)\n' "$(human_size "$sz")" "$name" "$extra"
      else
        printf '%-8s  %s\n' "$(human_size "$sz")" "$name"
      fi
    fi
  done <<<"$sorted"

  (( count == 0 )) && return
  if [[ "$has_status" == "true" ]]; then
    printf '%-8s  (top %d shown)\n'                          "$(human_size "$total")"        "$count"
    printf '%-8s  ref    (kept by `uv cache prune`)\n'       "$(human_size "$ref_total")"
    printf '%-8s  prune  (removed by `uv cache prune`)\n'    "$(human_size "$prune_total")"
  else
    printf '%-8s  (top %d shown)\n' "$(human_size "$total")" "$count"
  fi
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
