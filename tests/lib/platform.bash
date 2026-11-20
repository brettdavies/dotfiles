# shellcheck shell=bash
# The one place a suite decides or fakes the platform its code runs on.
#
# Production code asks `uname`, so a test fakes the platform by putting
# stub_uname's stub ahead of the real one on PATH, and selects it with
# STUB_UNAME (what `uname -s` prints), STUB_UNAME_R (`uname -r`), and
# STUB_UNAME_M (`uname -m`). Each one left unset, and every other option,
# answers as the real uname does. A suite that sources the code under test may
# define a `uname` function instead, which costs no process.
#
# There is deliberately no gate that skips a whole suite on macOS: CI runs only
# on Linux, so a suite gated to macOS would never run there. Mac-side code is
# tested on Linux through stub_uname, and a test that needs the real macOS (a
# Mac tool, or Apple's own shell setup) skips just itself with require_macos.

# require_linux <why>: skip unless the host is Linux. From setup_file it skips
# every test in the file, for a suite whose code under test cannot run
# anywhere else; from a test it skips that test alone.
require_linux() {
  [ "$(uname -s)" = Linux ] || skip "Linux only: $1"
}

# require_macos <why>: skip this one test unless the host is macOS. Call it from
# a test, never from setup_file: a suite skipped on Linux never runs in CI.
require_macos() {
  [ "$(uname -s)" = Darwin ] || skip "macOS only: $1"
}

# stub_uname <dir>: write <dir>/uname, the fake uname described above, read-only
# so a suite can write it once in setup_file and share it. A second call for the
# same directory leaves the first stub in place.
stub_uname() {
  mkdir -p "$1"
  [ -e "$1/uname" ] && return 0
  cat >"$1/uname" <<'EOF'
#!/bin/sh
[ "$#" -gt 0 ] || set -- -s
out=
for opt in "$@"; do
  case $opt in
    -s) val=${STUB_UNAME:-$(command -p uname -s)} ;;
    -r) val=${STUB_UNAME_R:-$(command -p uname -r)} ;;
    -m) val=${STUB_UNAME_M:-$(command -p uname -m)} ;;
    *) command -p uname "$@"; exit ;;
  esac
  out=${out:+$out }$val
done
printf '%s\n' "$out"
EOF
  chmod 555 "$1/uname"
}
