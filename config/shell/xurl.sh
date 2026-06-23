# shellcheck shell=bash
# xurl-rs installs its binary as `xr`; alias `xurl` to it for muscle memory
# from the Go tool this crate ports.
if command -v xr >/dev/null 2>&1; then
  alias xurl=xr
fi
