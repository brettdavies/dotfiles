#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# claude-code-synthesize-sweep — hand-rolled synthesize loop over the corpus.
#
# Iterates `.md` files under ~/.gbrain/transcripts/claude-code/ in date order
# and runs `gbrain dream --phase synthesize --input <file> --json` per file.
# `--input` mode bypasses checkCooldown (only the corpus-dir-scan path runs
# the cooldown gate), so this is the right knob for a one-shot backfill.
#
# NO enforced cost cap. The user runs this in one pane and tails the existing
# `~/.gbrain/audit/dream-budget-*.jsonl` ledger in another. Stop with Ctrl-C
# when satisfied -- the trap writes a final summary on signal.
#
# `dream_verdicts` content-hash cache makes second + subsequent passes cheap.
# Per-file audit goes to ~/.gbrain/audit/claude-code-synthesize-sweep-*.jsonl.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: claude-code-synthesize-sweep.sh [-h|--help] [--dry-run]

Iterate every .md under ~/.gbrain/transcripts/claude-code/ and run
`gbrain dream --phase synthesize --input <file> --json` per file.
Stop with Ctrl-C; the trap writes a summary on signal.

Flags:
  -h, --help      show this help and exit (does not invoke gbrain).
  --dry-run       enumerate transcripts and emit a `dry_run` audit event;
                  do not call gbrain.

Cost monitoring: tail ~/.gbrain/audit/dream-budget-*.jsonl in another pane.
EOF
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

set +e
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
set -e

CORPUS_ROOT="$HOME/.gbrain/transcripts/claude-code"
AUDIT_DIR="$HOME/.gbrain/audit"
AUDIT_JSONL="$AUDIT_DIR/claude-code-synthesize-sweep-$(date -u +%G-W%V).jsonl"

for bin in gbrain jaq find; do
  command -v "$bin" >/dev/null 2>&1 || {
    printf 'claude-code-synthesize-sweep: missing %s on PATH; aborting.\n' "$bin" >&2
    exit 3
  }
done

[[ -d "$CORPUS_ROOT" ]] || {
  printf 'claude-code-synthesize-sweep: corpus dir not found: %s\n' "$CORPUS_ROOT" >&2
  exit 3
}

mkdir -p "$AUDIT_DIR"

PROCESSED=0
FAILED=0
SKIPPED=0
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_event() {
  jaq -n -c --arg ts "$(now_ts)" "$@" >> "$AUDIT_JSONL"
}

emit_processed() {
  emit_event \
    --arg s "$1" --arg f "$2" --argjson v "$3" --argjson p "$4" --argjson c "$5" \
    '{schema_version: 1, ts: $ts, event: "processed", session_id: $s, file: $f, verdicts_count: $v, pages_written: $p, exit_code: $c}'
}

emit_failed() {
  emit_event \
    --arg f "$1" --argjson c "$2" --arg r "$3" \
    '{schema_version: 1, ts: $ts, event: "failed", file: $f, exit_code: $c, error: $r}'
}

emit_summary() {
  emit_event \
    --arg s "$START_TS" --argjson p "$PROCESSED" --argjson f "$FAILED" --argjson k "$SKIPPED" --arg r "$1" \
    '{schema_version: 1, ts: $ts, event: "summary", started_at: $s, processed: $p, failed: $f, skipped: $k, reason: $r}'
}

print_summary() {
  printf '\n--- claude-code-synthesize-sweep summary ---\n' >&2
  printf 'started_at: %s\n' "$START_TS" >&2
  printf 'processed:  %d\n' "$PROCESSED" >&2
  printf 'failed:     %d\n' "$FAILED" >&2
  printf 'skipped:    %d\n' "$SKIPPED" >&2
  printf 'audit:      %s\n' "$AUDIT_JSONL" >&2
  printf 'cost ledger: tail ~/.gbrain/audit/dream-budget-*.jsonl\n' >&2
}

on_signal() {
  printf '\nclaude-code-synthesize-sweep: caught signal, writing summary.\n' >&2
  emit_summary "signal"
  print_summary
  exit 0
}
trap on_signal INT TERM

# Iterate in date-partition order; oldest first so the verdict cache builds up
# usefully for any later targeted re-run.
mapfile -t TRANSCRIPTS < <(find "$CORPUS_ROOT" -type f -name "*.md" | sort)

if [[ ${#TRANSCRIPTS[@]} -eq 0 ]]; then
  emit_summary "no_transcripts"
  print_summary
  exit 0
fi

printf 'claude-code-synthesize-sweep: %d transcripts queued. Ctrl-C to stop.\n' "${#TRANSCRIPTS[@]}" >&2
printf 'Watch cost in another pane: tail -F ~/.gbrain/audit/dream-budget-*.jsonl | jaq -r .cumulative_cost_usd\n' >&2

if [[ "$DRY_RUN" == "1" ]]; then
  for file in "${TRANSCRIPTS[@]}"; do
    emit_event --arg f "$file" \
      '{schema_version: 1, ts: $ts, event: "dry_run", file: $f}'
  done
  printf 'claude-code-synthesize-sweep: --dry-run logged %d transcripts; no gbrain calls made.\n' "${#TRANSCRIPTS[@]}" >&2
  emit_summary "dry_run"
  print_summary
  exit 0
fi

for file in "${TRANSCRIPTS[@]}"; do
  session=$(basename "$file" .md)
  result=""
  exit_code=0
  if ! result=$(gbrain dream --phase synthesize --input "$file" --json 2>/dev/null); then
    exit_code=$?
    FAILED=$((FAILED + 1))
    emit_failed "$file" "$exit_code" "gbrain_dream_nonzero"
    continue
  fi

  verdicts=$(printf '%s' "$result" | jaq -r '(.verdicts_count // .verdicts | length // 0)' 2>/dev/null || printf '0')
  pages=$(printf '%s' "$result" | jaq -r '(.pages_written // .pages // 0)' 2>/dev/null || printf '0')
  [[ -z "$verdicts" || "$verdicts" == "null" ]] && verdicts=0
  [[ -z "$pages" || "$pages" == "null" ]] && pages=0
  PROCESSED=$((PROCESSED + 1))
  emit_processed "$session" "$file" "$verdicts" "$pages" "$exit_code"
done

emit_summary "completed"
print_summary
