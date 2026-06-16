#!/usr/bin/env bash
# SessionEnd hook: kick off claude-code-archive on the ending session's jsonl.
# Fire-and-forget; MUST exit 0 to avoid blocking shell exit.
#
# Defensive schema: tries .transcript_path first (direct path, zero filesystem
# walk), falls back to .session_id resolution via find under ~/.claude/projects.
# Both shapes have appeared in Claude Code hook payloads; the probe documented
# in the plan is replaced by this runtime detection.
set -uo pipefail

INPUT=$(cat)

command -v jaq >/dev/null 2>&1 || exit 0
ARCHIVE_SH="$HOME/dotfiles/scripts/sync/claude-code-archive.sh"
[[ -x "$ARCHIVE_SH" ]] || exit 0

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jaq -r '.transcript_path // ""' 2>/dev/null || printf '')
SESSION_ID=$(printf '%s' "$INPUT" | jaq -r '.session_id // ""' 2>/dev/null || printf '')

JSONL=""
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  JSONL="$TRANSCRIPT_PATH"
elif [[ -n "$SESSION_ID" ]]; then
  JSONL=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f -print -quit 2>/dev/null || printf '')
fi

[[ -z "$JSONL" ]] && exit 0

nohup "$ARCHIVE_SH" --single "$JSONL" >/dev/null 2>&1 &
exit 0
