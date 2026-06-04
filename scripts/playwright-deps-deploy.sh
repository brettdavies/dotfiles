#!/usr/bin/env bash
set -euo pipefail

# Provision Playwright browser launch on Ubuntu/Debian dev hosts so the browse
# tool and Playwright e2e "just work" after a fresh clone or reprovision.
#
# Two independent things gate whether Playwright's bundled browsers LAUNCH:
#
#   1. The AppArmor userns profile for Chromium (ALWAYS deployed by this script
#      via scripts/apparmor-deploy.sh, plus a boot unit so it survives reboots).
#      Without it Chromium's sandbox fails with:
#        FATAL:sandbox/linux/services/credentials.cc Check failed: Permission denied
#      This is the only thing the browse tool needs. It is light, so it is the
#      default.
#
#   2. Browser system libraries (apt), installed ONLY when you ask, because they
#      are heavy (WebKit pulls ~180 packages / ~380 MB). Without them the
#      browser fails with:
#        browserType.launch: Host system is missing dependencies to run browsers
#
#        --chromium : Chromium/Blink deps (Chrome, Edge, Android Chrome e2e).
#                     Mostly already present on a full desktop; needed on minimal.
#        --webkit   : WebKit deps = Safari, incl. iOS/iPadOS Safari e2e
#                     (Playwright's mobile-ios + tablet projects). Heavy.
#        --all      : both.
#
# Run as your NORMAL user (not via sudo): apparmor-deploy.sh is invoked with
# sudo explicitly, and `playwright install --with-deps` escalates to sudo for
# apt on its own. Idempotent — re-run any time (e.g. after a browser version
# bump). On non-Linux it is a no-op.
#
# Usage:
#   scripts/playwright-deps-deploy.sh                 # AppArmor profile + boot wiring
#   scripts/playwright-deps-deploy.sh --webkit        # + Safari/iOS deps
#   scripts/playwright-deps-deploy.sh --chromium      # + Chromium deps
#   scripts/playwright-deps-deploy.sh --all           # + both

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

want_chromium=0
want_webkit=0
for arg in "$@"; do
  case "$arg" in
    --chromium) want_chromium=1 ;;
    --webkit)   want_webkit=1 ;;
    --all)      want_chromium=1; want_webkit=1 ;;
    -h|--help)
      sed -n '3,33p' "$0"
      exit 0
      ;;
    *)
      echo "FATAL: unknown flag '$arg' (use --chromium, --webkit, --all, or no flag)" >&2
      exit 1
      ;;
  esac
done

# --- Pre-flight ---

if [ "$(uname -s)" != "Linux" ]; then
  echo "NOTE: not Linux — Playwright browser deps + AppArmor are only needed on Linux. Nothing to do."
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "FATAL: run as your normal user, not root — sudo is escalated where needed" >&2
  echo "       (running the whole script as root puts bun outside PATH and mis-owns the browser cache)" >&2
  exit 1
fi

# --- 1. AppArmor profile + boot wiring (always; this is what the browse tool needs) ---

echo "NOTE: deploying the Chromium AppArmor profile + boot unit (sudo)…"
sudo "$REPO_ROOT/scripts/apparmor-deploy.sh"

# --- 2. Browser system libraries (opt-in; playwright runs sudo apt internally) ---

if [ "$want_chromium" -eq 1 ] || [ "$want_webkit" -eq 1 ]; then
  if ! command -v bun >/dev/null 2>&1; then
    echo "FATAL: bun not found — needed for 'playwright install --with-deps' (see BOOTSTRAP.md)" >&2
    exit 1
  fi
  browsers=()
  [ "$want_chromium" -eq 1 ] && browsers+=("chromium")
  [ "$want_webkit" -eq 1 ] && browsers+=("webkit")
  echo "NOTE: installing browser binaries + system deps via 'playwright install --with-deps ${browsers[*]}' (will sudo apt)…"
  bun x playwright install --with-deps "${browsers[@]}"
fi

echo "OK: Playwright browser launch provisioned (apparmor=yes chromium-deps=$want_chromium webkit-deps=$want_webkit)"
