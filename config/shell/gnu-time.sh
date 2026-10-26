# shellcheck shell=bash
# gtime: GNU time under one name on every host. Homebrew's gnu-time installs it
# as `gtime` on macOS but as plain `time` on Linux, where bash and zsh parse a
# bare `time` as their own keyword (no -v, -f or %M) and Ubuntu has no
# /usr/bin/time unless its `time` package is installed. On macOS the formula's
# own `gtime` binary answers, so nothing is defined there. A function rather
# than an alias: .profile sources this in non-interactive shells.
if ! command -v gtime >/dev/null 2>&1 && [ -x "${HOMEBREW_PREFIX:-}/bin/time" ]; then
  gtime() { "$HOMEBREW_PREFIX/bin/time" "$@"; }
fi
