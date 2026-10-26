#!/usr/bin/env bats
# Tests for scripts/fseventsd-check.sh, which warns when macOS fseventsd has grown far past the memory budget launchd
# gives it.
#
# Run: bats tests/fseventsd-check.bats
#
# Every command the script reads the daemon through is a stub in a PATH-prepended directory: `uname` (so Linux CI
# passes the Darwin gate), `pgrep` (STUB_NO_DAEMON makes it find nothing), `ps` (prints STUB_RSS_KB the way
# `ps -o rss=` does), and `launchctl` (prints the jetsam lines of `launchctl print` with STUB_BUDGET_MB, or fails when
# STUB_NO_BUDGET is set). Nothing reads the host's real fseventsd.

bats_require_minimum_version 1.5.0

CHECK="$BATS_TEST_DIRNAME/../scripts/fseventsd-check.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  stub uname 'echo "${STUB_UNAME:-Darwin}"'
  stub pgrep '[ -z "${STUB_NO_DAEMON-}" ] || exit 1
    echo 106'
  stub ps 'printf "%6s\n" "$STUB_RSS_KB"'
  stub launchctl '[ -z "${STUB_NO_BUDGET-}" ] || { echo "Could not find service" >&2; exit 113; }
    printf "\tjetsam priority = 40\n\tjetsam memory limit (active, soft) = %s MB\n\tjetsam memory limit (inactive, soft) = %s MB\n" \
      "${STUB_BUDGET_MB:-30}" "${STUB_BUDGET_MB:-30}"'
  PATH="$STUBS:$PATH"
}

# stub NAME BODY: an executable NAME running BODY.
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

@test "a daemon within its budget prints nothing" {
  STUB_RSS_KB=9792 run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a runaway daemon gets one warning naming its size, its budget, and the fix" {
  STUB_RSS_KB=2307072 run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == "WARNING: fseventsd "* ]]
  [[ "$stderr" == *"2253 MB"* ]]
  [[ "$stderr" == *"30 MB"* ]]
  [[ "$stderr" == *"sudo killall fseventsd"* ]]
}

@test "the warning starts above ten times the budget" {
  STUB_RSS_KB=$((299 * 1024)) run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  STUB_RSS_KB=$((301 * 1024)) run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"301 MB"* ]]
}

@test "the threshold follows the budget launchd reports" {
  STUB_BUDGET_MB=60 STUB_RSS_KB=$((500 * 1024)) run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  STUB_BUDGET_MB=60 STUB_RSS_KB=$((700 * 1024)) run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"60 MB"* ]]
}

@test "a budget launchctl cannot report falls back to 30 MB" {
  STUB_NO_BUDGET=1 STUB_RSS_KB=$((400 * 1024)) run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"400 MB"* ]]
  [[ "$stderr" == *"30 MB"* ]]
}

@test "no running fseventsd prints nothing" {
  STUB_NO_DAEMON=1 STUB_RSS_KB=2307072 run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a host other than macOS prints nothing" {
  STUB_UNAME=Linux STUB_RSS_KB=2307072 run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "as a Claude Code hook, a runaway daemon's warning goes to both the user and Claude as SessionStart JSON" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  STUB_RSS_KB=2307072 run --separate-stderr "$CHECK" --claude-hook
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  warning=$(jaq -r '.systemMessage' <<<"$output")
  [[ "$warning" == "WARNING: fseventsd holds 2253 MB against its 30 MB launchd budget; reset it with: sudo killall fseventsd" ]]
  [ "$(jaq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = SessionStart ]
  [ "$(jaq -r '.hookSpecificOutput.additionalContext' <<<"$output")" = "$warning" ]
}

@test "as a Claude Code hook, a daemon within its budget prints nothing" {
  STUB_RSS_KB=9792 run --separate-stderr "$CHECK" --claude-hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an unknown argument is refused" {
  STUB_RSS_KB=9792 run --separate-stderr "$CHECK" --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == "ERROR: "*"--bogus"* ]]
}
