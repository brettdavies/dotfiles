#!/usr/bin/env bash
# test-cost-guard.sh - Fail on a bats test that costs more than it has to.
#
# Usage:
#   test-cost-guard.sh [FILE...]               the setup() check
#   test-cost-guard.sh --report XML FILE...    the time check, on a bats junit report
#
# scripts/run-tests runs both: the setup() check over the suites it runs, and
# the time check after each bats run.
#
# setup() runs before every test, so work it does alike for every test belongs
# in setup_file(), done once and then copied or shared. A repository built per
# test costs about 0.2 s and a hundred processes; `cp -R` of one built once
# costs one process, after rewriting each absolute path the copy holds, such as
# a clone's origin URL. The setup() check flags these at a command's start in
# a tests/*.bats file's setup():
#   git clone, git commit, git push (any -C or -c options between), fixture_repo,
#   and fixture_git <dir> commit or push
# It reads setup() itself, not the helpers setup() calls.
# With FILE arguments it checks those of them that are tests/*.bats; with none it
# checks every tests/*.bats and also fails on an allowlist entry that names a
# file, a test, or a setup() finding that does not exist.
#
# The time check prints `file<TAB>test<TAB>ms<TAB>budget ms` for each passing test
# in the report that took longer than RUN_TESTS_BUDGET_MS (default 3000; 0 turns
# it off) and is not allowlisted; a failing or skipped test already has its
# verdict. FILE... are the files the run was given, which name each test's
# file by its base name.
#
# Allowlist: tests/slow-tests.tsv, one entry per line, `file<TAB>block<TAB>reason`:
# file is the suite's name under tests/, block is a test's name as bats prints it
# or `setup()`, and reason says why it has to cost what it does. Blank lines and
# lines starting with # are ignored.
#
# Exit codes: 0 clean, 1 findings, 2 usage error.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/tests/slow-tests.tsv"
BUDGET_MS=${RUN_TESTS_BUDGET_MS:-3000}

usage() {
  echo "usage: test-cost-guard.sh [FILE...] | --report XML FILE..." >&2
  exit 2
}

declare -A ALLOWED=()
ENTRIES=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z $line || $line == \#* ]] && continue
    IFS=$'\t' read -r file block reason <<<"$line"
    ALLOWED["$file"$'\t'"$block"]=1
    ENTRIES+=("$file"$'\t'"$block"$'\t'"${reason:-}")
  done <"$ALLOWLIST"
fi

# A git command that builds or moves history, or fixture_repo, at a command's start.
GIT_OPTS='([[:space:]]+-[Cc][[:space:]]+[^[:space:];&|)]+)*'
BUILD_RE='(^|[;&|({!]|\$\(|then|do|else)[[:space:]]*(git'"$GIT_OPTS"'[[:space:]]+(clone|commit|push)|fixture_repo|fixture_git[[:space:]]+[^[:space:]]+'"$GIT_OPTS"'[[:space:]]+(commit|push))([[:space:]]|;|$)'

# check_setup FILE: prints each setup() line of FILE that builds a repository.
check_setup() {
  local n=0 line on=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if ((on == 0)); then
      [[ $line =~ ^setup\(\)[[:space:]]*\{ ]] || continue
      on=1
      [[ $line =~ \}[[:space:]]*$ && ! $line =~ ^setup\(\)[[:space:]]*\{[[:space:]]*$ ]] && on=2
    elif [[ $line == '}'* ]]; then
      break
    fi
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ $BUILD_RE ]] && printf '%s:%d: %s\n' "$1" "$n" "${line#"${line%%[![:space:]]*}"}"
    ((on == 2)) && break
  done <"$1"
  return 0
}

