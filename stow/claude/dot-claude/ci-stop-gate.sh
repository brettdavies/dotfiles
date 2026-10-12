#!/usr/bin/env bash
# ci-stop-gate.sh — Stop hook. Refuse the turn while CI for the current
# branch's latest pushed commit is red or still running.
#
# Snapshot only (--fast): it does not wait. The agent runs ci-verify.sh to
# wait. Empty repo, unpushed HEAD, and no CI are a pass-through.
#
# Loop guard: when stop_hook_active is true this hook allows the stop so a
# blocked turn cannot retry the hook forever. Escape hatch for a human:
# CI_VERIFY_ALLOW_STOP=1 (or true / yes).
#
# Missing gh/jq (or ci-verify itself): warn-and-allow. Exit 0, no
# decision:block. The WARNING is emitted on hookSpecificOutput.additionalContext
# so the transcript shows that CI was NOT verified.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERIFY="$HERE/ci-verify.sh"
JQ=""

# Emit a non-blocking Stop WARNING. additionalContext is the harness channel
# that stays visible without decision:block (which would refuse the turn).
# Args: $1 message
ci_stop::warn() {
  local msg=$1
  echo "$msg" >&2
  if [[ -n "$JQ" ]]; then
    # shellcheck disable=SC2016  # jq program; $ctx is an --arg binding
    "$JQ" -n --arg ctx "$msg" '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: $ctx
      }
    }'
    return 0
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"WARNING: jq (or jaq) is not on PATH. CI was NOT verified."}}'
}

if command -v jaq >/dev/null 2>&1; then
  JQ=jaq
elif command -v jq >/dev/null 2>&1; then
  JQ=jq
else
  ci_stop::warn "WARNING: jq (or jaq) is not on PATH. CI was NOT verified."
  exit 0
fi

payload=$(cat || true)
[[ -n "$payload" ]] || payload='{}'
stop_active=$("$JQ" -r '.stop_hook_active // false' <<<"$payload" 2>/dev/null || true)
: "${stop_active:=false}"
case "$(printf '%s' "${CI_VERIFY_ALLOW_STOP:-0}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes)
    exit 0
    ;;
esac
if [[ "$stop_active" == "true" ]]; then
  exit 0
fi

if [[ ! -x "$VERIFY" ]]; then
  ci_stop::warn "WARNING: ${VERIFY} is not executable. CI was NOT verified."
  exit 0
fi

set +e
out=$(CI_VERIFY_FAST=1 "$VERIFY" --fast 2>&1)
rc=$?
set -e

case "$rc" in
  1 | 2)
    reason=$out
    reason+=$'\n\n'
    reason+="Run ~/.claude/ci-verify.sh and fix any red check before ending the turn."
    reason+=$'\n'
    reason+="Escape hatch (human only): CI_VERIFY_ALLOW_STOP=1"
    # shellcheck disable=SC2016  # jq program; $reason is an --arg binding
    "$JQ" -n --arg reason "$reason" '{decision:"block", reason:$reason}'
    exit 0
    ;;
  4)
    [[ -n "$out" ]] || out="WARNING: ci-verify could not verify CI. CI was NOT verified."
    ci_stop::warn "$out"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
