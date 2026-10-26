#!/usr/bin/env bash
# Runs the `bu` shell function from config/shell/shell-functions, without `--greedy`. Runs daily from
# brew-upgrade.timer on the Linux server and from the com.user.brew-upgrade LaunchAgent on macOS, writing the run log
# that lib/run-log.sh defines.

lib_dir="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/shell-env.sh
. "$lib_dir/shell-env.sh"
# shellcheck source=lib/run-log.sh
. "$lib_dir/run-log.sh"
# shellcheck source=lib/stale-procs.sh
. "$lib_dir/stale-procs.sh"
set -euo pipefail
# shellcheck source=/dev/null
. "$DOTFILES_SHELL_DIR/shell-functions"

# shellcheck disable=SC2329 # run_log_upgrade calls it by name
_brew_versions() {
  brew list --versions 2>/dev/null | awk '{ print $1, $NF }'
}

run_log_start brew-upgrade "bu --no-greedy" "$(brew --version 2>&1 | head -n 1)" HOMEBREW_NO_ANALYTICS HOMEBREW_CACHE
run_log_upgrade _brew_versions bu --no-greedy
if [ "$RUN_OS" = Linux ] && prefix=$(brew --prefix 2>/dev/null); then
  stale_procs_restart /proc "$prefix"
fi
run_log_complete
