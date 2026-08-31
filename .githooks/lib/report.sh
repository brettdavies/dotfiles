# shellcheck shell=bash
# Shared reporting helpers for the local gates.
#
# Sourced by .githooks/pre-commit and .githooks/pre-push so both speak with one
# voice: a step either passes, is skipped with an actionable install hint, or
# fails and stops the gate.
#
# Colors degrade to empty strings when stdout is not a terminal, so hook output
# stays readable in a log or a CI capture.

if [ -t 1 ]; then
  GATE_RED=$'\033[0;31m'
  GATE_GREEN=$'\033[0;32m'
  GATE_DIM=$'\033[2m'
  GATE_BOLD=$'\033[1m'
  GATE_RESET=$'\033[0m'
else
  GATE_RED='' GATE_GREEN='' GATE_DIM='' GATE_BOLD='' GATE_RESET=''
fi

gate_header() { printf '%s%s%s\n' "$GATE_BOLD" "$1" "$GATE_RESET"; }
gate_pass() { printf '  %s✓%s %s\n' "$GATE_GREEN" "$GATE_RESET" "$1"; }
gate_skip() { printf '  %s- %s%s\n' "$GATE_DIM" "$1" "$GATE_RESET"; }
gate_done() { printf '%s%s%s%s\n' "$GATE_BOLD" "$GATE_GREEN" "$1" "$GATE_RESET"; }

gate_fail() {
  printf '  %s✗%s %s\n' "$GATE_RED" "$GATE_RESET" "$1" >&2
  exit 1
}
