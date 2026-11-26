#!/usr/bin/env bash
set -euo pipefail

# Deploy the apt preferences in config/apt/preferences.d/ to
# /etc/apt/preferences.d/ by copy (not stow).
#
# apt reads /etc/apt/preferences.d/ as root on every install and upgrade, so
# the files are root-owned copies rather than symlinks into $HOME. A copied
# file does not prove apt honours it: a later file can raise the same pin.
# nvidia-gpu-verify answers that by asking apt-cache policy, and the deploy's
# last line names it.
#
# Usage: sudo scripts/nvidia-deploy.sh
#        scripts/nvidia-deploy.sh --check
#        scripts/nvidia-deploy.sh --dest DIR
#
#   --check      compare /etc/apt/preferences.d with config/apt/preferences.d
#                and change nothing; needs no root.
#   --dest DIR   copy into DIR instead of /etc/apt/preferences.d, with no root
#                or platform check. tests/nvidia-deploy.bats drives this.
#
# Exit 0 on success, including when nothing needed copying or on a non-Linux
# host; 1 on a failed pre-flight or a deployed file that differs; 2 on a usage
# error.
#
# Env: NVIDIA_DEPLOY_PREFERENCES_DIR  where --check reads the deployed files
#      (default /etc/apt/preferences.d). The bats suite points it at a sandbox.

EXIT_FAILURE=1
EXIT_USAGE=2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/config/apt/preferences.d"
LIVE_DEST="${NVIDIA_DEPLOY_PREFERENCES_DIR:-/etc/apt/preferences.d}"

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

# --- Pre-flight checks ---

if [ "$mode" != dest ] && [ "$(uname -s)" != Linux ]; then
  echo "NOTE: apt preferences are Linux-only; nothing to do on $(uname -s)"
  exit 0
fi

if [ "$mode" = deploy ] && [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit "$EXIT_FAILURE"
fi

shopt -s nullglob
files=("$SRC_DIR"/*)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "FATAL: no files in $SRC_DIR" >&2
  exit "$EXIT_FAILURE"
fi

if [ "$mode" = check ]; then
  drift=0
  for src in "${files[@]}"; do
    name="$(basename "$src")"
    if cmp -s "$src" "$LIVE_DEST/$name"; then
      echo "OK: $LIVE_DEST/$name matches the repo"
    elif [ -e "$LIVE_DEST/$name" ]; then
      echo "FATAL: $LIVE_DEST/$name differs from config/apt/preferences.d/$name" >&2
      drift=1
    else
      echo "FATAL: $LIVE_DEST/$name is not deployed" >&2
      drift=1
    fi
  done
  if [ "$drift" -ne 0 ]; then
    echo "NOTE: deploy with: sudo $0" >&2
    exit "$EXIT_FAILURE"
  fi
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
  echo "OK: $dest already matches config/apt/preferences.d (nothing to copy)"
fi

echo "NOTE: confirm apt honours the guard with: nvidia-gpu-verify"
