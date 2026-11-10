#!/usr/bin/env bash
set -euo pipefail

# Deploy the Rex login server's config by copy (not stow) and enable the
# service, so Rex for Mac can reach this host over the tailnet:
#
#   config/rex/accounts.jsonc  ->  /etc/rex/accounts.jsonc
#   config/systemd/system/rex-login-server.service.d/tailnet-listen.conf
#                              ->  /etc/systemd/system/rex-login-server.service.d/
#
# The repo is public, so accounts.jsonc is a template: the Tailscale login it
# lets in comes from --login at deploy time and never lands in git. The rex
# package itself comes from Superlogical's install script (BOOTSTRAP.md § Rex
# login server), which needs a pre-release token this repo does not hold.
#
# Usage: sudo scripts/rex-login-server-deploy.sh --login LOGIN [--account NAME]
#        scripts/rex-login-server-deploy.sh --login LOGIN [--account NAME] --root DIR
#
#   --login LOGIN   the Tailscale login let in, as the admin console shows it
#   --account NAME  the account that login gets (default: $SUDO_USER, else the
#                   current user)
#   --root DIR      write under DIR/etc instead of /etc, with no root check and
#                   no systemctl. tests/rex-login-server-deploy.bats drives this.
#
# Exit 0 on success, including when nothing changed; 1 on a failed pre-flight
# or a service that does not come up listening; 2 on a usage error.

EXIT_FAILURE=1
EXIT_USAGE=2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNTS_SRC="$REPO_ROOT/config/rex/accounts.jsonc"
DROPIN_SRC="$REPO_ROOT/config/systemd/system/rex-login-server.service.d/tailnet-listen.conf"
UNIT=rex-login-server.service

usage() {
  echo "ERROR: $1 (usage: sudo $0 --login LOGIN [--account NAME] [--root DIR])" >&2
  exit "$EXIT_USAGE"
}

login=""
account="${SUDO_USER:-$(id -un)}"
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --login | --account | --root)
      [ "$#" -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --login) login="$2" ;;
        --account) account="$2" ;;
        --root) root="$2" ;;
      esac
      shift 2
      ;;
    *) usage "unexpected argument: $1" ;;
  esac
done

[ -n "$login" ] || usage "--login is required"
# Both values are substituted with sed and land inside JSON strings, so neither
# may carry a quote, a backslash, or a sed metacharacter.
[[ "$login" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+$ ]] || usage "not a Tailscale login: $login"
[[ "$account" =~ ^[a-z_][a-z0-9_-]*$ ]] || usage "not an account name: $account"

# --- Pre-flight checks ---

if [ -z "$root" ]; then
  if [ "$(uname -s)" != Linux ]; then
    echo "NOTE: the Rex login server deploy is Linux-only; nothing to do on $(uname -s)"
    exit 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: This script must be run as root (use sudo)" >&2
    exit "$EXIT_FAILURE"
  fi
  if ! systemctl cat "$UNIT" >/dev/null 2>&1; then
    echo "FATAL: $UNIT is not installed; install the rex package first (BOOTSTRAP.md § Rex login server)" >&2
    exit "$EXIT_FAILURE"
  fi
  if ! systemctl is-active --quiet tailscaled.service; then
    echo "FATAL: tailscaled is not running, and the tailnet listener needs it" >&2
    exit "$EXIT_FAILURE"
  fi
elif [ ! -d "$root" ]; then
  echo "FATAL: root directory not found: $root" >&2
  exit "$EXIT_FAILURE"
fi

shell=$(getent passwd "$account" | cut -d: -f7) || true
if [ -z "$shell" ]; then
  echo "FATAL: no account named $account" >&2
  exit "$EXIT_FAILURE"
fi
# PAM refuses these shells, so every connection would fail after the deploy.
case "$shell" in
  */nologin | */false)
    echo "FATAL: $account has the shell $shell, and the login server refuses it" >&2
    exit "$EXIT_FAILURE"
    ;;
esac

port=$(sed -n 's|.*--extra-listen tailnet://:\([0-9][0-9]*\).*|\1|p' "$DROPIN_SRC")
if [ -z "$port" ]; then
  echo "FATAL: no tailnet listener port in $DROPIN_SRC" >&2
  exit "$EXIT_FAILURE"
fi

# --- Deploy ---

accounts_dest="$root/etc/rex/accounts.jsonc"
dropin_dest="$root/etc/systemd/system/$UNIT.d/$(basename "$DROPIN_SRC")"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
sed -e "s|@ACCOUNT@|$account|g" -e "s|@TAILSCALE_LOGIN@|$login|g" "$ACCOUNTS_SRC" >"$rendered"

# Copy $1 to $2 when they differ. Succeeds only when it copied.
copy_if_changed() {
  if cmp -s "$1" "$2"; then
    return 1
  fi
  install -D -m 0644 "$1" "$2"
  echo "NOTE: wrote $2"
}

accounts_changed=0
dropin_changed=0
copy_if_changed "$rendered" "$accounts_dest" && accounts_changed=1
copy_if_changed "$DROPIN_SRC" "$dropin_dest" && dropin_changed=1

if [ "$accounts_changed" -eq 0 ] && [ "$dropin_changed" -eq 0 ]; then
  echo "OK: $root/etc already matches config/rex and the drop-in (nothing to copy)"
fi

[ -z "$root" ] || exit 0

# --- Apply and verify ---

[ "$dropin_changed" -eq 0 ] || systemctl daemon-reload
systemctl enable --quiet "$UNIT"
# A restart leaves each account's server and its sessions running
# (KillMode=process in the packaged unit), and a reload applies the accounts
# file without dropping connections.
if ! systemctl is-active --quiet "$UNIT"; then
  systemctl start "$UNIT"
elif [ "$dropin_changed" -eq 1 ]; then
  systemctl restart "$UNIT"
elif [ "$accounts_changed" -eq 1 ]; then
  systemctl reload "$UNIT"
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -n "$(ss -ltnH "sport = :$port")" ]; then
    echo "OK: $UNIT is listening on tailnet port $port and lets $login in as $account"
    echo "NOTE: in Rex for Mac, choose Add Remote Host… and enter this host's tailnet name"
    exit 0
  fi
  sleep 1
done
echo "FATAL: $UNIT is not listening on port $port; see: journalctl -u $UNIT -n 50 --no-pager" >&2
exit "$EXIT_FAILURE"
