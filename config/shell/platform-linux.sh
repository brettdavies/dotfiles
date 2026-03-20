# shellcheck shell=bash
# Linux-specific shell config — sourced by .profile on all platforms, guarded below
[ "$(uname -s)" = "Linux" ] || return 0

# Print aliases — duplex must be specified explicitly (IPP Everywhere global config doesn't stick)
alias lp='lp -d Lunik -o sides=two-sided-long-edge'
alias lp1='lp -d Lunik -o sides=one-sided'

# Trash — gio trash is the freedesktop.org standard on Linux
alias trash='gio trash'
