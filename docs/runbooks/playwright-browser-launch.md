# Playwright / browse browser launch

Why the `browse` tool and Playwright e2e fail to launch browsers on this host, and how to restore them. Three
independent causes on Linux; on a Mac only the first applies.

## The browser set

One Chrome for Testing (CfT) build with its headless shell, one WebKit build, and one ffmpeg build serve every
Playwright on a host. `scripts/playwright-browsers-deploy.sh` provisions them into the shared cache
(`$PLAYWRIGHT_BROWSERS_PATH`, exported by `config/shell/caches.sh` as `~/.cache/playwright`), on the Linux server and on
Apple silicon Macs, from the pin `config/playwright/browsers.pin`. **Repos never run `playwright install` themselves.**
A repo's Playwright, at 1.57 or later, finds the browsers it asks for through aliases, so its `playwright install` is an
instant no-op. Which Playwright a repo pins does not change which browsers a host holds; the set moves by editing the
pin.

The cache holds:

| Entry                                                             | What it is                                                                        |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `chromium-<N>`, `chromium_headless_shell-<N>`                     | the CfT build, numbered `build * 1000 + patch` (`157.0.8103.38` is 8103038)       |
| `webkit-<revision>`, `ffmpeg-<revision>`                          | Playwright's own builds, at the revisions the pin names                           |
| `chromium-<rev>`, `chromium_headless_shell-<rev>`, `ffmpeg-<rev>` | symlinks to the real directories, one per revision a released Playwright asks for |
| `webkit-<rev>`                                                    | symlinks to the real WebKit for every older revision, never a newer one           |
| `.links/dotfiles-<directory>`, `.dotfiles/clients/<directory>/`   | one client per directory and per alias, so Playwright's cleanup keeps them        |

The aliases exist because Playwright pins a build for reproducibility and does not enforce it: it chooses a directory
and a download URL from the revision, then speaks CDP over a pipe with no version check. Chromium and ffmpeg alias in
both directions. WebKit aliases only at or below the set's, because a newer Playwright fails on an older WebKit with a
protocol error midway through a run; a Playwright newer than the set's WebKit fails at once with
`Executable doesn't exist`. Playwright 1.56 and earlier look for `chrome-linux`, so they need `executablePath` or an
upgrade.

### What a deploy does

1. Reads the pin through the one parser, `scripts/playwright-browsers/lib/pin.sh`, which accepts only dotted-numeric
   versions, integer revisions, 64-hex hashes, and the archive names it knows. Download hosts are fixed in
   `scripts/playwright-browsers/lib/plan.sh`, never read from the pin.
2. Registers what already exists, then fetches each archive with `curl` (https only, no redirect followed), holds it to
   the pin's sha256, unpacks it with `unzip` into a stage inside the cache, writes the completion markers and a record
   of the archive's sha256 and URL (`.dotfiles-record`), and renames it into place. A failure before the rename leaves
   the existing directory alone.
3. Points every alias at its real directory by atomic rename, once every directory is verified.
4. Removes only what it can show it made: a stale `dotfiles-*` client in a shape it writes, and a symlink at a
   browser-directory name that points into the cache. An unrecorded real directory at a set or alias name is replaced;
   any other directory, or a symlink pointing outside the cache, stays for `--check` to name.

A directory counts as provisioned only while its executable is present and its record matches the hash the pin names and
the URL its version gives, so a changed version fetches from its own URL and a directory whose executable is gone is
fetched again. A CfT build outside the pin stays on disk and registered, and `--check` reports it as retained.

The first deploy on a host replaces every unrecorded directory at a set or alias name, `chromium-1248` from another
tool's install included, so run it with no browser session open there. A run with no arguments deploys the set. The
deploy takes no Playwright version; a run that passes one exits 2 with `version-argument-removed`.

`scripts/playwright-browsers-deploy.sh` uses `curl` and `unzip` rather than `playwright install` because node's own
extractor deadlocks on this host: on Node 26 / libuv 1.52.1 the io_uring filesystem backend hangs during archive
extraction on kernel 6.8, and libuv removed the `UV_USE_IO_URING` escape hatch. The download is fine; only node's
extractor wedges.

### Other Playwright installs keep the set

