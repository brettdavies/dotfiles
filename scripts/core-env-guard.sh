#!/usr/bin/env bash
# core-env-guard.sh - Fail when a test resets a core environment variable.
#
# Usage:
#   core-env-guard.sh [--allowlist FILE] [FILE...]
#
# A test that reassigns HOME (or USER, TMPDIR, an XDG_* directory, a tool home
# such as CARGO_HOME, or the whole value of PATH) points every process it starts
# at a fabricated environment. The test stops exercising the seam the code
# really uses, and a bug that leaves the variable pointing somewhere unintended
# reads or writes live state. Isolate through a variable the script or tool
# supports instead: an override the script honors, GIT_CONFIG_GLOBAL for git, a
# path flag. Prepending a directory to PATH ("$dir:$PATH") extends it and passes.
#
# With FILE arguments the guard scans those files, ignoring any that are not
# test files; the pre-commit hook passes the staged set. With none it scans
# every tracked test file and also fails on allowlist entries that no longer
# match a finding.
#
# Test files: *.bats, *.bash, and *.sh under a tests/ or test/ directory.
#
# Flagged when the assignment starts a command (line start; after ; & | ( { or
# $(; after export, env, local, declare, readonly, or typeset; after another
# assignment; or opening a `bash -c` script), comment lines and @test headers
# excepted:
#   VAR=...     for VAR in HOME USER LOGNAME TMPDIR SHELL ZDOTDIR GNUPGHOME
#               CARGO_HOME RUSTUP_HOME XDG_*
#   PATH=...    unless the rest of the line refers back to $PATH
#   unset VAR   env -u VAR   env -i
#
# Allowlist: one tab-separated entry per line, `path<TAB>block<TAB>reason`,
# where block is the enclosing @test name or function name, or `-` for top-level
# code. An entry allows every finding in that block. Blank lines and lines
# starting with # are ignored. Default: core-env-allowlist.tsv beside this
# script, where a missing file is an empty allowlist; a path passed with
# --allowlist must exist.
#
# Exit codes: 0 clean, 1 findings or stale allowlist entries, 2 usage error.

set -euo pipefail

allowlist="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core-env-allowlist.tsv"
explicit=0

usage() {
  echo "usage: core-env-guard.sh [--allowlist FILE] [FILE...]" >&2
  exit 2
}

files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowlist)
      [[ $# -ge 2 ]] || usage
      allowlist="$2"
      explicit=1
      shift 2
      ;;
    --)
      shift
      files+=("$@")
      break
      ;;
    -*) usage ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

