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

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERIFY="$HERE/ci-verify.sh"

# Pick a JSON CLI — prefer jaq, fall back to jq. No CLI means fail-open.
if command -v jaq >/dev/null 2>&1; then
  JQ=jaq
elif command -v jq >/dev/null 2>&1; then
  JQ=jq
else
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

[[ -x "$VERIFY" ]] || exit 0

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
  *)
    exit 0
    ;;
esac
