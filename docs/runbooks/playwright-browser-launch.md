# Playwright / browse browser launch on Linux

Why the `browse` tool and Playwright e2e fail to launch browsers on this host, and how to restore them. Two independent
causes, neither of which is a cleared browser cache (the binaries under `$PLAYWRIGHT_BROWSERS_PATH` are present and run
fine; reinstalling them fixes nothing).

## Indicators

| Symptom                                                                                         | Cause                                 |
| ----------------------------------------------------------------------------------------------- | ------------------------------------- |
| `browse` / Chromium dies with `FATAL:sandbox/linux/services/credentials.cc … Permission denied` | AppArmor userns profile not loaded    |
| Playwright `browserType.launch: Host system is missing dependencies to run browsers` (WebKit)   | WebKit system libraries not installed |

Chromium e2e projects can still pass while `browse` fails, because Playwright launches its test Chromium
sandbox-disabled while `browse` keeps the sandbox on.

## Root cause

1. **Chromium sandbox.** Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks the user
   namespace Chromium's sandbox needs. `config/apparmor.d/playwright` grants `userns` to the Playwright Chromium
   binaries to fix this. It is deployed to `/etc/apparmor.d/`, but **Ubuntu's own `apparmor.service` is skipped at boot
   on this minimized server** (`systemctl show apparmor.service -p ConditionResult` prints `no`, and `journalctl -b -u
   apparmor.service` is empty), so the profile silently drops on every reboot. `apparmor-playwright.service` (a oneshot
   that runs `apparmor_parser -r` at boot) loads it independently so it survives reboots.

2. **WebKit deps.** Playwright's `webkit` browser is WebKitGTK (the engine behind Safari, including iOS/iPadOS Safari —
   the `mobile-ios` and `tablet` e2e projects). It needs `libgtk-4-1`, the `gstreamer1.0` set, `libavif16`,
   `libenchant-2-2`, `libflite1`, `libhyphen0`, `libwoff1`, `libgraphene-1.0-0`, and more (~180 apt packages). These are
   `/usr/lib` packages, so a `~/.cache` clear cannot remove them, and `playwright install` does not restore them — only
   `playwright install-deps` does.

## Restore (and fresh-machine setup)

Run as your normal user (it escalates to sudo where needed):

```bash
# Chromium / browse only (light; the default):
scripts/playwright-deps-deploy.sh

# Also Safari/iOS e2e (WebKit, heavy ~380 MB):
scripts/playwright-deps-deploy.sh --webkit
```

The default deploys the AppArmor profile and enables `apparmor-playwright.service` so it persists across reboots. The
`--webkit` (and `--chromium`, `--all`) flags additionally install the browser system libraries. WebKit deps are opt-in
because they are heavy and only needed for Safari/iOS testing.

## Verify

```bash
systemctl is-enabled apparmor-playwright.service                       # → enabled
~/.claude/skills/gstack/browse/dist/browse goto https://example.com    # → Navigated (200)
# WebKit, from a Playwright project:
bun run test:e2e --project=tablet --project=mobile-ios                  # → passes, no launch error
```