# test_names FILE: prints each @test name in FILE as bats prints it.
test_names() {
  local line name
  while IFS= read -r line; do
    [[ $line =~ ^@test[[:space:]]+\"(.*)\"[[:space:]]*\{ ]] || continue
    name=${BASH_REMATCH[1]}
    name=${name//\\\"/\"}
    name=${name//\\\$/\$}
    name=${name//\\\`/\`}
    printf '%s\n' "${name//\\\\/\\}"
  done <"$1"
}

# static_check FILE...: run from REPO_ROOT.
static_check() {
  local file found status=0
  for file in "$@"; do
    [[ $file == tests/*.bats && $file != tests/*/* && -f $file ]] || continue
    [ -z "${ALLOWED["${file#tests/}"$'\t'"setup()"]:-}" ] || continue
    found=$(check_setup "$file")
    [ -n "$found" ] || continue
    printf '%s\n' "$found"
    status=1
  done
  if ((status)); then
    echo "test-cost-guard: setup() runs before every test; build the repository once in setup_file()," >&2
    echo "  copy it per test, and rewrite the absolute paths the copy holds, or allowlist the file's" >&2
    echo "  setup() in tests/slow-tests.tsv with the reason it cannot be shared" >&2
  fi
  return "$status"
}

stale_entries() {
  local entry file block reason status=0
  for entry in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    IFS=$'\t' read -r file block reason <<<"$entry"
    if [ -z "$reason" ]; then
      echo "test-cost-guard: tests/slow-tests.tsv: $file: $block: no reason given" >&2
      status=1
    elif [ ! -f "tests/$file" ]; then
      echo "test-cost-guard: tests/slow-tests.tsv: $file: no such suite" >&2
      status=1
    elif [ "$block" = 'setup()' ]; then
      [ -n "$(check_setup "tests/$file")" ] || {
        echo "test-cost-guard: tests/slow-tests.tsv: $file: setup() builds no repository; drop the entry" >&2
        status=1
      }
    elif [[ $'\n'$(test_names "tests/$file")$'\n' != *$'\n'"$block"$'\n'* ]]; then
      echo "test-cost-guard: tests/slow-tests.tsv: $file: no test named \"$block\"" >&2
      status=1
    fi
  done
  return "$status"
}

# over_budget CLASS NAME SECONDS FILE...: prints the test when it passed over the
# budget and is not allowlisted, and returns 1; returns 0 otherwise.
over_budget() {
  local class=$1 name=$2 t=$3 int frac ms file f
  shift 3
  int=${t%%.*} frac=
  [[ $t == *.* ]] && frac=${t#*.}
  frac="${frac}000"
  ms=$((10#$int * 1000 + 10#${frac:0:3}))
  ((ms > 10#$BUDGET_MS)) || return 0
  name=${name//&quot;/\"}
  name=${name//&#39;/\'}
  name=${name//&lt;/<}
  name=${name//&gt;/>}
  name=${name//&amp;/\&}
  [ -z "${ALLOWED["$class"$'\t'"$name"]:-}" ] || return 0
  file=$class
  for f in "$@"; do [ "${f##*/}" != "$class" ] || file=$f; done
  printf '%s\t%s\t%s\t%s\n' "$file" "$name" "$ms" "$((10#$BUDGET_MS))"
  return 1
}

# report_check XML FILE...
#
# bats closes a passing test's <testcase> on its own line when the test printed
# nothing; a passing test that wrote to fd 3 or kept its output gets a
# <system-out> or <system-err> element first, and is still checked. A
# <failure> or <skipped> element marks a test that has its verdict.
report_check() {
  local xml=$1 line status=0 open=()
  shift
  [[ $BUDGET_MS =~ ^[0-9]+$ ]] || {
    echo "test-cost-guard: RUN_TESTS_BUDGET_MS takes a whole number of milliseconds, got '$BUDGET_MS'" >&2
    exit 2
  }
  ((10#$BUDGET_MS > 0)) || return 0
  [ -f "$xml" ] || {
    echo "test-cost-guard: no bats report at $xml" >&2
    exit 2
  }
  local re='<testcase classname="([^"]*)" name="([^"]*)" time="([0-9.]+)"'
  while IFS= read -r line; do
    if [[ $line =~ $re\ /\>$ ]]; then
      over_budget "${BASH_REMATCH[@]:1:3}" "$@" || status=1
    elif [[ $line =~ $re\>$ ]]; then
      open=("${BASH_REMATCH[@]:1:3}")
    elif ((${#open[@]})) && [[ $line =~ ^[[:space:]]*\<(failure|skipped)[[:space:]\>/] ]]; then
      open=()
    elif ((${#open[@]})) && [[ $line =~ ^[[:space:]]*\</testcase\>$ ]]; then
      over_budget "${open[@]}" "$@" || status=1
      open=()
    fi
  done <"$xml"
  return "$status"
}

if [ "${1:-}" = --report ]; then
  [ "$#" -ge 3 ] || usage
  shift
  report_check "$@"
  exit
fi
case "${1:-}" in -*) usage ;; esac
cd "$REPO_ROOT"

if [ "$#" -gt 0 ]; then
  static_check "$@"
  exit
fi
status=0
static_check tests/*.bats || status=1
stale_entries || status=1
exit "$status"
