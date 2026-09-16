# shellcheck shell=bash
# Shared reporting and scheduling helpers for the local gates.
#
# Sourced by .githooks/pre-commit and .githooks/pre-push so both speak with one
# voice: a step either passes, is skipped with an actionable install hint, or
# fails and stops the gate. Both hooks also schedule their gates through the
# same gate_begin/gate_spawn/gate_collect trio, so the two cannot drift into
# different execution models — only their target lists differ.
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

# Gates that do not read each other's output run together, so the slowest one
# sets the wall-clock instead of the sum. Each buffers its own stream and
# records its own status; gate_collect replays them in a fixed order, so the
# report reads the same regardless of which gate finished first.
GATE_OUT=''

gate_begin() {
  GATE_OUT="$(mktemp -d)"
  # gate_fail exits, so cleanup hangs off EXIT rather than the happy path.
  trap 'gate_end' EXIT
}

gate_end() {
  [ -n "$GATE_OUT" ] && rm -rf "$GATE_OUT"
  GATE_OUT=''
  return 0
}

# gate_spawn <name> <command>...
gate_spawn() {
  local name=$1
  shift
  # errexit is off inside the job so a failing gate still records its status;
  # without this the job dies at the failure and leaves no status file, which
  # would read as a missing result rather than a failed gate.
  {
    set +e
    "$@" >"$GATE_OUT/$name.out" 2>&1
    printf '%s' "$?" >"$GATE_OUT/$name.rc"
  } &
}

# gate_collect <name> <label> <failure-message>
gate_collect() {
  local name=$1 label=$2 failure=$3 rc
  rc="$(cat "$GATE_OUT/$name.rc" 2>/dev/null || true)"
  if [ -s "$GATE_OUT/$name.out" ]; then
    cat "$GATE_OUT/$name.out"
  fi
  [ "$rc" = "0" ] || gate_fail "$failure"
  gate_pass "$label"
}
