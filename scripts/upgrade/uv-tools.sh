#!/usr/bin/env bash
# Upgrades every uv-installed tool. Runs daily from uv-tools-upgrade.timer on the Linux server and from the
# com.user.uv-tools-upgrade LaunchAgent on macOS, writing the run log that lib/run-log.sh defines.

lib_dir="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/shell-env.sh
. "$lib_dir/shell-env.sh"
# shellcheck source=lib/run-log.sh
. "$lib_dir/run-log.sh"
set -euo pipefail

_uv_tools() {
  { uv tool list 2>/dev/null || true; } | awk 'NF == 2 && $1 != "-" { sub(/^v/, "", $2); print $1, $2 }'
}

run_log_start uv-tools-upgrade "uv tool upgrade --all" "$(uv --version 2>&1)" \
  UV_EXCLUDE_NEWER UV_MALWARE_CHECK UV_CACHE_DIR

# Without the cooldown an unattended upgrade installs a release minutes after it is published, inside the window
# before a malicious upload is reported.
if [ -z "${UV_EXCLUDE_NEWER:-}" ]; then
  run_log_finish 1 cooldown-unset \
    "UV_EXCLUDE_NEWER is unset after loading $DOTFILES_SHELL_DIR; refusing to upgrade without the release cooldown" \
    '[]' inspect-config "grep -n UV_EXCLUDE_NEWER $(printf %q "$DOTFILES_SHELL_DIR/supply-chain.sh")"
fi

before=$(_uv_tools)
run_log_capture uv tool upgrade --all
run_log_complete "$(run_log_changes "$before" "$(_uv_tools)")"