sweep=0
if [[ ${#files[@]} -eq 0 ]]; then
  sweep=1
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "core-env-guard: not inside a git work tree" >&2
    exit 2
  }
  cd "$root"
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(git ls-files -z)
fi

tests=()
for f in "${files[@]}"; do
  f="${f#./}"
  [[ -f "$f" ]] || continue
  case "$f" in
    *.bats | *.bash | tests/*.sh | test/*.sh | */tests/*.sh | */test/*.sh) tests+=("$f") ;;
  esac
done

# The hint names the allowlist to edit even before the file exists.
allowlist_name="$allowlist"
if [[ ! -e "$allowlist" ]]; then
  if [[ $explicit -eq 1 ]]; then
    echo "core-env-guard: allowlist not found: $allowlist" >&2
    exit 2
  fi
  allowlist=/dev/null
fi

# The awk program reads the allowlist in BEGIN, then every test file. Each
# finding is keyed by path and enclosing block; the END block prints the
# findings no entry allows and, on a sweep, the entries nothing matched.
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose
prog='
BEGIN {
  vars = "(HOME|USER|LOGNAME|TMPDIR|SHELL|ZDOTDIR|GNUPGHOME|CARGO_HOME|RUSTUP_HOME|XDG_[A-Z_]+)"
  assign = "[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|\047[^\047]*\047|[^[:space:]\"\047;&|]*)"
  shell_c = "(^|[[:space:]/;&|(])(sh|bash|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+[\"\047]"
  keyword = "(^|[[:space:]])(export|env|local|declare|readonly|typeset)([[:space:]]+-[A-Za-z]+)*"
  lead = "(^|[;&|({`]|\\$\\(|" keyword "|" shell_c ")"
  pos = lead "[[:space:]]*(" assign "[[:space:]]+)*"
  core_re = pos vars "="
  path_re = pos "PATH="
  edge = "(^|[;&|({`[:space:]\"\047])"
  unset_re = edge "unset[[:space:]]+(-[A-Za-z]+[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)*" vars "([^A-Za-z0-9_]|$)"
  env_u_re = edge "env[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-u[[:space:]]*" vars "([^A-Za-z0-9_]|$)"
  env_i_re = edge "env[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-[A-Za-z]*i|--ignore-environment)([[:space:]]|$)"
  findings = 0
  while ((status = (getline line < allowlist_path)) > 0) {
    lineno++
    if (line ~ /^[[:space:]]*(#|$)/) continue
    n = split(line, f, "\t")
    if (n < 3 || f[1] == "" || f[2] == "" || f[3] == "") {
      printf "core-env-guard: allowlist line %d needs path, block, and reason, tab-separated\n", lineno > "/dev/stderr"
      bad = 1
      exit 2
    }
    key = f[1] SUBSEP f[2]
    allowed[key] = 1
    entry[++entries] = key
  }
  if (status < 0) {
    printf "core-env-guard: cannot read allowlist %s\n", allowlist_path > "/dev/stderr"
    bad = 1
    exit 2
  }
  close(allowlist_path)
}

FNR == 1 { block = "-" }

/^[[:space:]]*@test[[:space:]]/ {
  name = $0
  if (match(name, "\"[^\"]*\"") || match(name, "\047[^\047]*\047")) block = substr(name, RSTART + 1, RLENGTH - 2)
}
/^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)/ {
  name = $0
  sub(/^[[:space:]]*(function[[:space:]]+)?/, "", name)
  sub(/[[:space:]]*\(\).*/, "", name)
  block = name
}

$0 !~ /^[[:space:]]*(#|@test[[:space:]])/ {
  what = ""
  if (match($0, core_re)) {
    hit = substr($0, RSTART, RLENGTH)
    sub(/=$/, "", hit)
    match(hit, /[A-Z_]+$/)
    what = substr(hit, RSTART, RLENGTH)
  } else if (match($0, path_re) && substr($0, RSTART + RLENGTH) !~ /\$\{?PATH([^A-Za-z0-9_]|$)/) {
    what = "PATH"
  } else if ($0 ~ unset_re) {
    what = "unset"
  } else if ($0 ~ env_u_re) {
    what = "env -u"
  } else if ($0 ~ env_i_re) {
    what = "env -i"
  }
  if (what != "") {
    key = FILENAME SUBSEP block
    used[key] = 1
    if (!(key in allowed)) {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      report[++findings] = sprintf("  %s:%d [%s] %s: %s", FILENAME, FNR, block, what, text)
    }
  }
}

/^}/ { block = "-" }

END {
  if (bad) exit 2
  status = 0
  if (findings > 0) {
    print "core-env-guard: tests reset a core environment variable:"
    for (i = 1; i <= findings; i++) print report[i]
    print ""
    print "Isolate through a variable the script or tool supports instead (an override"
    print "the script honors, GIT_CONFIG_GLOBAL for git, a path flag), or allowlist the"
    printf "block in %s with the reason.\n", allowlist_name
    status = 1
  }
  if (sweep) {
    stale = 0
    for (i = 1; i <= entries; i++) if (!(entry[i] in used)) stale++
    if (stale > 0) {
      print "core-env-guard: allowlist entries match no finding:"
      for (i = 1; i <= entries; i++) if (!(entry[i] in used)) {
        split(entry[i], k, SUBSEP)
        printf "  %s [%s]\n", k[1], k[2]
      }
      status = 1
    }
  }
  if (status == 0) printf "core-env-guard: %d test file(s) clean\n", files
  exit status
}
'

# With no test files, /dev/null keeps awk off stdin while the allowlist is
# still read: a malformed one fails, and a sweep reports every entry as stale.
count=${#tests[@]}
[[ $count -gt 0 ]] || tests=(/dev/null)
awk -v sweep="$sweep" -v files="$count" -v allowlist_path="$allowlist" -v allowlist_name="$allowlist_name" \
  "$prog" "${tests[@]}"
