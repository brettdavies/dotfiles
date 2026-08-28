# Playwright / browse browser launch on Linux

Why the `browse` tool and Playwright e2e fail to launch browsers on this host, and how to restore them. Three
independent causes.

## Browser binaries are dotfiles-provisioned

The canonical Playwright browser set for the whole machine is provisioned by `scripts/playwright-browsers-deploy.sh`
into the shared cache (`$PLAYWRIGHT_BROWSERS_PATH`, exported by `config/shell/caches.sh` as `~/.cache/playwright`).
**Repos never run `playwright install` themselves** — with the binaries already in the shared cache, a per-repo
`playwright install` scoped to the provisioned browsers is an instant no-op. One canonical version serves every repo;
updating it is a dotfiles job, not an arbitrary repo's or e2e test's.

The provisioning uses `curl` + `unzip` rather than `playwright install` because node's own extractor deadlocks on this
host: on Node 26 / libuv 1.52.1 the io_uring filesystem backend hangs during archive extraction on kernel 6.8 — file
writes are submitted to io_uring but the completion never wakes libuv's epoll loop, so the extractor stalls in `ep_poll`
partway through the largest zip. libuv 1.52.1 removed the `UV_USE_IO_URING` escape hatch, so there is no toggle. The
download itself is fine; only node's extractor wedges. `curl` + `unzip` sidesteps node and produces bit-identical
browser directories, each carrying the `INSTALLATION_COMPLETE` + `DEPENDENCIES_VALIDATED` markers that make Playwright
treat them as real installs.

**Bumping the canonical version:** edit the revision map in `scripts/playwright-browsers-deploy.sh` (the `case` matching
`$VERSION`) and set `DEFAULT_VERSION`, then re-run the script. Read the new revisions from any repo's
`node_modules/playwright-core/browsers.json` (per-browser `revision`, plus chromium's `browserVersion` for the
Chrome-for-Testing CDN path). The default is **Playwright 1.61.1** (chromium 1228, chromium-headless-shell 1228, webkit
2311, ffmpeg 1011).

## Indicators

| Symptom                                                                                         | Cause                                 |
| ----------------------------------------------------------------------------------------------- | ------------------------------------- |
| Playwright `browserType.launch: Executable doesn't exist at …/<browser>_<revision>/…`           | Browser binaries not provisioned      |
| `browse` / Chromium dies with `FATAL:sandbox/linux/services/credentials.cc … Permission denied` | AppArmor userns profile not loaded    |
| Playwright `browserType.launch: Host system is missing dependencies to run browsers` (WebKit)   | WebKit system libraries not installed |

Chromium e2e projects can still pass while `browse` fails, because Playwright launches its test Chromium
sandbox-disabled while `browse` keeps the sandbox on.

## Root cause

1. **Browser binaries.** Provisioned by `scripts/playwright-browsers-deploy.sh` (see above). A missing or wrong-revision
   binary surfaces as `Executable doesn't exist at …/<browser>_<revision>/…`; re-run the script to restore it.

2. **Chromium sandbox.** Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks the user
   namespace Chromium's sandbox needs. `config/apparmor.d/playwright` grants `userns` to the Playwright Chromium
   binaries to fix this. It is deployed to `/etc/apparmor.d/`, but **Ubuntu's own `apparmor.service` is skipped at boot
   on this minimized server** (`systemctl show apparmor.service -p ConditionResult` prints `no`, and `journalctl -b -u
   apparmor.service` is empty), so the profile silently drops on every reboot. `apparmor-playwright.service` (a oneshot
   that runs `apparmor_parser -r` at boot) loads it independently so it survives reboots.

3. **WebKit deps.** Playwright's `webkit` browser is WebKitGTK (the engine behind Safari, including iOS/iPadOS Safari —
   the `mobile-ios` and `tablet` e2e projects). It needs `libgtk-4-1`, the `gstreamer1.0` set, `libavif16`,
   `libenchant-2-2`, `libflite1`, `libhyphen0`, `libwoff1`, `libgraphene-1.0-0`, and more (~180 apt packages). These are
   `/usr/lib` packages, so a `~/.cache` clear cannot remove them, and `playwright install` does not restore them — only
   `playwright install-deps` does.

## Restore (and fresh-machine setup)

Run as your normal user (it escalates to sudo where needed):

```bash
# Browser binaries + AppArmor profile + boot persistence (Chromium / browse):
scripts/playwright-deps-deploy.sh

# Also Safari/iOS e2e (WebKit system libraries, heavy ~380 MB):
scripts/playwright-deps-deploy.sh --webkit
```

`playwright-deps-deploy.sh` always provisions the browser binaries (via `scripts/playwright-browsers-deploy.sh`),
deploys the AppArmor profile, and enables `apparmor-playwright.service` so it persists across reboots. The `--webkit`
(and `--chromium`, `--all`) flags additionally install the browser system libraries. WebKit deps are opt-in because they
are heavy and only needed for Safari/iOS testing. To provision (or re-provision) only the browser binaries, run
`scripts/playwright-browsers-deploy.sh` directly.

## Verify

```bash
scripts/playwright-browsers-deploy.sh                                  # → SKIP lines for all four (already provisioned)
# From a Playwright project, scoped to the provisioned browsers:
./node_modules/.bin/playwright install chromium chromium-headless-shell webkit ffmpeg  # → instant no-op, exit 0
systemctl is-enabled apparmor-playwright.service                       # → enabled
~/.claude/skills/gstack/browse/dist/browse goto https://example.com    # → Navigated (200)
# WebKit, from a Playwright project:
bun run test:e2e --project=tablet --project=mobile-ios                  # → passes, no launch error
```

Bare `playwright install` (no browser args) also pulls firefox, which is in Playwright's default set but not the
agentnative e2e suite; scope the verify to the four provisioned browsers to keep it a true no-op.
