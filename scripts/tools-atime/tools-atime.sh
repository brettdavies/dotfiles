#!/usr/bin/env bash
# tools-atime.sh — audit installed CLI tools across package managers, sorting
# by last-used time (binary atime) with disk-size + reclaim figures.
#
# Adapters live under lib/<manager>.sh. Each exposes <manager>_rows() that
# emits TSV: manager \t atime \t name \t has_bin \t own_kb \t reclaim_kb.
# The orchestrator concatenates, sorts, filters, and renders.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/lib"
# shellcheck source=lib/common.sh
source "$LIB/common.sh"

DEFAULT_MANAGERS=(brew uv cargo bun caches)
DAYS=
JSON=false
QUIET=false
SKIP_NOBIN=false
SORT=age
REVERSE=false
MANAGERS_FLAG=""
INSPECT=""
INSPECT_LIMIT=30
export INSPECT_LIMIT

usage() {
  cat <<'EOF'
Usage: tools-atime.sh [options]

Sort installed CLI tools by last-used time across multiple package managers,
with own + cascading-reclaim sizes so cleanup decisions never leave stragglers.

Options:
  -m, --manager LIST  comma-separated subset of: brew,uv,cargo,bun,caches
                      (default: all of them)
  -d, --days N        only show entries unused for N+ days
  -s, --sort FIELD    sort by: age (default) | name | size | reclaim | manager
  -r, --reverse       reverse the sort order
  -i, --inspect TGT   drill into one entry by size. Valid targets:
                        uv-cache | bun-cache | uv/<tool>
                      Uses `du` to fill gaps the PM CLI doesn't expose.
  -l, --limit N       cap inspect output at N entries (default 30, 0 = all)
  -j, --json          emit JSON instead of a table (rows and inspect)
  -q, --quiet         emit "manager/name" pairs only (skips no-bin entries)
  -B, --no-bin-skip   skip rows flagged as library-only (no bin/ dir)
  -h, --help          show this help

Managers:
  brew    `brew leaves` + brew autoremove cascade (reclaim includes deps)
  uv      `uv tool list` — Python apps with isolated venvs
  cargo   `cargo install --list` — Rust binaries in ~/.cargo/bin
  bun     `bun pm ls -g` — JS globals
  caches  ~/.cache/uv and ~/.bun/install/cache — ephemeral download caches
EOF
}

while (($#)); do
  case "$1" in
    -m|--manager)     MANAGERS_FLAG="${2:?--manager needs a value}"; shift 2 ;;
    -d|--days)        DAYS="${2:?--days needs a value}"; shift 2 ;;
    -s|--sort)        SORT="${2:?--sort needs a field}"; shift 2 ;;
    -r|--reverse)     REVERSE=true; shift ;;
    -i|--inspect)     INSPECT="${2:?--inspect needs a target}"; shift 2 ;;
    -l|--limit)       INSPECT_LIMIT="${2:?--limit needs a value}"; shift 2 ;;
    -j|--json)        JSON=true; shift ;;
    -q|--quiet)       QUIET=true; shift ;;
    -B|--no-bin-skip) SKIP_NOBIN=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Inspect mode short-circuits the list pipeline.
