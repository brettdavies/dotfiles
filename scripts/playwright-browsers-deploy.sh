#!/usr/bin/env bash
set -euo pipefail

# Provision the canonical Playwright browser binaries into the shared cache
# ($PLAYWRIGHT_BROWSERS_PATH, exported by config/shell/caches.sh) via curl +
# unzip, so that `playwright install` in any repo is an instant no-op.
#
# WHY curl + unzip instead of `playwright install`:
#   On Node 26 / libuv 1.52.1, the io_uring filesystem backend deadlocks on
#   kernel 6.8 during archive extraction — file writes are submitted to
#   io_uring but the completion never wakes libuv's epoll loop, so the
#   extractor hangs in ep_poll (stalls partway through the largest browser
#   zip, e.g. WidevineCdm/libwidevinecdm.so at ~18MB). libuv 1.52.1 removed
#   the UV_USE_IO_URING escape hatch, so there is no toggle. The download
#   itself is fine; only node's extractor wedges. curl + unzip sidesteps
#   node entirely and produces bit-identical browser directories.
#
# This provisions ONE canonical browser set for the whole machine. Updating
# that version is a dotfiles job (bump REVISIONS below + re-run), not the
# responsibility of an arbitrary repo or e2e test. Repos consume whatever is
# in the shared cache; their `playwright install` becomes a no-op.
#
# Scope: user-space only. It writes browser binaries into the shared cache and
# never runs sudo/apt. The apt system libraries (WebKit needs ~180 packages)
# and the Chromium AppArmor userns profile are handled by the sibling script
# scripts/playwright-deps-deploy.sh, which this script is invoked from.
#
# Idempotent: any browser whose target directory already carries the
# INSTALLATION_COMPLETE marker is skipped. A partial download never leaves a
# marker behind, so an interrupted run is safe to re-run.
#
# Usage:
#   scripts/playwright-browsers-deploy.sh            # provision default version (1.62.1)
#   scripts/playwright-browsers-deploy.sh 1.61.1     # provision an explicit version
#
# On non-Linux it is a no-op (the io_uring deadlock is Linux-only, and the
# CFT/dbazure zips this fetches are the linux64 builds).

# --- Canonical version → revision map ---
#
# To bump the machine's canonical Playwright version:
#   1. Pick the new version (e.g. 1.60.0).
#   2. Read its revisions from a repo's node_modules:
#        jq . node_modules/playwright-core/browsers.json
#      (fields: revision per browser, and browserVersion for chromium — the
#      Chrome-for-Testing CDN path is keyed on browserVersion, not revision).
#   3. Add a case below mapping the version to CHROMIUM_REV, HEADLESS_REV,
#      WEBKIT_REV, FFMPEG_REV, and CFT_VERSION.
#   4. Set DEFAULT_VERSION if this becomes the new canonical version.
#   5. Re-run the script (old browser dirs stay; new ones are fetched).

DEFAULT_VERSION="1.62.1"
VERSION="${1:-$DEFAULT_VERSION}"

case "$VERSION" in
  1.62.1)
    # Verified against node_modules/playwright-core/browsers.json (playwright 1.62.1).
    CHROMIUM_REV="1234"
    HEADLESS_REV="1234"
    WEBKIT_REV="2336"
    FFMPEG_REV="1011"
    CFT_VERSION="151.0.7922.34" # chromium browserVersion → Chrome-for-Testing CDN path
    ;;
  1.61.1)
    # Verified against node_modules/playwright-core/browsers.json (playwright 1.61.1).
    CHROMIUM_REV="1228"
    HEADLESS_REV="1228"
    WEBKIT_REV="2311"
    FFMPEG_REV="1011"
    CFT_VERSION="149.0.7827.55" # chromium browserVersion → Chrome-for-Testing CDN path
    ;;
  1.59.1)
    # Verified against node_modules/playwright-core/browsers.json (playwright 1.59.1).
    CHROMIUM_REV="1217"
    HEADLESS_REV="1217"
    WEBKIT_REV="2272"
    FFMPEG_REV="1011"
    CFT_VERSION="147.0.7727.15" # chromium browserVersion → Chrome-for-Testing CDN path
    ;;
  *)
    echo "FATAL: no revision map for Playwright $VERSION" >&2
    echo "       add a case in $(basename "$0") (see the 'To bump' comment) and re-run" >&2
    exit 1
    ;;
esac

# --- Lagging-consumer chromium revisions (aliased to the canonical build) ---
#
# Tools that embed their own Playwright (crawl4ai, patchright, e2e runners) pin
# a chromium revision and resolve it by exact path
# (<browsers>/chromium-<rev>/chrome-linux64/chrome). A tool one Playwright
# version behind the canonical set asks for a revision the canonical set does
# not carry, and with PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 its launch fails
# ("Executable doesn't exist") rather than silently fetching a third browser
# build. Instead of provisioning another ~450 MB Chrome-for-Testing build per
# lagging tool, alias the wanted revision to the canonical one: one physical
# chromium on disk serves every consumer. The CfT directory layout is identical
# across adjacent builds, so a one-version-off driver launches the canonical
# binary fine (Playwright itself supports channel="chrome" against arbitrary
# system Chrome versions).
#
# Add a revision here when a tool pins a Playwright whose chromium the canonical
# set does not already provide:
#   crawl4ai 0.8.9 / patchright → Playwright 1.60.0 → chromium 1223
#   repos exact-pinning @playwright/test 1.61.1 → chromium 1228
CONSUMER_CHROMIUM_REVS=(1223 1228)

