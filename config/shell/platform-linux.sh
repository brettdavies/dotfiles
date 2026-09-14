# shellcheck shell=bash
# Linux-specific shell config — sourced by .profile on all platforms, guarded below
[ "$(uname -s)" = "Linux" ] || return 0

# Print wrappers — duplex must be specified explicitly (IPP Everywhere global config doesn't stick).
# Functions rather than aliases: .profile sources this in non-interactive shells,
# where whether an alias resolves depends on the invocation rather than the shell.
# `command lp` reaches the real binary instead of recursing into the function.
lp() { command lp -d Lunik -o sides=two-sided-long-edge "$@"; }
lp1() { command lp -d Lunik -o sides=one-sided "$@"; }
