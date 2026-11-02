#!/usr/bin/env bash
# Compare Hex's transform config, ~/.config/hex/hex.config.ts, with the copy in
# config/hex/hex.config.ts.
#
# Hex refuses a config whose real path is outside its config folder ("only
# files inside the config folder can be imported"), so a stow symlink into this
# repo never loads and the file is copied instead. Hex reloads the config about
# a third of a second after the file changes.
#
# Usage: scripts/hex-config.sh           report; exit 1 on drift
#        scripts/hex-config.sh --apply   copy the repo's file into place
#
# Exit codes: 0 in sync, Hex not installed, or not macOS; 1 drift; 2 usage
#             error; 3 no config in the repo.
# Env:   HEX_CONFIG_DIR  Hex's config folder (default ~/.config/hex)
#        HEX_APP         the Hex app bundle (default /Applications/Hex.app)
#        The bats suite points both at per-test paths.

set -euo pipefail

EXIT_DRIFT=1
EXIT_USAGE=2
EXIT_CONFIG=3

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECLARED="$REPO_ROOT/config/hex/hex.config.ts"
CONFIG_DIR="${HEX_CONFIG_DIR:-$HOME/.config/hex}"
TARGET="$CONFIG_DIR/hex.config.ts"
HEX_APP="${HEX_APP:-/Applications/Hex.app}"

APPLY=false
case "$#:${1:-}" in
  0:) ;;
  1:--apply) APPLY=true ;;
  *)
    echo "usage: $0 [--apply]" >&2
    exit "$EXIT_USAGE"
    ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: Hex is deployed only on macOS; nothing to do on $(uname -s)." >&2
  exit 0
fi
if [ ! -d "$HEX_APP" ]; then
  echo "NOTE: Hex is not installed at $HEX_APP; nothing to do." >&2
  exit 0
fi
if [ ! -f "$DECLARED" ]; then
  echo "ERROR: no Hex config in $DECLARED" >&2
  exit "$EXIT_CONFIG"
fi

if [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && cmp -s "$DECLARED" "$TARGET"; then
  echo "Hex transforms in sync: $TARGET"
  exit 0
fi

if [ "$APPLY" = false ]; then
  echo "WARNING: $TARGET differs from config/hex/hex.config.ts" >&2
  if [ -L "$TARGET" ]; then
    echo "  it is a symlink, which Hex refuses to load" >&2
  elif [ -f "$TARGET" ]; then
    diff -u -L installed -L config/hex/hex.config.ts "$TARGET" "$DECLARED" | sed 's/^/  /' >&2 || true
  else
    echo "  it does not exist" >&2
  fi
  echo "  fix: scripts/hex-config.sh --apply" >&2
  echo "       (it replaces the installed file; to keep an edit made there, copy it to config/hex/ first)" >&2
  exit "$EXIT_DRIFT"
fi

mkdir -p "$CONFIG_DIR"
# cp onto a symlink would write through it into the file it names.
if [ -L "$TARGET" ]; then
  rm -f "$TARGET"
fi
cp "$DECLARED" "$TARGET"
cmp -s "$DECLARED" "$TARGET" || {
  echo "ERROR: $TARGET still differs after the copy" >&2
  exit "$EXIT_DRIFT"
}
echo "Hex transforms copied to $TARGET; Hex reloads them within a second."