# --- CDN host ---
#
# Derived from `playwright install --dry-run` on this machine (host is stable
# across the CFT and dbazure build paths). If Playwright moves the host, update
# here — the dry-run output is the source of truth (its "Download url:" lines).
CDN="https://cdn.playwright.dev"

# --- Pre-flight ---

if [ "$(uname -s)" != "Linux" ]; then
  echo "NOTE: not Linux — the io_uring extractor deadlock is Linux-only and these are linux64 builds. Nothing to do."
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "FATAL: run as your normal user, not root — the browser cache must be owned by you" >&2
  exit 1
fi

for tool in curl unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FATAL: $tool not found — required to fetch and extract browser archives" >&2
    exit 1
  fi
done

BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/playwright}"
mkdir -p "$BROWSERS_PATH"

# --- Temp workspace (cleaned on exit) ---

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pw-browsers.XXXXXX")"
cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$TMP_DIR" 2>/dev/null || rm -rf "$TMP_DIR"
  else
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# --- Provision one browser: dirname, download URL ---
#
# Downloads to a temp zip, extracts into a temp staging dir, then atomically
# moves the staged dir into place and writes the marker files. A failed curl or
# unzip aborts (set -e) before any marker is written, so a partial dir is never
# treated as a real install.

provision() {
  local dirname="$1" url="$2"
  local dest="$BROWSERS_PATH/$dirname"

  if [ -f "$dest/INSTALLATION_COMPLETE" ]; then
    echo "SKIP: $dirname already provisioned (INSTALLATION_COMPLETE present)"
    return 0
  fi

  echo "NOTE: provisioning $dirname"
  echo "      url: $url"

  local zip="$TMP_DIR/$dirname.zip"
  local stage="$TMP_DIR/$dirname"

  curl -fSL --retry 3 --retry-delay 2 -o "$zip" "$url"

  mkdir -p "$stage"
  unzip -q "$zip" -d "$stage"

  # Mirror the real installer's completion markers so Playwright treats this as
  # a genuine install (INSTALLATION_COMPLETE short-circuits the re-download
  # check; DEPENDENCIES_VALIDATED skips host-dependency revalidation).
  : >"$stage/INSTALLATION_COMPLETE"
  : >"$stage/DEPENDENCIES_VALIDATED"

  # Atomic swap: remove any stale/partial dest, then move the staged dir in.
  if [ -e "$dest" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$dest" 2>/dev/null || rm -rf "$dest"
    else
      rm -rf "$dest"
    fi
  fi
  mv "$stage" "$dest"

  echo "OK:   $dirname provisioned"
}

# --- Provision the full default browser set ---
#
# Chromium and chromium-headless-shell are Chrome-for-Testing builds, keyed on
# the Chrome browserVersion (CFT_VERSION). WebKit and ffmpeg are Playwright's
# own builds, keyed on the playwright revision under the dbazure path.
# Directory names match Playwright's <name>_<revision> / <name>-<revision>
# convention exactly (underscore for chromium-headless-shell, hyphen elsewhere).

echo "NOTE: provisioning Playwright $VERSION browsers into $BROWSERS_PATH"

provision "chromium-${CHROMIUM_REV}" \
  "$CDN/builds/cft/${CFT_VERSION}/linux64/chrome-linux64.zip"

provision "chromium_headless_shell-${HEADLESS_REV}" \
  "$CDN/builds/cft/${CFT_VERSION}/linux64/chrome-headless-shell-linux64.zip"

provision "webkit-${WEBKIT_REV}" \
  "$CDN/dbazure/download/playwright/builds/webkit/${WEBKIT_REV}/webkit-ubuntu-24.04.zip"

provision "ffmpeg-${FFMPEG_REV}" \
  "$CDN/dbazure/download/playwright/builds/ffmpeg/${FFMPEG_REV}/ffmpeg-linux.zip"

# --- Alias lagging-consumer revisions to the canonical chromium ---
#
# A relative symlink so the cache stays relocatable. Never clobbers a real
# install: if a genuine <name>-<rev> directory is already present it is left
# untouched (an existing symlink is refreshed).

link_consumer_alias() {
  local rev="$1"
  if [ "$rev" = "$CHROMIUM_REV" ]; then
    return 0 # consumer already matches canonical; no alias needed
  fi
  local pair name canon_rev link target
  for pair in "chromium:$CHROMIUM_REV" "chromium_headless_shell:$HEADLESS_REV"; do
    name="${pair%%:*}"
    canon_rev="${pair##*:}"
    link="$BROWSERS_PATH/${name}-${rev}"
    target="${name}-${canon_rev}"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "SKIP: $link is a real install, leaving it"
      continue
    fi
    ln -sfn "$target" "$link"
    echo "OK:   aliased ${name}-${rev} -> ${target}"
  done
}

for rev in "${CONSUMER_CHROMIUM_REVS[@]}"; do
  link_consumer_alias "$rev"
done

echo "OK: Playwright $VERSION browser set provisioned in $BROWSERS_PATH"
echo "    'playwright install' in any repo pinning $VERSION is now a no-op."