Any `playwright install` or `uninstall`, of any version, records its own package in `$PLAYWRIGHT_BROWSERS_PATH/.links`
and then deletes every browser directory that no `.links` entry names: it reads each entry's `browsers.json` and keeps
`<name>-<revision>` for the first entry of each browser name. A directory provisioned outside Playwright belongs to no
package, so the deploy registers a client of its own for each real directory and each alias, under `.dotfiles/clients/`,
which the cleanup never counts as a browser directory. The cleanup claims revisions as integers, which is why real
directories carry a number. A client's content is rewritten only when it is wrong, through a file outside `.links`
renamed into place, because the cleanup reads an empty or half-written client as broken and deletes every directory no
working client names.

### `--check`

`scripts/playwright-browsers-deploy.sh --check` compares the cache with the pin and changes nothing. It exits 0 with one
`OK:` line on stdout when the set is whole, and exits 1 with one `ERROR:` line per finding on stderr, each carrying a
stable reason from the table below, what it changed (nothing), and a command to run next. It prints the first five
findings of each reason and counts the rest. It reports a missing or incomplete directory, a record that differs from
the pin, an alias that is missing, dangling, pointing at the wrong build, or a real directory, a directory with no
client, a `dotfiles-*` link that names nothing in the set, and any browser directory the pin does not name that no
deploy recorded: the `firefox-*` a bare `playwright install` downloads, or what a consumer below Playwright 1.57
installs.

```text
ERROR: chromium-8103038 is missing or incomplete; reason: directory-incomplete; changed nothing; a deploy restores it; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh
```

`--pin PATH` reads another pin, for checking an edit before it is committed.

### Reasons

Every failure line from `scripts/playwright-browsers-deploy.sh` has the form
`ERROR: <message>; reason: <reason>[; value: <value>]; <what changed>; next: <command>`. A value from a file or the
command line is shown with every character outside letters, digits, `.`, `_`, `-`, and space replaced by `?`, cut to 80
characters. A usage error exits 2 before any work; every other failure exits 1. When `curl`, `unzip`, or another tool
fails in a way the script did not anticipate, the tool's own message comes first and `unexpected-failure` follows.

| Reason                     | Exit | Meaning                                                                                | Fix                                                                               |
| -------------------------- | ---- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `usage`                    | 2    | An unknown option, or `--pin` with no path. Nothing changed.                           | `scripts/playwright-browsers-deploy.sh --help`                                    |
| `version-argument-removed` | 2    | A Playwright version was passed. The pin names the set. Nothing changed.               | Run with no version; to change the set, move the pin.                             |
| `pin-not-found`            | 1    | The pin file does not exist or cannot be read. Nothing changed.                        | Pass a readable file with `--pin`, or leave `--pin` off for the checkout's.       |
| `pin-malformed`            | 1    | A line the parser does not know, or a key that appears twice.                          | Edit the pin: one `key value...` line per field.                                  |
| `pin-invalid-value`        | 1    | A value outside its shape, or a WebKit alias above the set's WebKit.                   | Edit the value named; the shapes are in `scripts/playwright-browsers/lib/pin.sh`. |
| `pin-incomplete`           | 1    | A required key, or a required archive's `sha256` line, is missing.                     | Add the line named.                                                               |
| `running-as-root`          | 1    | The cache must be owned by you. Nothing changed.                                       | Run as your normal user.                                                          |
| `unsupported-platform`     | 1    | The set is built for Linux x86_64 and Apple silicon. Nothing changed.                  | Run on a supported host.                                                          |
| `mac-release-unsupported`  | 1    | The pin has no WebKit archive for this macOS release. Nothing was downloaded.          | Update macOS to the release the message names, or move the pin.                   |
| `tool-missing`             | 1    | `curl`, `unzip`, or a sha256 tool is missing. Nothing changed.                         | Install the tool named.                                                           |
| `archive-fetch-failed`     | 1    | `curl` could not fetch an archive. Nothing moved; the existing set stays.              | Rerun the deploy; if the URL answers 404, the pin names a build that is gone.     |
| `archive-hash-mismatch`    | 1    | A download hashes to something other than the pin's sha256. Nothing moved.             | Do not rerun; recompute the hash from the URL, or the pin is wrong.               |
| `archive-extract-failed`   | 1    | `unzip` could not unpack an archive. Nothing moved.                                    | Rerun the deploy; check the disk.                                                 |
| `archive-incomplete`       | 1    | An archive does not hold the executable Playwright launches. Nothing moved.            | The pin names the wrong archive; compare it with Playwright's registry.           |
| `unexpected-failure`       | 1    | A step failed in a way the script did not expect. The set may be partly updated.       | Rerun the deploy; it finishes the work. Read the tool's message above.            |
| `directory-incomplete`     | 1    | A set directory is missing, a symlink, or lacks its markers or executable.             | Run the deploy.                                                                   |
| `provenance-mismatch`      | 1    | A set directory's record is absent or names another archive or URL.                    | Run the deploy; it fetches that directory again.                                  |
| `alias-missing`            | 1    | An alias the pin asks for does not exist.                                              | Run the deploy.                                                                   |
| `alias-wrong-target`       | 1    | An alias points at another build or at nothing.                                        | Run the deploy.                                                                   |
| `alias-real-directory`     | 1    | A real directory sits at an alias name, as a `--force` install leaves it.              | Run the deploy; it replaces the directory with the alias.                         |
| `client-missing`           | 1    | No correct client registers a directory or alias, so another install deletes it.       | Run the deploy.                                                                   |
| `client-unrecognised`      | 1    | A `.links/dotfiles-*` entry names nothing in the set, and the deploy did not write it. | Inspect it; remove it if nothing needs it.                                        |
| `stray-directory`          | 1    | A browser directory outside the pin that no deploy recorded.                           | Remove it once nothing uses it, with `trash`.                                     |
| `stray-symlink`            | 1    | A symlink at a browser-directory name that is not an alias of the pin.                 | A deploy removes one pointing into the cache; remove others by hand.              |

