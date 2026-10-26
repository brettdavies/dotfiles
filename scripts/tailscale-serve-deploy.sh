#!/usr/bin/env bash
set -euo pipefail

# Install the systemd unit that re-runs scripts/tailscale-serve-setup.sh every
# time tailscaled starts. Copied (not stowed): a system unit should not symlink
# into a user-owned directory. The unit runs as the Tailscale operator, so
# `tailscale serve` needs no root, and executes that user's ~/dotfiles (the
# canonical checkout) whichever checkout this script runs from, so the unit
# never points at a scratch clone or worktree that later disappears.
#
# Usage: sudo scripts/tailscale-serve-deploy.sh
#        scripts/tailscale-serve-deploy.sh --render OPERATOR   print the unit only

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_SRC="$REPO_ROOT/config/systemd/system/tailscale-serve-setup.service"
UNIT_DEST="/etc/systemd/system/tailscale-serve-setup.service"

checkout_of() {
  local home
  home=$(getent passwd "$1" | cut -d: -f6)
  if [ -z "$home" ]; then
    echo "FATAL: no account for operator user $1" >&2
    exit 1
  fi
  echo "$home/dotfiles"
}

render() {
  local checkout
  checkout=$(checkout_of "$1")
  sed -e "s|@OPERATOR@|$1|g" -e "s|@CHECKOUT@|$checkout|g" "$UNIT_SRC"
}

usage_error() {
  echo "ERROR: $1 (usage: sudo $0 | $0 --render OPERATOR)" >&2
  exit 2
}

if [ "${1:-}" = "--render" ]; then
  [ "$#" -eq 2 ] || usage_error "--render takes the operator user name"
  render "$2"
  exit 0
fi
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"

# --- Pre-flight checks ---

if [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit 1
fi

operator=$(tailscale debug prefs | sed -n 's/^[[:space:]]*"OperatorUser": "\([^"]*\)",\{0,1\}$/\1/p')
if [ -z "$operator" ]; then
  echo "FATAL: tailscale has no operator user, and the unit runs tailscale serve as that user." >&2
  echo "  Set one first: sudo tailscale set --operator=\$SUDO_USER" >&2
  exit 1
fi

setup_script="$(checkout_of "$operator")/scripts/tailscale-serve-setup.sh"
if [ ! -x "$setup_script" ]; then
  echo "FATAL: $setup_script not found or not executable; the unit runs it from the canonical checkout" >&2
  exit 1
fi

# --- Deploy ---

render "$operator" >"$UNIT_DEST"
systemctl daemon-reload
systemctl enable --now tailscale-serve-setup.service
echo "NOTE: installed + enabled tailscale-serve-setup.service (runs as $operator on every tailscaled start)"
