#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# claude-code-archive — convert Claude Code session jsonl to redacted markdown.
#
# Two modes:
#   (no args)                    Full sweep via `cc2md list --json`.
#   --single <jsonl-path>        Single-file mode (used by SessionEnd hook).
#
# Output: ~/.gbrain/transcripts/claude-code/YYYY-MM-DD/<session-id>.md
# Audit:  ~/.gbrain/audit/claude-code-archive-YYYY-WNN.jsonl (RFC3339 ts).
# Called by claude-code-archive.{service,timer} and the SessionEnd hook.
set -euo pipefail

# Load shell env so cc2md, gitleaks, python3 resolve under systemd. The
# set +e / set -e sandwich matches gbrain-sync.sh: caches.sh's conditional
# mkdir patterns return 1 under outer set -e and propagate as fatal exits.
set +e
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
set -e

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/dotfiles}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
CORPUS_ROOT="$HOME/.gbrain/transcripts/claude-code"
AUDIT_DIR="$HOME/.gbrain/audit"
AUDIT_JSONL="$AUDIT_DIR/claude-code-archive-$(date -u +%G-W%V).jsonl"
SHIM="$DOTFILES_ROOT/scripts/sync/lib/gitleaks-redact.py"
SUBAGENT_SHIM="$DOTFILES_ROOT/scripts/sync/lib/subagent-to-md.py"

mkdir -p "$CORPUS_ROOT" "$AUDIT_DIR"

for bin in cc2md gitleaks jaq python3; do
  command -v "$bin" >/dev/null 2>&1 || {
    printf 'claude-code-archive: missing %s on PATH; aborting.\n' "$bin" >&2
    exit 3
  }
done
[[ -r "$SHIM" ]] || {
  printf 'claude-code-archive: shim not readable at %s\n' "$SHIM" >&2
  exit 3
}
[[ -r "$SUBAGENT_SHIM" ]] || {
  printf 'claude-code-archive: subagent shim not readable at %s\n' "$SUBAGENT_SHIM" >&2
  exit 3
}

