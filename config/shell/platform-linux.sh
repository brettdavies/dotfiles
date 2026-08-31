# shellcheck shell=bash
# Linux-specific shell config — sourced by .profile on all platforms, guarded below
[ "$(uname -s)" = "Linux" ] || return 0

# Print aliases — duplex must be specified explicitly (IPP Everywhere global config doesn't stick)
alias lp='lp -d Lunik -o sides=two-sided-long-edge'
alias lp1='lp -d Lunik -o sides=one-sided'

# Trash is a binary, not an alias: trash-cli from the Brewfile, matching the
# stock /usr/bin/trash on macOS. An alias reaches interactive shells only, so
# every script, systemd unit, git hook and agent tool call resolved nothing and
# had no way to honor the repo's ban on rm.
