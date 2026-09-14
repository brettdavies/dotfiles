#!/usr/bin/env bash
# Shared bash utilities for the release-(pre|post)flight orchestrators and any
# project-authored surface-smoke suite that wants to participate in the
# orchestrator's PASS/FAIL/SKIP accounting. Source via:
#
#   . "$(dirname "$0")/_lib.sh"
#
# Provides:
#   - Color helpers (C_RED, C_GRN, C_YLW, C_RST, C_BLD), empty when stdout is
#     not a TTY, so output is clean in CI logs.
#   - Gate counters (PASS_COUNT, FAIL_COUNT, SKIP_COUNT) and emitters
#     (gate_pass, gate_fail, gate_skip).
#   - Section header helper.
#   - Dependency checks (require_bin, have_bin).
#   - 1Password helper (read_1p) routing through the brettdavies 1password skill.
#   - Final summary printer (print_summary).
#   - Sub-script delegation (delegate_to_subscript) for surface-smoke aggregation.
#
# Idempotent: safe to source multiple times. Re-sourcing is a no-op so the
# `readonly` declarations on color constants don't fail.

if [[ -n "${_RELEASE_LIB_SOURCED:-}" ]]; then
  return 0
fi
_RELEASE_LIB_SOURCED=1

# Require bash >= 4.4: associative arrays, mapfile, and safe empty-array
# expansion under `set -u`. Sourced, so return (not exit) to avoid killing an
# interactive shell; the sourcing script aborts on the non-zero return.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'error: bash >= 4.4 required, but this is bash %s.\n' "${BASH_VERSION:-unknown}" >&2
  printf 'Install a newer bash: brew install bash\n' >&2
  # shellcheck disable=SC2317  # `exit` runs only when executed rather than sourced
  return 1 2>/dev/null || exit 1
fi

# Color helpers --------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YLW=$'\033[33m'
  C_RST=$'\033[0m'
  C_BLD=$'\033[1m'
else
  C_RED='' C_GRN='' C_YLW='' C_RST='' C_BLD=''
fi
readonly C_RED C_GRN C_YLW C_RST C_BLD

# Gate counters and emitters -------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

gate_pass() {
  printf "  %s✓%s %s\n" "$C_GRN" "$C_RST" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}
gate_fail() {
  printf "  %s✗%s %s\n    %s\n" "$C_RED" "$C_RST" "$1" "${2:-}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}
gate_skip() {
  printf "  %s⊝%s %s: %s\n" "$C_YLW" "$C_RST" "$1" "${2:-not yet ready}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}
header() { printf "\n%s== %s ==%s\n" "$C_BLD" "$1" "$C_RST"; }

# Dependency checks ----------------------------------------------------------

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 2
  }
}

have_bin() {
  command -v "$1" >/dev/null 2>&1
}

# 1Password helpers (read-only) ----------------------------------------------
#
# Reads from the secrets-dev vault via the 1password skill's read_field.sh. The
# skill enforces --vault secrets-dev and the brettdavies naming/tagging
# conventions; calling `op read` directly would bypass those. Set
# OP_SERVICE_ACCOUNT_TOKEN in the environment (or use a service-account-bound
# shell) before invoking. Returns empty string if the skill isn't installed or
# the field doesn't exist; callers gate on `[[ -n "$value" ]]` and SKIP cleanly.
#
# Example: dev_bearer=$(read_1p "<APP-NAME>" credential)

readonly OP_SKILL="${OP_SKILL:-$HOME/.claude/skills/1password/scripts}"

read_1p() {
  [[ -x "$OP_SKILL/read_field.sh" ]] || return 1
  "$OP_SKILL/read_field.sh" "$1" "$2" 2>/dev/null
}

# Final summary --------------------------------------------------------------
#
# Callers that suppress (sub-scripts invoked with --result-file by the
# delegate_to_subscript helper) write counters to the result file instead and
# skip the colored summary line.

print_summary() {
  printf "\n%sSummary:%s  %s%d passed%s  %s%d failed%s  %s%d skipped%s\n" \
    "$C_BLD" "$C_RST" "$C_GRN" "$PASS_COUNT" "$C_RST" \
    "$C_RED" "$FAIL_COUNT" "$C_RST" "$C_YLW" "$SKIP_COUNT" "$C_RST"
}

# Sub-script delegation ------------------------------------------------------
#
# Runs a sub-script with --result-file pointing at a tmp file and aggregates
# its PASS/FAIL/SKIP counters into the parent's. The sub-script must accept
# --result-file PATH and write three space-separated integers to PATH at exit.
# A sub-script using this contract sources _lib.sh, runs its gates, and ends
# with:
#
#   if [[ -n "$RESULT_FILE" ]]; then
#       printf "%d %d %d\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" > "$RESULT_FILE"
#   else
#       print_summary
#   fi
#
# Exit codes from the sub-script are not propagated; the parent decides
# pass/fail based on its own aggregated counters after every gate runs.
#
# Usage:
#   delegate_to_subscript <script> <args...>

delegate_to_subscript() {
  local script="$1"
  shift
  local result_file
  result_file=$(mktemp)
  "$script" "$@" --result-file "$result_file" || true
  if [[ -s "$result_file" ]]; then
    local p f s
    read -r p f s <"$result_file"
    PASS_COUNT=$((PASS_COUNT + p))
    FAIL_COUNT=$((FAIL_COUNT + f))
    SKIP_COUNT=$((SKIP_COUNT + s))
  fi
  rm -f "$result_file"
}

# SMOKE_HOME seeding ---------------------------------------------------------
#
# Smoke gates that exercise the project's CLI against a live external service
# need an isolated $HOME so the dev machine's real config / token store is
# never touched. `shred -u` overwrites bytes before unlinking the tempdir on
# exit (closes the exfil window for cred recovery off the FS, backups, or the
# trash bin). Refuses to operate outside /tmp or $HOME as a path-typo guardrail
# (mirrors the 1Password skill's stage_secret.sh contract).
#
# Callers source _lib.sh, set SMOKE_HOME via mktemp inside their seed function,
# and the EXIT trap handles cleanup. Set NO_CLEANUP=1 to skip the shred (useful
# for debugging the seeded state after a failed gate).

SMOKE_HOME="${SMOKE_HOME:-}"
NO_CLEANUP="${NO_CLEANUP:-0}"

shred_tmpdir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case "$dir" in
    /tmp/* | "$HOME"/*) ;;
    *)
      echo "refusing to shred outside /tmp or \$HOME: $dir" >&2
      return 1
      ;;
  esac
  if command -v shred >/dev/null 2>&1; then
    find "$dir" -type f -exec shred -u {} + 2>/dev/null || true
  else
    find "$dir" -type f -exec sh -c 'dd if=/dev/urandom of="$1" bs=1 count=$(stat -c%s "$1") conv=notrunc 2>/dev/null; rm -f "$1"' _ {} \;
  fi
  find "$dir" -depth -type d -exec rmdir {} + 2>/dev/null || true
}

cleanup_smoke() {
  [[ "$NO_CLEANUP" -eq 0 && -n "$SMOKE_HOME" && -d "$SMOKE_HOME" ]] || return 0
  shred_tmpdir "$SMOKE_HOME"
}
