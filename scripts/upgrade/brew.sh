#!/usr/bin/env bash
# Runs the `bu` shell function from config/shell/shell-functions, without `--greedy`. Runs daily from
# brew-upgrade.timer on the Linux server and from the com.user.brew-upgrade LaunchAgent on macOS, writing the run log
# that lib/run-log.sh defines.

lib_dir="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/shell-env.sh
. "$lib_dir/shell-env.sh"
# shellcheck source=lib/run-log.sh
. "$lib_dir/run-log.sh"
set -euo pipefail
# shellcheck source=/dev/null
. "$DOTFILES_SHELL_DIR/shell-functions"

_brew_versions() {
  { brew list --versions 2>/dev/null || true; } | awk '{ print $1, $NF }'
}

run_log_start brew-upgrade "bu --no-greedy" "$(brew --version 2>&1 | head -n 1)" HOMEBREW_NO_ANALYTICS HOMEBREW_CACHE
before=$(_brew_versions)
run_log_capture bu --no-greedy
run_log_complete "$(run_log_changes "$before" "$(_brew_versions)")"
