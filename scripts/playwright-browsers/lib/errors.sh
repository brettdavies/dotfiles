# Diagnostics for the browser-set scripts: stderr only, a severity prefix, a
# stable reason from the runbook's reason table, what changed, and a command
# that runs verbatim from a headless shell.

# The tilde stays literal: %q would escape it, and the script lives at the
# same checkout path on every host.
# shellcheck disable=SC2088
PW_DEPLOY='~/dotfiles/scripts/playwright-browsers-deploy.sh'
PW_FAILED=0

# Every character outside letters, digits, ".", "_", "-" and space becomes "?",
# so a value read from a file cannot forge the reason or next step on the line
# that reports it.
pw_mask() {
  local LC_ALL=C v="$1"
  v=${v//[^A-Za-z0-9._ -]/?}
  printf '%s' "${v:0:80}"
}

# pw_report SEVERITY MESSAGE REASON EFFECT NEXT [VALUE]
pw_report() {
  local value=""
  [ "$#" -ge 6 ] && value="; value: $(pw_mask "$6")"
  printf '%s: %s; reason: %s%s; %s; next: %s\n' "$1" "$2" "$3" "$value" "$4" "$5" >&2
}

pw_fail() {
  pw_report ERROR "$@"
  exit 1
}

pw_usage() {
  pw_report ERROR "$@"
  exit 2
}

# --check fails at the end. It prints the first PW_SHOWN findings of each reason
# and counts the rest, so a host with nothing deployed gets a page, not a wall.
PW_SHOWN=5
declare -A PW_COUNT=()
pw_finding() {
  PW_FAILED=1
  PW_COUNT[$2]=$((${PW_COUNT[$2]:-0} + 1))
  [ "${PW_COUNT[$2]}" -gt "$PW_SHOWN" ] || pw_report ERROR "$@"
}

pw_finding_tail() {
  local r n
  for r in "${!PW_COUNT[@]}"; do
    n=${PW_COUNT[$r]}
    [ "$n" -le "$PW_SHOWN" ] || pw_note "$((n - PW_SHOWN)) more findings with reason $r"
  done
}

pw_note() {
  printf 'NOTE: %s\n' "$*" >&2
}

pw_unexpected() {
  pw_report ERROR "a step failed unexpectedly; the failing tool's own message is above" \
    unexpected-failure "the set may be partly updated and a rerun finishes it" "$PW_DEPLOY"
  exit 1
}
