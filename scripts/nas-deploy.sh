#!/usr/bin/env bash
set -euo pipefail

# Deploy NAS mount + automount systemd units via copy (not stow).
# System-level units should not symlink into user-owned directories.
#
# Usage: sudo scripts/nas-deploy.sh
#
# Prerequisites:
#   - /root/.smbcredentials-pool-nas (retrieve from 1Password: op://secrets-dev/pool-nas)
#   - cifs-utils package installed

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# NAS IP: 192.168.1.5 (static LAN). Also referenced in: config/systemd/system/mnt-nas.mount
NAS_IP="192.168.1.5"

# --- Pre-flight checks ---

if [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! test -f /root/.smbcredentials-pool-nas; then
  echo "FATAL: /root/.smbcredentials-pool-nas not found" >&2
  echo "  Retrieve from 1Password: op://secrets-dev/pool-nas" >&2
  echo "  Format: username=<user>" >&2
  echo "          password=<pass>" >&2
  exit 1
fi

# --- Deploy ---

mkdir -p /mnt/nas

# Copy unit files (overwrites existing regular files or stale copies)
cp "$REPO_ROOT/config/systemd/system/mnt-nas.mount" /etc/systemd/system/
cp "$REPO_ROOT/config/systemd/system/mnt-nas.automount" /etc/systemd/system/
systemctl daemon-reload

# Activate automount (stop + disable direct mount first for clean state)
systemctl stop mnt-nas.mount 2>/dev/null || true
systemctl disable mnt-nas.mount 2>/dev/null || true
systemctl enable --now mnt-nas.automount

echo "NOTE: NAS automount enabled (mnt-nas.automount)"

# --- Verify ---

if ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1; then
  if ls /mnt/nas >/dev/null 2>&1; then
    # shellcheck disable=SC2012  # ls output is for human display, not parsed
    echo "Mount OK — $(ls /mnt/nas | tr '\n' ' ')"
  else
    echo "WARNING: Mount test failed — check credentials and network" >&2
  fi
else
  echo "NOTE: NAS unreachable ($NAS_IP) — automount configured, will mount on next access"
fi
