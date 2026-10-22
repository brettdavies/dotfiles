# shellcheck shell=bash
# Loads config/shell/*.sh, the tool policy (release cooldowns, cache locations, telemetry opt-outs) that ~/.profile
# gives an interactive shell; launchd and systemd start the upgrade jobs without reading any startup file. ~/.profile
# itself stays out: it also loads ~/.secrets through 1Password, and no install script an upgrade runs needs those
# tokens in its environment.
DOTFILES_SHELL_DIR="${DOTFILES_SHELL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/shell}"
for _f in "$DOTFILES_SHELL_DIR"/*.sh; do
  # shellcheck disable=SC1090
  [ -f "$_f" ] && . "$_f"
done
unset _f
