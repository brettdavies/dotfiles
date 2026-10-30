#!/usr/bin/env bash
# PreToolUse hook: intercept WebFetch, redirect to defuddle for HTML pages.
# Registered in settings.json as PreToolUse matcher for "WebFetch".
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# Exit 2 + JSON deny when the call cannot be checked: no JSON parser on PATH,
# or a failure inside this script.
# The deny holds even for a URL that permissions.allow approves.
set -euo pipefail

readonly GUARD=defuddle-webfetch

# The deny is built from text already escaped for JSON, the guard's name, and a
# line number, so it needs no parser. Exit 2 blocks the call even where the
# harness does not read the JSON.
block() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s %s"},"systemMessage":"%s %s"}\n' \
    "$GUARD" "$1" "$GUARD" "$2"
  exit 2
}
trap 'block "failed [guard-internal-error] at line $LINENO, so this call did not run.\nnext_step [ask-user]: tell the user; bats tests/$GUARD.bats in the dotfiles repo shows what broke." "failed at line $LINENO and blocked the call"' ERR

# Read hook input from fd 0.
#
# Do NOT use `$(</dev/stdin)`. Claude Code's hook runner spawns this script with
# fd 0 connected via a pipe in a way where `open("/dev/stdin")` returns ENXIO
# ("No such device or address"). `cat` reads fd 0 directly via read(2) without
# opening /dev/stdin, so it works in every context where bash's `</dev/stdin`
# works and also in the hook-runner context where the latter fails.
INPUT=$(cat)

JQ=$(command -v jaq || command -v jq) \
  || block 'blocked [json-parser-missing]: neither jaq nor jq is on PATH, so this call could not be checked. It did not run; install jaq, then rerun it.\ndocs: ~/dotfiles/BOOTSTRAP.md § \"Install Packages from Brewfile\"\nnext_step [install-jaq]:\nbrew install jaq' \
    'blocked the call: neither jaq nor jq is installed (brew install jaq)'

# Extract URL (confirmed field: tool_input.url, lowercase)
URL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.url // ""')
[[ -z "$URL" ]] && exit 0
[[ "$URL" != http://* && "$URL" != https://* ]] && exit 0

# Skip known non-HTML extensions (portable lowercase via tr)
EXT="${URL##*.}"
EXT="${EXT%%[?#]*}"
EXT=$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')
case "$EXT" in
  pdf | json | xml | csv | png | jpg | jpeg | gif | svg | webp | zip | tar | gz | mp3 | mp4 | wasm) exit 0 ;;
esac

# Skip localhost, private IPs (RFC 1918), .local domains
case "$URL" in
  *://localhost[:/]* | *://localhost) exit 0 ;;
  *://127.0.0.1* | *://0.0.0.0* | *://\[::1\]*) exit 0 ;;
  *://10.* | *://172.1[6-9].* | *://172.2[0-9].* | *://172.3[01].* | *://192.168.*) exit 0 ;;
  *://*.local[:/]* | *://*.local) exit 0 ;;
esac

# Marker-based passthrough: each URL gets one defuddle redirect per session.
# Marker means "defuddle was attempted" (not "defuddle failed").
MARKER_DIR="${DEFUDDLE_MARKER_DIR:-/tmp/.defuddle-markers}"
# shellcheck disable=SC2174  # mode applies to the leaf only by design — that's the dir we want 700 on
mkdir -p -m 700 "$MARKER_DIR" 2>/dev/null || true
# cksum is POSIX, so this runs on macOS, where sha256sum ships only as
# Homebrew coreutils' gsha256sum.
URL_HASH=$(printf '%s' "$URL" | cksum | cut -d ' ' -f 1)
MARKER="$MARKER_DIR/$URL_HASH"
[[ -f "$MARKER" ]] && exit 0

# Mark URL as attempted
touch "$MARKER"

# Construct deny JSON via jaq for proper escaping (prevents JSON injection from URLs
# containing quotes, backslashes, or newlines). Both permissionDecisionReason and
# systemMessage are set for reliable delivery (Issue #12446).
# shellcheck disable=SC2016  # jaq filter uses single quotes; $url and $msg are jaq variables, not shell
"$JQ" -n --arg url "$URL" '
  ("WebFetch intercepted. Use `defuddle parse " + $url + " --md` via Bash for clean markdown. If defuddle fails or returns empty, retry with WebFetch — the hook will allow the retry. If this content is worth saving, clip it with ~/.claude/skills/clip/scripts/clip.sh " + $url + ".") as $msg |
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $msg
    },
    systemMessage: $msg
  }'
