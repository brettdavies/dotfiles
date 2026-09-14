#!/usr/bin/env bats
# Shell startup latency budgets.
#
# Lives outside tests/*.bats on purpose. The pre-push hook and the bats workflow
# both glob one level deep, so these do not run in the middle of the ~330-test
# suite, where several hundred spawned shells make the machine slow enough to
# push interactive zsh past its budget while nothing about the config changed.
# The hook runs this directory first, on a quiet machine.
#
# Every measurement is a best-of-N minimum rather than a single sample. Startup
# latency has a hard floor and a long right tail: the minimum estimates the floor
# and is stable, while the mean tracks whatever else the machine was doing.
#
# Run: bats tests/perf/

# Budgets sit well clear of the measured floor so ordinary machine noise does
# not block a push, while still catching a real regression. Floors on the
# development machine, best of 15 at rest:
#
#   non-interactive zsh   133ms      non-interactive bash   11ms
#   interactive zsh       327ms      interactive bash      144ms
#   login zsh             139ms      login bash            140ms
#
# These run only in .githooks/pre-push, never in CI, so a budget is a local
# ergonomics dial rather than a merge gate.
SAMPLES="${SHELL_PERF_SAMPLES:-9}"

# On a host without the dotfiles deployed these would time a stock shell reading
# no startup files, pass trivially, and report a green that means nothing.
_skip_unless_deployed() {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed (~/.profile not a symlink)"
}

# Wall-clock milliseconds for one invocation.
_measure_once() {
  local start end
  start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time()')
  eval "$1" >/dev/null 2>&1
  end=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time()')
  /usr/bin/perl -e "printf '%.0f', ($end - $start) * 1000"
}

# Fastest of $SAMPLES runs, after one untimed warm-up to page in the shell and
# its startup files. A cold first run measures the filesystem, not the config.
_measure_best_ms() {
  local cmd="$1" best="" ms i
  _measure_once "$cmd" >/dev/null
  for ((i = 0; i < SAMPLES; i++)); do
    ms=$(_measure_once "$cmd")
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then
      best="$ms"
    fi
  done
  printf '%s' "$best"
}

_assert_under() {
  local label="$1" cmd="$2" budget="$3" ms
  _skip_unless_deployed
  ms=$(_measure_best_ms "$cmd")
  echo "# $label: ${ms}ms (best of $SAMPLES, budget ${budget}ms)" >&3
  [ "$ms" -lt "$budget" ] || {
    echo "$label took ${ms}ms at its floor, over the ${budget}ms budget"
    echo "this is the fastest of $SAMPLES runs, so it is not contention"
    false
  }
}

@test "non-interactive zsh starts under 250ms" {
  _assert_under "non-interactive zsh" "zsh -c exit" 250
}

@test "non-interactive bash starts under 200ms" {
  _assert_under "non-interactive bash" "bash -c exit" 200
}

@test "interactive zsh starts under 500ms" {
  _assert_under "interactive zsh" "zsh -i -c exit" 500
}

@test "interactive bash starts under 500ms" {
  _assert_under "interactive bash" "bash -i -c exit" 500
}

@test "login zsh starts under 500ms" {
  _assert_under "login zsh" "zsh -l -c exit" 500
}

@test "login bash starts under 500ms" {
  _assert_under "login bash" "bash -l -c exit" 500
}