WORK_DIR=$(mktemp -d -t cc-archive.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_event() {
  jaq -n -c --arg ts "$(now_ts)" "$@" >> "$AUDIT_JSONL"
}

emit_archived() {
  emit_event \
    --arg s "$1" --arg j "$2" --arg t "$3" \
    '{schema_version: 1, ts: $ts, event: "archived", session_id: $s, jsonl_path: $j, target_path: $t}'
}

emit_skipped() {
  emit_event \
    --arg s "$1" --arg j "$2" --arg r "$3" \
    '{schema_version: 1, ts: $ts, event: "skipped", session_id: $s, jsonl_path: $j, reason: $r}'
}

emit_failed() {
  emit_event \
    --arg s "$1" --arg j "$2" --arg r "$3" \
    '{schema_version: 1, ts: $ts, event: "failed", session_id: $s, jsonl_path: $j, error: $r}'
}

emit_discovered() {
  emit_event \
    --argjson c "$1" --argjson o "$2" --argjson f "$3" --argjson s "$4" --arg src "$5" \
    '{schema_version: 1, ts: $ts, event: "discovered", source: $src, count: $c, archived: $o, failed: $f, skipped: $s}'
}

process_jsonl() {
  local jsonl="$1" session="$2" modified="$3"
  local date_dir="${modified%%T*}"
  if [[ ! "$date_dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    emit_failed "$session" "$jsonl" "bad_modified_at:$modified"
    return 1
  fi

  local target_dir="$CORPUS_ROOT/$date_dir"
  local target="$target_dir/$session.md"

  if [[ -f "$target" ]]; then
    emit_skipped "$session" "$jsonl" "already_archived"
    return 0
  fi

  mkdir -p "$target_dir"

  local raw="$WORK_DIR/$session.raw.md"
  local clean="$WORK_DIR/$session.clean.md"

  if ! cc2md "$jsonl" --raw --markdown gfm --thinking -o "$raw" >/dev/null 2>&1; then
    emit_failed "$session" "$jsonl" "cc2md_failed"
    return 1
  fi

  if ! python3 "$SHIM" "$raw" --audit-jsonl "$AUDIT_JSONL" > "$clean" 2>/dev/null; then
    emit_failed "$session" "$jsonl" "redaction_subprocess_failed"
    return 1
  fi

  if ! mv -- "$clean" "$target" 2>/dev/null; then
    emit_failed "$session" "$jsonl" "mv_to_target_failed"
    return 1
  fi

  emit_archived "$session" "$jsonl" "$target"
  return 0
}

extract_subagent_meta() {
  local jsonl="$1"
  jaq -r -s '
    map(select(.type == "user" or .type == "assistant"))
    | (.[0] // {})
    | [(.sessionId // ""), (.agentId // ""), (.timestamp // "")]
    | @tsv
  ' < "$jsonl" 2>/dev/null
}

process_subagent_jsonl() {
  local jsonl="$1"
  local meta agent_id parent_session modified
  meta=$(extract_subagent_meta "$jsonl")
  if [[ -z "$meta" ]]; then
    emit_failed "" "$jsonl" "subagent_meta_extract_failed"
    return 1
  fi
  IFS=$'\t' read -r parent_session agent_id modified <<< "$meta"
  if [[ -z "$agent_id" || -z "$parent_session" || -z "$modified" ]]; then
    local fallback_id
    fallback_id=$(basename "$jsonl" .jsonl | sed 's/^agent-//')
    [[ -z "$agent_id" ]] && agent_id="$fallback_id"
    [[ -z "$modified" ]] && modified=$(date -u -r "$jsonl" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ -z "$parent_session" ]]; then
      local parent_dir
      parent_dir=$(basename "$(dirname "$(dirname "$jsonl")")")
      parent_session="$parent_dir"
    fi
  fi

  local date_dir="${modified%%T*}"
  if [[ ! "$date_dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    emit_failed "$agent_id" "$jsonl" "bad_modified_at:$modified"
    return 1
  fi

  local target_dir="$CORPUS_ROOT/$date_dir"
  local target="$target_dir/${parent_session}--${agent_id}.md"

  if [[ -f "$target" ]]; then
    emit_skipped "$agent_id" "$jsonl" "already_archived"
    return 0
  fi

  mkdir -p "$target_dir"

  local raw="$WORK_DIR/${parent_session}--${agent_id}.raw.md"
  local clean="$WORK_DIR/${parent_session}--${agent_id}.clean.md"

  if ! python3 "$SUBAGENT_SHIM" "$jsonl" -o "$raw" 2>/dev/null; then
    emit_failed "$agent_id" "$jsonl" "subagent_convert_failed"
    return 1
  fi

  if ! python3 "$SHIM" "$raw" --audit-jsonl "$AUDIT_JSONL" > "$clean" 2>/dev/null; then
    emit_failed "$agent_id" "$jsonl" "redaction_subprocess_failed"
    return 1
  fi

  if ! mv -- "$clean" "$target" 2>/dev/null; then
    emit_failed "$agent_id" "$jsonl" "mv_to_target_failed"
    return 1
  fi

  emit_archived "$agent_id" "$jsonl" "$target"
  return 0
}

sweep_top_level() {
  local listing
  if ! listing=$(cc2md list --json 2>/dev/null); then
    emit_failed "" "" "cc2md_list_failed"
    return 1
  fi

  local count=0 ok=0 fail=0 skip=0
  while IFS=$'\t' read -r path session modified; do
    [[ -z "$path" ]] && continue
    count=$((count + 1))
    local target_dir="$CORPUS_ROOT/${modified%%T*}"
    local target="$target_dir/$session.md"
    if [[ -f "$target" ]]; then
      skip=$((skip + 1))
      continue
    fi
    if process_jsonl "$path" "$session" "$modified"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done < <(printf '%s' "$listing" | jaq -r '.[] | [.path, .session_id, .modified_at] | @tsv')

  emit_discovered "$count" "$ok" "$fail" "$skip" "top_level"
  return 0
}

sweep_subagents() {
  local count=0 ok=0 fail=0 skip=0
  while IFS= read -r jsonl; do
    [[ -z "$jsonl" ]] && continue
    count=$((count + 1))
    if process_subagent_jsonl "$jsonl"; then
      if tail -1 "$AUDIT_JSONL" | jaq -e '.event == "skipped"' >/dev/null 2>&1; then
        skip=$((skip + 1))
      else
        ok=$((ok + 1))
      fi
    else
      fail=$((fail + 1))
    fi
  done < <(find "$CLAUDE_PROJECTS" -path '*/subagents/agent-*.jsonl' -type f 2>/dev/null)

  emit_discovered "$count" "$ok" "$fail" "$skip" "subagents"
  return 0
}

sweep() {
  sweep_top_level
  sweep_subagents
}

single() {
  local jsonl="$1"
  if [[ ! -f "$jsonl" ]]; then
    emit_failed "" "$jsonl" "jsonl_not_found"
    return 1
  fi

  if [[ "$jsonl" == *"/subagents/"* ]]; then
    process_subagent_jsonl "$jsonl"
    return $?
  fi

  local meta
  if ! meta=$(cc2md list --json 2>/dev/null | jaq -r --arg p "$jsonl" '.[] | select(.path == $p) | [.session_id, .modified_at] | @tsv'); then
    emit_failed "" "$jsonl" "cc2md_list_failed"
    return 1
  fi
  if [[ -z "$meta" ]]; then
    emit_failed "" "$jsonl" "session_metadata_not_found"
    return 1
  fi

  local session modified
  IFS=$'\t' read -r session modified <<< "$meta"
  process_jsonl "$jsonl" "$session" "$modified"
}

main() {
  case "${1:-}" in
    "")
      sweep
      ;;
    --single)
      [[ -n "${2:-}" ]] || { printf 'usage: %s --single <jsonl-path>\n' "$0" >&2; exit 2; }
      single "$2"
      ;;
    -h|--help)
      printf 'usage: %s [--single <jsonl-path>]\n' "$0"
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

main "$@"