### Moving the pin

A move is a person editing `config/playwright/browsers.pin` and rerunning the deploy. Everything new is provisioned and
verified before any alias moves.

1. **CfT version.** The Stable channel is the version to follow:

   ```bash
   curl -fsS https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json | jq -r .channels.Stable.version
   ```

   Set `cft-version`. A build's directory number is its build and patch, so two versions with the same build and patch
   under different majors collide; the record catches it, and the deploy fetches from the version's own URL.
2. **WebKit and ffmpeg.** Read them from `browsers.json` in the newest Playwright release's npm tarball, without
   installing it, and record the tarball's sha256 as `source-sha256`:

   ```bash
   npm view playwright-core version
   curl -fsS -o /tmp/pw.tgz https://registry.npmjs.org/playwright-core/-/playwright-core-<version>.tgz
   sha256sum /tmp/pw.tgz
   tar -xzOf /tmp/pw.tgz package/browsers.json | jq -r '.browsers[] | select(.name == "webkit" or .name == "ffmpeg") | "\(.name) \(.revision)"'
   ```

   Set `source-release`, `source-sha256`, `webkit-revision`, and `ffmpeg-revision`.
3. **Alias lists.** Repeat the `browsers.json` read for every release from 1.57.0 to the newest. `chromium-aliases` and
   `ffmpeg-aliases` list every Chromium and ffmpeg revision those files name; `webkit-aliases` lists every WebKit
   revision below the set's.
4. **Archive hashes.** Hash each archive from its URL, one `sha256` line each:

   ```bash
   curl -fsS https://storage.googleapis.com/chrome-for-testing-public/<version>/linux64/chrome-linux64.zip | sha256sum
   curl -fsS https://cdn.playwright.dev/builds/webkit/<revision>/webkit-ubuntu-24.04.zip | sha256sum
   ```

   The archives are `chrome-linux64.zip`, `chrome-headless-shell-linux64.zip`, `webkit-ubuntu-24.04.zip`,
   `ffmpeg-linux.zip`, their `mac-arm64` counterparts `chrome-mac-arm64.zip`, `chrome-headless-shell-mac-arm64.zip`,
   `ffmpeg-mac-arm64.zip`, and one `webkit-mac-<14|15|26>-arm64.zip` per macOS release the WebKit build supports. A 404
   for a macOS release's WebKit means that release is unsupported: leave its line out, and a Mac on it is refused.
   `https://cdn.playwright.dev/builds/` serves WebKit and ffmpeg directly; Playwright's `/dbazure/` path redirects to
   another host, which the deploy does not follow.
5. **Library.** `library-version` is the Playwright the repos' tests run, and `library-sha256` is its `playwright-core`
   tarball's sha256. The test suite fetches that tarball by the hash, so a wrong value fails CI.
