#!/usr/bin/env bash
set -euo pipefail

# Install the pinned rexurrect release on the Linux server: the binary to
# ~/.local/bin/rexurrect and its zsh recorder to
# ~/.local/share/rexurrect/rexurrect.plugin.zsh, where .zshrc sources it.
#
# The archive is downloaded into an empty directory, and nothing is installed
# unless its SHA-256 matches the pin below and `gh attestation verify` accepts
# it. An install counts as current only when both installed files have the
# pinned SHA-256 of their copies inside that archive; any other file there is
# replaced from the verified download, and the installed binary is never run.
#
# Usage: scripts/rexurrect-deploy.sh [--dest DIR]
#
#   --dest DIR  install under DIR instead of $HOME
#
# Exit 0 on success, including when nothing changed; 1 on a failed check or
# download; 2 on a usage error.

REXURRECT_REPO=cemcatik/rexurrect
REXURRECT_VERSION=0.6.0
REXURRECT_TARGET=x86_64-unknown-linux-musl
REXURRECT_ARCHIVE_SHA256=45990bb57e10d56c31e6d7cb75befe1751adc430c629e2dcf5b74e432e53339f
REXURRECT_BINARY_SHA256=22ced533d8a2ca76ada4e8d46fbb230f0c820afc8391397b458d083062ea8af0
REXURRECT_PLUGIN_SHA256=72131622ef547d25e9217358fb2483e6d4d8322f808adbfa41d0992c6af14752

EXIT_FAILURE=1
EXIT_USAGE=2
RERUN="cd ~/dotfiles && scripts/rexurrect-deploy.sh"
ARCHIVE="rexurrect-$REXURRECT_TARGET.tar.xz"

dest=$HOME
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest)
      [ "$#" -ge 2 ] || { echo "ERROR: --dest needs a directory (usage: $0 [--dest DIR])" >&2 && exit "$EXIT_USAGE"; }
      dest=$2
      shift 2
      ;;
    -h | --help)
      awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *) echo "ERROR: unexpected argument: $1 (usage: $0 [--dest DIR])" >&2 && exit "$EXIT_USAGE" ;;
  esac
done

bin_dest="$dest/.local/bin/rexurrect"
plugin_dest="$dest/.local/share/rexurrect/rexurrect.plugin.zsh"

# Usage: fatal <message> <fix>; nothing has been installed when it runs.
fatal() {
  echo "FATAL: $ARCHIVE (rexurrect $REXURRECT_VERSION): $1; nothing was installed. $2" >&2
  exit "$EXIT_FAILURE"
}

sha256() {
  local sum
  read -r sum _ < <(sha256sum "$1")
  printf '%s' "$sum"
}

if [ "$(uname -s)" != Linux ]; then
  echo "NOTE: rexurrect's deploy installs the Linux build; nothing to do on $(uname -s)"
  exit 0
fi
arch=$(uname -m)
[ "$arch" = "${REXURRECT_TARGET%%-*}" ] \
  || fatal "no build is pinned for this machine ($arch)" "Pin the $arch archive's hashes in $0."

if [ -f "$bin_dest" ] && [ -f "$plugin_dest" ] && [ "$(sha256 "$bin_dest")" = "$REXURRECT_BINARY_SHA256" ] \
  && [ "$(sha256 "$plugin_dest")" = "$REXURRECT_PLUGIN_SHA256" ]; then
  echo "OK: rexurrect $REXURRECT_VERSION is already installed at $bin_dest; nothing to do"
  exit 0
fi

for tool in gh sha256sum tar xz install; do
  command -v "$tool" >/dev/null 2>&1 || fatal "$tool is required to fetch and check the release" "Install $tool."
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gh release download "v$REXURRECT_VERSION" --repo "$REXURRECT_REPO" --pattern "$ARCHIVE" --dir "$work" \
  || fatal "the download failed" "Rerun: $RERUN"

actual=$(sha256 "$work/$ARCHIVE")
[ "$actual" = "$REXURRECT_ARCHIVE_SHA256" ] \
  || fatal "SHA-256 is $actual, not the pinned $REXURRECT_ARCHIVE_SHA256" "Rerun: $RERUN"

gh attestation verify "$work/$ARCHIVE" --repo "$REXURRECT_REPO" \
  || fatal "its GitHub attestation did not verify" \
    "Check it by hand: gh release download v$REXURRECT_VERSION --repo $REXURRECT_REPO --pattern $ARCHIVE && gh attestation verify $ARCHIVE --repo $REXURRECT_REPO"

tar -xJf "$work/$ARCHIVE" -C "$work"
unpacked="$work/rexurrect-$REXURRECT_TARGET"
[ "$(sha256 "$unpacked/rexurrect")" = "$REXURRECT_BINARY_SHA256" ] \
  && [ "$(sha256 "$unpacked/rexurrect.plugin.zsh")" = "$REXURRECT_PLUGIN_SHA256" ] \
  || fatal "the binary or recorder inside it does not match its pin" "Pin their hashes from the verified archive in $0."

# Each file is written beside its destination and renamed over it, so a shell
# or timer never runs a half-written copy.
install -D -m 0755 "$unpacked/rexurrect" "$bin_dest.new"
mv -f "$bin_dest.new" "$bin_dest"
install -D -m 0644 "$unpacked/rexurrect.plugin.zsh" "$plugin_dest.new"
mv -f "$plugin_dest.new" "$plugin_dest"
echo "OK: rexurrect $REXURRECT_VERSION installed at $bin_dest, recorder at $plugin_dest"
