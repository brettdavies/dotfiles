#!/usr/bin/env bash
set -euo pipefail

# Deploy the kernel settings in config/sysctl.d/ to /etc/sysctl.d/ by copy (not
# stow), apply them, and confirm the kernel holds each one.
#
# systemd-sysctl.service reads /etc/sysctl.d/ early in boot, so the files are
# root-owned copies rather than symlinks into $HOME. Restarting that unit
# re-applies every drop-in in the lexical order boot uses, so a passing run
# also shows the setting survives a reboot. Neither the restart nor
# `sysctl --system` fails when a later-sorting file overrides a key, so the
# script reads each key back from /proc/sys and fails when the kernel holds
# something else.
#
# Usage: sudo scripts/sysctl-deploy.sh
#        scripts/sysctl-deploy.sh --check
#        scripts/sysctl-deploy.sh --dest DIR
#
#   --check      compare the kernel's live values with config/sysctl.d/ and
#                change nothing; needs no root.
#   --dest DIR   copy into DIR instead of /etc/sysctl.d, with no root or
#                platform check and no apply. tests/sysctl-deploy.bats drives
#                this.
#
# Exit 0 on success, including when nothing needed copying or on a non-Linux
# host; 1 on a failed pre-flight or a value the kernel does not hold; 2 on a
# usage error.
#
# Env: SYSCTL_PROC_DIR  where live values are read (default /proc/sys). The
#      bats suite points it at a sandbox tree.

EXIT_FAILURE=1
EXIT_USAGE=2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/config/sysctl.d"
LIVE_DEST=/etc/sysctl.d
PROC_DIR="${SYSCTL_PROC_DIR:-/proc/sys}"

usage() {
  echo "usage: $0 [--check | --dest DIR]" >&2
  exit "$EXIT_USAGE"
}

mode=deploy
dest="$LIVE_DEST"
case "$#:${1:-}" in
  0:) ;;
  1:--check) mode=check ;;
  2:--dest)
    mode=dest
    dest="$2"
    ;;
  *) usage ;;
esac

# Print "key<TAB>value" for every setting in a sysctl.d file, with the key in
# its /proc/sys path form. A leading `-` only tells systemd-sysctl to ignore a
# missing key, so it is dropped.
settings() {
  awk '
    /^[[:space:]]*([#;]|$)/ { next }
    {
      eq = index($0, "=")
      if (!eq) next
      key = substr($0, 1, eq - 1)
      value = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/^-/, "", key)
      gsub(/\./, "/", key)
      print key "\t" value
    }
  ' "$1"
}

# Compare every shipped setting with the live value. Whitespace runs compare
# equal, since /proc/sys separates multi-value settings with tabs.
check_live() {
  local src key value live_words want_words drift=0
  for src in "${files[@]}"; do
    while IFS=$'\t' read -r key value; do
      if [ ! -r "$PROC_DIR/$key" ]; then
        echo "FATAL: ${key//\//.} from $(basename "$src") is not a setting this kernel exposes" >&2
        drift=1
        continue
      fi
      read -r -a live_words <"$PROC_DIR/$key" || true
      read -r -a want_words <<<"$value"
      if [ "${live_words[*]}" = "${want_words[*]}" ]; then
        echo "OK: ${key//\//.} = $value"
      else
        echo "FATAL: ${key//\//.} is ${live_words[*]}, $(basename "$src") sets $value" >&2
        drift=1
      fi
    done < <(settings "$src")
  done
  if [ "$drift" -ne 0 ]; then
    echo "NOTE: a later-sorting file can override a key; list the order with: systemd-analyze cat-config sysctl.d" >&2
    return "$EXIT_FAILURE"
  fi
}

# --- Pre-flight checks ---

if [ "$mode" != dest ] && [ "$(uname -s)" != Linux ]; then
  echo "NOTE: sysctl.d is Linux-only; nothing to do on $(uname -s)"
  exit 0
fi

if [ "$mode" = deploy ] && [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit "$EXIT_FAILURE"
fi

shopt -s nullglob
files=("$SRC_DIR"/*.conf)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "FATAL: no .conf files in $SRC_DIR" >&2
  exit "$EXIT_FAILURE"
fi

if [ "$mode" = check ]; then
  check_live
  exit 0
fi

if [ ! -d "$dest" ]; then
  echo "FATAL: destination not found: $dest" >&2
  exit "$EXIT_FAILURE"
fi

# --- Deploy ---

copied=0
for src in "${files[@]}"; do
  target="$dest/$(basename "$src")"
  if cmp -s "$src" "$target"; then
    continue
  fi
  install -m 0644 "$src" "$target"
  echo "NOTE: copied $(basename "$src") to $dest"
  copied=$((copied + 1))
done

if [ "$copied" -eq 0 ]; then
  echo "OK: $dest already matches config/sysctl.d (nothing to copy)"
fi

[ "$mode" = dest ] && exit 0

# --- Apply and verify ---

systemctl restart systemd-sysctl.service
check_live
echo "OK: the kernel holds every setting in config/sysctl.d"
