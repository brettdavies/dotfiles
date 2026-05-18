#!/usr/bin/env bash
# PreToolUse hook: intercept WebFetch, redirect to defuddle for HTML pages.
# Registered in settings.json as PreToolUse matcher for "WebFetch".
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# permissionDecision: "deny" requires WebFetch NOT be in permissions.allow (Issue #18312).
set -euo pipefail

# Read hook input from fd 0.
#
# Do NOT use `$(</dev/stdin)`. Claude Code's hook runner spawns this script with
# fd 0 connected via a pipe in a way where `open("/dev/stdin")` returns ENXIO
# ("No such device or address"). `cat` reads fd 0 directly via read(2) without
# opening /dev/stdin, so it works in every context where bash's `</dev/stdin`
# works and also in the hook-runner context where the latter fails.
INPUT=$(cat)

# Guard: jaq required for JSON parsing
command -v jaq >/dev/null 2>&1 || exit 0

# Extract URL (confirmed field: tool_input.url, lowercase)
URL=$(printf '%s' "$INPUT" | jaq -r '.tool_input.url // ""')
[[ -z "$URL" ]] && exit 0
[[ "$URL" != http://* && "$URL" != https://* ]] && exit 0

# Skip known non-HTML extensions (portable lowercase via tr)
EXT="${URL##*.}"
EXT="${EXT%%[?#]*}"
EXT=$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')
case "$EXT" in
  pdf|json|xml|csv|png|jpg|jpeg|gif|svg|webp|zip|tar|gz|mp3|mp4|wasm) exit 0 ;;
esac

# Skip localhost, private IPs (RFC 1918), .local domains
case "$URL" in
  *://localhost[:/]*|*://localhost) exit 0 ;;
  *://127.0.0.1*|*://0.0.0.0*|*://\[::1\]*) exit 0 ;;
  *://10.*|*://172.1[6-9].*|*://172.2[0-9].*|*://172.3[01].*|*://192.168.*) exit 0 ;;
  *://*.local[:/]*|*://*.local) exit 0 ;;
esac

# Marker-based passthrough: each URL gets one defuddle redirect per session.
# Marker means "defuddle was attempted" (not "defuddle failed").
MARKER_DIR="/tmp/.defuddle-markers"
# shellcheck disable=SC2174  # mode applies to the leaf only by design — that's the dir we want 700 on
mkdir -p -m 700 "$MARKER_DIR" 2>/dev/null || true
URL_HASH=$(printf '%s' "$URL" | sha256sum | cut -c1-16)
MARKER="$MARKER_DIR/$URL_HASH"
[[ -f "$MARKER" ]] && exit 0

# Mark URL as attempted
touch "$MARKER"

# Construct deny JSON via jaq for proper escaping (prevents JSON injection from URLs
# containing quotes, backslashes, or newlines). Both permissionDecisionReason and
# systemMessage are set for reliable delivery (Issue #12446).
# shellcheck disable=SC2016  # jaq filter uses single quotes; $url and $msg are jaq variables, not shell
jaq -n --arg url "$URL" '
  ("WebFetch intercepted. Use `defuddle parse " + $url + " --md` via Bash for clean markdown. If defuddle fails or returns empty, retry with WebFetch — the hook will allow the retry. If this content is worth saving, clip it with ~/.claude/skills/clip/scripts/clip.sh " + $url + ".") as $msg |
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $msg
    },
    systemMessage: $msg
  }'
