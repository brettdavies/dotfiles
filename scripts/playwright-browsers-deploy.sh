#!/usr/bin/env bash
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi
set -euo pipefail
set -E

# Provision the system browser set into the shared Playwright cache
# ($PLAYWRIGHT_BROWSERS_PATH): one Chrome for Testing build with its headless
# shell, one WebKit, one ffmpeg, and an alias for every revision a released
# Playwright (1.57 and later) asks for, so `playwright install` in any repo is a
# no-op. Every version, revision, alias and archive hash comes from the pin,
# config/playwright/browsers.pin; archives come from hosts fixed in
# scripts/playwright-browsers/lib/plan.sh, through curl and unzip because node's
# extractor deadlocks on this kernel's io_uring. User-space only: no sudo.
#
# Usage:
#   scripts/playwright-browsers-deploy.sh [--pin PATH]          deploy the set the pin names
#   scripts/playwright-browsers-deploy.sh --check [--pin PATH]  report any difference, change nothing
#   scripts/playwright-browsers-deploy.sh --help
#
#   --pin PATH   read this pin instead of the checkout's
#
# Exit 0 on success or a healthy --check; 1 on any failure or finding; 2 on a
# usage error. Every failure line carries a stable reason, what changed, and a
# command to run next; docs/runbooks/playwright-browser-launch.md lists them.
#
# The first deploy on a host replaces each unrecorded directory at a set or
# alias name, so run it with no browser session open there.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/playwright-browsers/lib"
for f in pin provision clients check; do
  # shellcheck disable=SC1090 # the four files are linted as targets of their own
  source "$LIB/$f.sh"
done
trap pw_unexpected ERR

MODE=deploy
PIN="$REPO_ROOT/config/playwright/browsers.pin"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --pin)
      [ "$#" -ge 2 ] || pw_usage "--pin needs a path" usage "nothing changed" "$PW_DEPLOY --help"
      PIN=$2
      shift
      ;;
    -h | --help)
      awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*) pw_usage "unknown option" usage "nothing changed" "$PW_DEPLOY --help" "$1" ;;
    *) pw_usage "the Playwright version argument is gone; the set comes from the pin at $(printf %q "$PIN")" \
      version-argument-removed "nothing changed" "$PW_DEPLOY --help" "$1" ;;
  esac
  shift
done

[ "$(id -u)" -ne 0 ] \
  || pw_fail "run as your normal user, not root; the browser cache must be owned by you" running-as-root "nothing changed" "$PW_DEPLOY"
pin_load "$PIN"
pw_plan
BP="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/playwright}"
PW_LINKS="$BP/.links"
PW_CLIENTS="$BP/.dotfiles/clients"
pw_wanted

if [ "$MODE" = check ]; then
  pw_check
  exit 0
fi

for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 \
    || pw_fail "$tool is required to fetch and unpack the archives" tool-missing "nothing changed" "$PW_DEPLOY" "$tool"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || pw_fail "sha256sum or shasum is required to verify the archives" tool-missing "nothing changed" "$PW_DEPLOY" sha256sum

mkdir -p "$BP/.dotfiles" "$PW_LINKS" "$PW_CLIENTS"
STAGE="$(mktemp -d "$BP/.dotfiles/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# What exists is registered first, so a cleanup that runs while this provisions
# keeps it. A directory is registered once it has arrived, so a failed fetch
# leaves no client for nothing, and aliases move last, once every directory they
# point at is verified.
for n in "${PW_WANTED[@]}"; do
  if [ -e "$BP/$n" ] || [ -L "$BP/$n" ]; then pw_register "$n"; fi
done
for i in "${!PW_DIR[@]}"; do
  pw_provision "$i"
  pw_register "${PW_DIR[$i]}"
done
for e in "${PW_ALIAS[@]}"; do
  pw_register "${e%% *}"
  pw_alias "${e%% *}" "${e##* }"
done
pw_prune_symlinks
pw_prune_clients

printf 'OK: browser set deployed to %s: CfT %s, WebKit %s, ffmpeg %s, %s aliases\n' \
  "$BP" "$PIN_CFT_VERSION" "$PIN_WEBKIT_REVISION" "$PIN_FFMPEG_REVISION" "${#PW_ALIAS[@]}"