6. **Check, then deploy.** `scripts/playwright-browsers-deploy.sh --pin config/playwright/browsers.pin --check` shows
   the differences, `scripts/playwright-browsers-deploy.sh` applies them, and a second `--check` exits 0. Time the first
   deploy on a host with `gtime -f '%e s %M KB'`.

## Indicators

| Symptom                                                                                         | Cause                                                                                  |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Playwright `browserType.launch: Executable doesn't exist at …/<browser>_<revision>/…`           | Set not deployed, or a revision below Playwright 1.57 or a WebKit newer than the set's |
| `Removing unused browser at …/chromium-<N>` in another tool's install output                    | Set not registered in `.links`                                                         |
| `browse` / Chromium dies with `FATAL:sandbox/linux/services/credentials.cc … Permission denied` | AppArmor userns profile not loaded                                                     |
| Playwright `browserType.launch: Host system is missing dependencies to run browsers` (WebKit)   | WebKit system libraries not installed                                                  |

Chromium e2e projects can still pass while `browse` fails, because Playwright launches its test Chromium
sandbox-disabled while `browse` keeps the sandbox on.

## Root cause

1. **Browser binaries.** Provisioned by `scripts/playwright-browsers-deploy.sh` (see above). A missing binary surfaces
   as `Executable doesn't exist at …/<browser>_<revision>/…`; `scripts/playwright-browsers-deploy.sh --check` names what
   is missing, and the deploy restores it.

2. **Chromium sandbox.** Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks the user
   namespace Chromium's sandbox needs. `config/apparmor.d/playwright` grants `userns` to the Playwright Chromium
   binaries to fix this. It is deployed to `/etc/apparmor.d/`, but **Ubuntu's own `apparmor.service` is skipped at boot
   on this minimized server** (`systemctl show apparmor.service -p ConditionResult` prints `no`, and
   `journalctl -b -u apparmor.service` is empty), so the profile silently drops on every reboot.
   `apparmor-playwright.service` (a oneshot that runs `apparmor_parser -r` at boot) loads it independently so it
   survives reboots.

3. **WebKit deps.** Playwright's `webkit` browser is WebKitGTK (the engine behind Safari, including iOS/iPadOS Safari —
   the `mobile-ios` and `tablet` e2e projects). It needs `libgtk-4-1`, the `gstreamer1.0` set, `libavif16`,
   `libenchant-2-2`, `libflite1`, `libhyphen0`, `libwoff1`, `libgraphene-1.0-0`, and more (~180 apt packages). These are
   `/usr/lib` packages, so a `~/.cache` clear cannot remove them, and `playwright install` does not restore them — only
   `playwright install-deps` does.

## Restore (and fresh-machine setup)

Run as your normal user (it escalates to sudo where needed on Linux):

```bash
# Linux: the browser set + AppArmor profile + boot persistence (Chromium / browse). Mac: the browser set.
scripts/playwright-deps-deploy.sh

# Also Safari/iOS e2e (WebKit system libraries, heavy ~380 MB):
scripts/playwright-deps-deploy.sh --webkit
```

`playwright-deps-deploy.sh` always deploys the browser set (via `scripts/playwright-browsers-deploy.sh`); on Linux it
also deploys the AppArmor profile and enables `apparmor-playwright.service` so it persists across reboots. The
`--webkit` (and `--chromium`, `--all`) flags additionally install the browser system libraries, on Linux only. WebKit
deps are opt-in because they are heavy and only needed for Safari/iOS testing. To deploy only the browser set, run
`scripts/playwright-browsers-deploy.sh` directly.

## Verify

```bash
scripts/playwright-browsers-deploy.sh                                  # → NOTE lines for the four directories, then OK
scripts/playwright-browsers-deploy.sh --check                          # → one OK line, exit 0
# From a Playwright project, scoped to the browsers it launches:
./node_modules/.bin/playwright install chromium chromium-headless-shell webkit ffmpeg  # → instant no-op, exit 0
systemctl is-enabled apparmor-playwright.service                       # → enabled (Linux)
~/.claude/skills/gstack/browse/dist/browse goto https://example.com    # → Navigated (200)
# WebKit, from a Playwright project:
bun run test:e2e --project=tablet --project=mobile-ios                  # → passes, no launch error
```

Bare `playwright install` (no browser args) also pulls firefox, which is in Playwright's default set but not the
agentnative e2e suite, and which no alias covers; scope the verify to the browsers the repos launch to keep it a true
no-op. `--check` names the `firefox-*` directory such an install leaves.
