# shellcheck shell=bash
# xurl-rs installs its binary as `xr`; expose `xurl` for muscle memory from the
# Go tool this crate ports. A function rather than an alias: .profile sources
# this in non-interactive shells, where whether an alias resolves depends on the
# invocation rather than the shell.
if command -v xr >/dev/null 2>&1; then
  xurl() { xr "$@"; }
fi
