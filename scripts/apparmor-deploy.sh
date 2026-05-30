#!/usr/bin/env bash
set -euo pipefail

# Deploy AppArmor profiles via copy (not stow), and a systemd boot unit that
# reloads them at every boot. System-level policy should not symlink into
# user-owned directories.
#
# The boot unit matters because Ubuntu's own apparmor.service is skipped at boot
# on minimized server images (ConditionResult=no, so /etc/apparmor.d/ is never
# reloaded). Without the unit the playwright profile silently drops on each
# reboot and Chromium's sandbox breaks again.
#
# Usage: sudo scripts/apparmor-deploy.sh
#
# Currently deploys:
#   - playwright: grants userns to Playwright's bundled Chromium binaries so
#                 the browse tool and Playwright tests work on Ubuntu 24.04.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/config/apparmor.d"
DEST_DIR="/etc/apparmor.d"
UNIT_SRC="$REPO_ROOT/config/systemd/system/apparmor-playwright.service"
UNIT_DEST="/etc/systemd/system/apparmor-playwright.service"

# --- Pre-flight checks ---

if [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "FATAL: apparmor_parser not found — install apparmor package" >&2
  exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "FATAL: source directory not found: $SRC_DIR" >&2
  exit 1
fi

# --- Deploy ---

shopt -s nullglob
profiles=("$SRC_DIR"/*)
shopt -u nullglob

if [ ${#profiles[@]} -eq 0 ]; then
  echo "NOTE: no profiles found in $SRC_DIR — nothing to deploy"
  exit 0
fi

for src in "${profiles[@]}"; do
  name="$(basename "$src")"
  dest="$DEST_DIR/$name"
  cp "$src" "$dest"
  apparmor_parser -r "$dest"
  echo "NOTE: loaded AppArmor profile $name"
done

# --- Boot persistence: install + enable the reload-at-boot unit ---

if [ -f "$UNIT_SRC" ]; then
  cp "$UNIT_SRC" "$UNIT_DEST"
  systemctl daemon-reload
  systemctl enable apparmor-playwright.service >/dev/null 2>&1 || true
  echo "NOTE: installed + enabled apparmor-playwright.service (reloads profiles at boot)"
fi

echo "OK: AppArmor profiles deployed"