if [[ -n "$INSPECT" ]]; then
  case "$INSPECT" in
    uv-cache|cache/uv-cache|bun-cache|cache/bun-cache)
      # shellcheck source=lib/caches.sh
      source "$LIB/caches.sh"
      data=$(caches_inspect "$INSPECT") || exit 1
      ;;
    uv/*)
      # shellcheck source=lib/uv.sh
      source "$LIB/uv.sh"
      data=$(uv_inspect "${INSPECT#uv/}") || exit 1
      ;;
    *)
      echo "inspect target must be: uv-cache | bun-cache | uv/<tool>" >&2
      exit 2
      ;;
  esac
  [[ -z "$data" ]] && { echo "(empty inspection result for $INSPECT)" >&2; exit 0; }
  if [[ "$JSON" == "true" ]]; then
    printf '%s\n' "$data" | inspect_render_json
  else
    printf 'Inspecting %s — top by size:\n\n' "$INSPECT"
    printf '%s\n' "$data" | inspect_render
  fi
  exit 0
fi

case "$SORT" in
  age|name|size|reclaim|manager) ;;
  *) echo "--sort must be age|name|size|reclaim|manager" >&2; exit 2 ;;
esac

if [[ -n "$MANAGERS_FLAG" ]]; then
  IFS=, read -ra SELECTED <<<"$MANAGERS_FLAG"
else
  SELECTED=("${DEFAULT_MANAGERS[@]}")
fi

# Dispatch — source + collect rows from each requested manager.
all_rows=""
for m in "${SELECTED[@]}"; do
  case "$m" in
    brew|uv|cargo|bun|caches)
      # shellcheck source=/dev/null
      source "$LIB/${m}.sh"
      rows_fn="${m}_rows"
      all_rows+=$("$rows_fn")$'\n'
      ;;
    *) echo "unknown manager: $m" >&2; exit 2 ;;
  esac
done

now=$(date +%s)
threshold=
[[ -n "$DAYS" ]] && threshold=$(( now - DAYS * 86400 ))

rev=""; [[ "$REVERSE" == "true" ]] && rev="r"
case "$SORT" in
  age)     sort_args=(-t $'\t' -k2,2n${rev}) ;;
  name)    sort_args=(-t $'\t' -k3,3${rev})  ;;
  size)    sort_args=(-t $'\t' -k5,5n${rev}) ;;
  reclaim) sort_args=(-t $'\t' -k6,6n${rev}) ;;
  manager) sort_args=(-t $'\t' -k1,1${rev})  ;;
esac

filter() {
  while IFS=$'\t' read -r mgr atime name hasbin own reclaim; do
    [[ -z "$atime" ]] && continue
    [[ -n "$threshold" && "$atime" -gt "$threshold" ]] && continue
    [[ "$hasbin" == "0" && "$SKIP_NOBIN" == "true" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$mgr" "$atime" "$name" "$hasbin" "$own" "$reclaim"
  done
}

sorted=$(printf '%s' "$all_rows" | grep -v '^[[:space:]]*$' | sort "${sort_args[@]}" | filter)

if [[ "$JSON" == "true" ]]; then
  printf '['
  first=true
  while IFS=$'\t' read -r mgr atime name hasbin own reclaim; do
    [[ -z "$atime" ]] && continue
    days=$(( (now - atime) / 86400 ))
    [[ "$first" == true ]] && first=false || printf ','
    printf '{"manager":"%s","name":"%s","atime":%d,"days_ago":%d,"has_bin":%s,"size_kb":%d,"reclaim_kb":%d}' \
      "$mgr" "$name" "$atime" "$days" \
      "$([[ "$hasbin" == "1" ]] && echo true || echo false)" \
      "$own" "$reclaim"
  done <<<"$sorted"
  printf ']\n'
elif [[ "$QUIET" == "true" ]]; then
  while IFS=$'\t' read -r mgr _ name hasbin _ _; do
    [[ -z "$name" ]] && continue
    [[ "$hasbin" == "0" ]] && continue
    printf '%s/%s\n' "$mgr" "$name"
  done <<<"$sorted"
else
  printf '%-8s  %-12s  %-9s  %-8s  %-8s  %s\n' \
    'MANAGER' 'LAST USED' 'DAYS AGO' 'SIZE' 'RECLAIM' 'NAME'
  while IFS=$'\t' read -r mgr atime name hasbin own reclaim; do
    [[ -z "$atime" ]] && continue
    date_str=$(date_fmt "$atime")
    days=$(( (now - atime) / 86400 ))
    own_str=$(human_size "$own")
    reclaim_str=$(human_size "$reclaim")
    suffix=""
    [[ "$hasbin" == "0" ]] && suffix=" (no bin/)"
    printf '%-8s  %-12s  %-9s  %-8s  %-8s  %s%s\n' \
      "$mgr" "$date_str" "${days}d" "$own_str" "$reclaim_str" "$name" "$suffix"
  done <<<"$sorted"
fi
