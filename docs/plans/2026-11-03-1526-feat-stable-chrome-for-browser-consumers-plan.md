---
title: Stable Google Chrome for the Machine's Browser Consumers - Plan
type: feat
date: 2026-11-03
topic: stable-chrome-for-browser-consumers
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Stable Google Chrome for the Machine's Browser Consumers - Plan

## Goal Capsule

- **Objective:** Every tool on the Linux server and the Mac that opens web pages Brett does not control runs a Chrome
  that carries Google's current stable security fixes, with its sandbox on and certificate checks enforced.
- **Means:** Google Chrome stable, installed from Google's signed apt repository on the Linux server and kept current by
  the host's unattended upgrades. On the Mac it is the existing install, kept current by Google's own updater. Consumers
  reach it by Playwright's `chrome` channel or an executable path.
- **Product authority:** Requirements govern behavior and Key Decisions record why. The measurements in this plan are
  the evidence. Where a solutions doc or runbook disagrees with a measurement here, the doc is what gets rewritten. The
  scope of the pinned-download removal waits on Brett's answer to the first Outstanding Question.
- **Open blockers:** Brett decides the local browser for the e2e suites, whether Chrome is exempt from the seven-day
  gate, and what gstack's headed sessions run on (Resolve Before Planning). The sandbox at Chrome's real install path is
  measured at the first deploy, before any consumer is pointed at it.
- **Execution profile:** System package plus apt configuration, applied by the operator because the agent's settings
  deny `sudo`. Plus dotfiles shell config, provisioning-script trimming, and doc updates, and one upstream gstack issue
  Brett files. Proof is runtime measurement on both machines. bats covers the script seams.
- **Stop conditions:** Stop and bring the finding to Brett if stable Chrome at `/opt/google/chrome/chrome` cannot start
  with its sandbox on, if the unattended-upgrade run does not pick Chrome up from Google's origin, or if an e2e suite
  fails on stable Chrome where it passes on the pinned build.
- **Who finishes:** `ce-plan` enriches this file in place. The operator runs every `/etc` step. Brett files the gstack
  issue.

---

## Product Contract

### Summary

Install Google Chrome stable on the Linux server from Google's apt repository and let unattended upgrades keep it
current. Leave the Mac's Google-updated Chrome as it is. Point every consumer that opens untrusted pages at it with the
sandbox on: gstack browse, crawl4ai, and agent scripts. Dotfiles keeps provisioning a Playwright-pinned Chromium only if
Brett keeps local e2e runs on the pin (first Outstanding Question).

The recommendation splits consumers by trust boundary. Browsing agents move to stable Chrome now, because that is where
the measured security gap is. The e2e suites keep the pin in CI. Brett decides whether they also leave it locally, and
that choice is what would let the dotfiles Chromium download go away entirely.

### Problem Frame

Today the Linux server runs every browser consumer on Chrome for Testing builds that Playwright pins, provisioned by
`scripts/playwright-browsers-deploy.sh` into `$PLAYWRIGHT_BROWSERS_PATH`. Brett's question is whether that download can
go, replaced by a regular Chrome the machine keeps updated itself. He raised it after Playwright's guidance that the
pinned build "can miss Chrome security fixes until the next Playwright release" and runs sandbox-off by default ("Do not
use it on the hostile web").

The measurements below confirm both halves of that warning on this host. Both pinned builds still trust a CA
intermediate whose key was compromised on 2026-10-17. The canonical set predates two Chrome fixes that Google reports as
exploited in the wild. crawl4ai and every Playwright default launch run with `--no-sandbox`. Meanwhile the pinned set
carries its own upkeep: a revision map per Playwright version, alias symlinks for lagging tools, an io_uring extractor
workaround, and the `.links` registration from PR #431. On 2026-11-03 another tool's `playwright install` deleted the
canonical set and broke three repos' e2e at once.

### Measured Findings

Measured on the Linux server (Ubuntu 24.04.5, kernel 6.8.0-146, `kernel.apparmor_restrict_unprivileged_userns = 1`) and
read-only on the Mac (macOS 27.0, arm64), 2026-11-03. Chrome stable 156.0.8078.79 and 157.0.8103.38 were taken from
Google's apt repository: each sha256 matched the Packages index, and each was extracted into a scratch directory, not
installed.

| Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Evidence                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Playwright 1.61.1 resolves chromium 1228 to the 1234 alias, Chrome 151.0.7922.34. gstack's and crawl4ai's Playwright 1.64.1 run chromium 1248, Chrome for Testing 156.0.8078.4.                                                                                                                                                                                                                                                                              | `browser.version()` from each package's `chromium.launch()`; the browsers.json of 1.64.1                                           |
| Playwright's default launch passes `--no-sandbox`, and no child process gets its own user or PID namespace. With `chromiumSandbox: true` the pinned headless shell gets both namespaces and seccomp filter mode, under the dotfiles `playwright-chromium-headless` AppArmor label (the profile attaches through the alias symlink).                                                                                                                          | `/proc/<pid>/cmdline`, `ns/user`, `ns/pid`, `status`, `attr/current` of the browser tree                                           |
| Both pinned builds (151.0.7922.34 and 156.0.8078.4) load `https://dv-g3b-emudhra.we-have-a-problem.com/` with status 200 and the page's "That's bad!" text. Stable 156.0.8078.79, launched by Playwright with its default `--disable-component-update`, rejects it with `net::ERR_CERT_REVOKED`.                                                                                                                                                             | navigation through Playwright on each build                                                                                        |
| Chrome for Testing 151.0.7922.34 predates two fixes Google reports as exploited in the wild: CVE-2026-85046 (fixed in 152.0.7977.82, 2026-09-03) and CVE-2026-87491 (fixed in 153.0.8010.36, 2026-09-08). 156.0.8078.4 predates the four Criticals fixed in 156.0.8078.73 (2026-10-27: CVE-2026-118306, -118331, -118348, -118344) and CVE-2026-76024 (156.0.8078.79, 2026-10-29). Chrome 157.0.8103.38 went stable on 2026-11-03 with seven more Criticals. | Chrome Releases stable-channel posts                                                                                               |
| No Playwright release since 1.64.1 (2026-10-14). Playwright main (1.65.0-alpha-2026-11-03) pins 158.0.8127.2, which matches Chrome's current beta.                                                                                                                                                                                                                                                                                                           | npm registry times; the alpha's browsers.json                                                                                      |
| Playwright 1.61.1 drives full Chrome through `executablePath`: lmgroktfy's suite passes 16/16 on 156.0.8078.79 (22.3 s) and on 157.0.8103.38 (25.9 s, 22.1 s), against 16/16 on the pinned build (22.0 s, 22.3 s). Peak RSS is about 225 MB on full Chrome against 205 MB on the pinned headless shell. Host load average was about 29 throughout.                                                                                                           | scratch config over the repo's tests and `dist/`; `gtime -f '%e s %M KB'`, one or two runs each                                    |
| At a path no AppArmor profile covers, Chrome 156 with its sandbox on falls back to the setuid helper and aborts because the scratch copy is not root-owned mode 4755. With `--no-sandbox` it renders and no library is missing.                                                                                                                                                                                                                              | direct headless launch; `ldd`                                                                                                      |
| `channel: 'chrome'` resolves only to `/opt/google/chrome/chrome`.                                                                                                                                                                                                                                                                                                                                                                                            | Playwright 1.61.1 launch error; coreBundle.js in 1.64.1                                                                            |
| Ubuntu's `apparmor` package ships `/etc/apparmor.d/chrome`, granting `userns` to `/opt/google/chrome/chrome`, and it is loaded on the current boot as `chrome`. Google's deb ships its own equivalent profile and installs it only when Ubuntu's is absent.                                                                                                                                                                                                  | `dpkg -S`, `/sys/kernel/security/apparmor/policy/profiles/`, the deb's postinst                                                    |
| On the current boot (2026-10-05) `apparmor.service` ran and loaded `/etc/apparmor.d`. The runbook says it is skipped at boot on this host.                                                                                                                                                                                                                                                                                                                   | `systemctl show apparmor.service -p ConditionResult` is `yes`; `journalctl -b -u apparmor.service`                                 |
| Installing the deb installs `/opt/google/chrome` with a setuid `chrome-sandbox` and adds Google's apt source with the keyring `/usr/share/keyrings/google-chrome.gpg`. It also adds `/etc/cron.daily/google-chrome`, which keeps that source in place, creates a `chromemgmt` group, and registers update-alternatives for `google-chrome` and `x-www-browser`.                                                                                              | the deb's control files and payload                                                                                                |
| Google's apt index lists one version per channel. On 2026-11-03, the day Chrome 157 went stable, amd64 stable was 156.0.8078.79 at 12:14 UTC and 157.0.8103.38 from 21:28 UTC. The arm64 index already listed 157.0.8103.38 at 21:37 UTC.                                                                                                                                                                                                                    | `dists/stable/main/binary-{amd64,arm64}/Packages.gz`, `Release` Last-Modified                                                      |
| unattended-upgrades is enabled on the Linux server, but its Allowed-Origins cover only Ubuntu's own origins. The repository's `Origin: Google LLC` is not among them. unattended-upgrade builds its origin list from `Allowed-Origins` plus every `Origins-Pattern` entry, so a separate drop-in adds an origin without replacing the stock list.                                                                                                            | `/etc/apt/apt.conf.d/50unattended-upgrades`; `/usr/bin/unattended-upgrade:787-797`; `systemctl is-enabled apt-daily-upgrade.timer` |
| The Mac runs Google Chrome 156.0.8078.80 from Google's own installer, not Homebrew (the `google-chrome` cask reports not installed, `auto_updates`), and Google's user-level updater is present.                                                                                                                                                                                                                                                             | `defaults read`, `brew info --cask`, `~/Library/Application Support/Google/GoogleUpdater`                                          |
| GitHub's Ubuntu 24.04 runner image 20261026 ships Google Chrome 156.0.8078.47.                                                                                                                                                                                                                                                                                                                                                                               | actions/runner-images `Ubuntu2404-Readme.md`                                                                                       |
| Lighthouse CI cannot find a Chrome on the Linux server today: chrome-launcher 0.13.4 raises `ERR_LAUNCHER_PATH_NOT_SET`. Both repos' `.lighthouserc.json` set `--no-sandbox` and no `chromePath`.                                                                                                                                                                                                                                                            | `Launcher.getInstallations()` from agentnative-site's install                                                                      |
| None of the four e2e suites uses screenshot or snapshot assertions.                                                                                                                                                                                                                                                                                                                                                                                          | search of the suites' specs                                                                                                        |

### Consumer Risk

Who opens pages Brett does not control, on which browser, with or without the sandbox. "Pinned" means Chrome for Testing
as provisioned by Playwright or dotfiles.

| Consumer                                                                                    | Machine                           | Pages it opens                                                                   | Browser today                                                        | Sandbox today                                                | Under this plan                                                            |
| ------------------------------------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| gstack browse (`/browse`, `/qa`, `/scrape`, handoff, cookie import)                         | Linux, gstack 1.94.33.0           | arbitrary URLs, including credentialed sessions                                  | pinned 156.0.8078.4                                                  | on, through the dotfiles AppArmor profile                    | stable Chrome, sandbox on (R6)                                             |
| gstack browse                                                                               | Mac, gstack 1.93.42               | same                                                                             | pinned 151.0.7922.34                                                 | on                                                           | per the gstack headed-session question (R6)                                |
| crawl4ai CLI and the crawl4ai skill's scripts                                               | Linux, 0.9.5 on Playwright 1.64.1 | arbitrary sites                                                                  | pinned 156.0.8078.4                                                  | off (`--no-sandbox` unless `CRAWL4AI_CHROMIUM_SANDBOX=true`) | stable Chrome, sandbox and certificate checks on (R7)                      |
| crawl4ai CLI                                                                                | Mac, 0.7.7 on Playwright 1.56.0   | arbitrary sites                                                                  | none: the Mac cache holds no chromium for 1.56.0 (unverified launch) | off                                                          | stable Chrome, sandbox and certificate checks on (R7)                      |
| Ad hoc agent scripts and scrapers                                                           | both                              | arbitrary sites                                                                  | whatever the script launches, by default pinned with `--no-sandbox`  | off by Playwright default                                    | stable Chrome, sandbox on, by guidance (R8)                                |
| Puppeteer downloads in `~/.cache/puppeteer`                                                 | Linux                             | unknown; no consumer identified                                                  | Chrome for Testing 133.0.6943.141 and 150.0.7871.24 (929 MB)         | unknown                                                      | identified, then repointed or removed (Deferred to Planning)               |
| Codex browser plugin, Cursor `@agentdeskai/browser-tools-mcp@1.2.0`                         | Mac                               | arbitrary sites                                                                  | the Mac's real Chrome 156.0.8078.80                                  | on                                                           | unchanged                                                                  |
| Playwright MCP                                                                              | neither                           | none configured in Claude Code, Claude Desktop, or any `.mcp.json` under `~/dev` | n/a                                                                  | n/a                                                          | not adopted (Scope Boundaries)                                             |
| e2e suites: lmgroktfy, agentnative-site, meum-sites, streamsgrp (`@playwright/test` 1.61.1) | Linux                             | own local builds and own staging or production                                   | pinned 151.0.7922.34 locally; pinned 149 in CI                       | off                                                          | CI keeps the pin (R10); local is Brett's call (first Outstanding Question) |
| Lighthouse CI (agentnative-site, meum-sites)                                                | Linux                             | own site                                                                         | cannot launch locally; runner Chrome in CI                           | off by config                                                | finds stable Chrome locally once R1 lands                                  |

### Key Decisions

- **Split consumers by trust boundary.** Browsing agents move to stable Chrome with the sandbox on, and own-app test
  suites keep a Playwright-pinned build in CI. The measured gap (compromised-CA trust, missing exploited-in-the-wild
  fixes, sandbox off) is all on the browsing side. Playwright's own guidance keeps tests on the pin for reproducibility.
  Governs R6, R7, R8, R10.
- **Google's signed apt repository on Linux, kept current by the host's unattended upgrades.** This is the update path
  Google's package itself installs, and unattended upgrades already run daily on the host. Google's origin joins them
  through an `Origins-Pattern` drop-in, copy-deployed like `config/sysctl.d`, which leaves Ubuntu's stock list as it is.
  The upgrade timer runs `apt.systemd.daily install`, which never refreshes package lists, so a copy-deployed drop-in on
  `apt-daily-upgrade.service` refreshes Google's list alone just before each run (`/usr/lib/apt/apt.systemd.daily` lines
  437 and 491). A dotfiles download script would rebuild what apt provides, the same shape as the pinned-set script this
  plan shrinks. Governs R1, R2.
- **The install is per host, never fleet-wide.** This repo deploys to many headless servers that run no browser, so only
  a host where the operator runs the Chrome deploy gets Chrome, and a host without it keeps its consumers' current
  behavior. Governs R1, R15.
- **One owner for the Chrome executable path.** The per-OS path is defined once in shell config, as the variable agents'
  scripts read too. The gstack pointer, the crawl4ai settings, the guidance, and the R4 check all read it there, so no
  second copy can drift. Governs R6, R7, R8, R15, R18.
- **The Mac keeps Google's own updater, not Homebrew.** Chrome is already installed outside Homebrew and updated by
  Google. The cask declares `auto_updates`, so `brew-upgrade`'s `bu --no-greedy` would never upgrade it anyway. Governs
  R3.
- **Dotfiles adds no AppArmor profile for stable Chrome.** Ubuntu's own `chrome` profile already grants `userns` at the
  install path, and the setuid helper is the fallback when no profile is loaded. Both claims are measured only once the
  package is installed (the first execution gate, Deferred to Planning). Governs R5.
- **gstack moves by pointing, not patching.** `GSTACK_CHROMIUM_PATH` reaches every browse launch path, so dotfiles sets
  it and edits nothing inside gstack. The same variable drives headed sessions, where branded Chrome drops gstack's side
  panel, so where it is set is the gstack headed-session question. gstack keeps fetching its own pinned Chromium on each
  Playwright bump until upstream fixes its probes (Dependencies). PR #431's registration keeps that fetch from deleting
  anything else. Governs R6.
- **The pinned-set machinery shrinks to what still launches from it.** It does not disappear outright, because WebKit
  has no system alternative and gstack and crawl4ai still install their own pinned builds into the shared cache. Governs
  R12, R13.

### Requirements

**Install and updates**

- R1. The Linux server has Google Chrome stable installed from Google's signed apt repository at its standard path. The
  install is declared in dotfiles and applied by a deploy script the operator runs on each host that needs it, never by
  an ad hoc `sudo` command.
- R2. Chrome on the Linux server updates without operator action within a day of Google publishing a new stable build to
  its apt repository. Each unattended-upgrade run refreshes Google's package list first, because the stock timers can
  run the upgrade on lists up to a day and a half old.
- R3. The Mac keeps its existing Google-updated Chrome. Dotfiles neither installs a second copy nor moves it under
  Homebrew.
- R4. A check that changes nothing fails when an installed Chrome is older than a stable build that an unattended run
  has already had the chance to install, or when the host's unattended upgrades do not cover it, and names the command
  that fixes it. A build newer than the last unattended run is noted as pending, not failed.

**Sandbox**

- R5. Stable Chrome launched from Playwright with `chromiumSandbox: true` starts with Chromium's sandbox active on the
  Linux server, under the host's userns restriction, without the dotfiles Playwright AppArmor profile.

**Browsing agents**

- R6. gstack browse on both machines opens pages in stable Chrome with its sandbox on, through every launch path that
  opens a page, within the bounds of the gstack headed-session question. gstack's install probe, which renders a local
  test page in a pinned build, is outside R6 and R9 until upstream honors `GSTACK_CHROMIUM_PATH` in it.
- R7. crawl4ai on both machines (the CLI, the crawl4ai skill's scripts, and repos that import it) launches stable Chrome
  with its sandbox on and certificate errors enforced. crawl4ai takes its browser per caller, not from the environment,
  so each covered caller sets the Chrome channel, the sandbox opt-in, and `ignore_https_errors` off. Each runs a
  crawl4ai that honors `CRAWL4AI_CHROMIUM_SANDBOX` (0.9.5 does; 0.8.9 and earlier always pass `--no-sandbox`).
- R8. The guidance agents read before writing browser automation tells any script that opens pages Brett does not
  control to launch the Chrome binary dotfiles names, with the sandbox on. That guidance is the always-loaded
  `stow/claude/dot-claude/CLAUDE.md`, the CLI tools guide, and the browser-related skills. For Playwright its form is
  `executablePath` from the dotfiles-owned variable with `chromiumSandbox: true`, which works on both machines;
  `channel: 'chrome'` is equivalent only where Chrome is installed at the Linux path.
- R9. No browsing agent on either machine passes `--no-sandbox` outside a context where the sandbox cannot work (root, a
  container, CI).

**Test suites**

- R10. Each e2e suite's CI keeps running its Chromium-family projects on the Playwright-pinned build.
- R11. If Brett picks stable Chrome as the local default (first Outstanding Question), each e2e suite runs its
  Chromium-family projects on stable Chrome locally through one switch with the same name in every suite.

**Provisioning**

- R12. The dotfiles-provisioned Playwright set carries only the browsers some consumer on the machine still launches
  from it. Its registration with Playwright's cleanup, its `--check`, and its aliases cover exactly that set.
- R13. No AppArmor grant stays deployed on a host for a browser binary that nothing on that host launches with its
  sandbox on. The Playwright profile stays in the repo while any host can still fall back to a pinned build (R15).

**Docs**

- R14. The always-loaded `stow/claude/dot-claude/CLAUDE.md`, the Playwright runbook, the CLI tools guide, and the
  solutions docs on Playwright launch describe which consumers use stable Chrome and which use a pinned build, and why.
  Each states the boot-time AppArmor behavior as measured.

**Hosts without Chrome, processes an upgrade left behind, and failure output**

- R15. A host without stable Chrome keeps gstack and crawl4ai on their current browser. Dotfiles never points a consumer
  at a Chrome binary that is absent, and on such a host the R4 check only notes the absence. New scripts follow R18
  instead.
- R16. The R4 check also reports any running Chrome process still on an executable an upgrade replaced, and names the
  restart that picks up the new build.
- R17. Each R4 failure carries a stable reason from a closed set, the values it compared (installed and offered
  versions, the configuration file read), and the fix command, on stderr with a non-zero exit.
- R18. A script following the R8 guidance on a host without stable Chrome stops and names the operator's deploy command.
  It never falls back to a pinned build for pages Brett does not control and never runs `playwright install chrome`. A
  bare `executablePath` from an unset variable is `undefined`, which silently launches the bundled build, so the
  guidance checks the variable before launching.

### Acceptance Examples

- AE1. **Covers R6, R9.** **Given** stable Chrome is installed and gstack is pointed at it, **when**
  `browse goto https://dv-g3b-emudhra.we-have-a-problem.com/` runs, **then** the navigation fails with a certificate
  error, and the browser's renderer processes run in their own user namespace.
- AE2. **Covers R2, R4, R17.** **Given** Google publishes a new stable build, **when** the host's next daily
  unattended-upgrade run completes, **then** the installed version matches it and the R4 check passes; the time from the
  build entering Google's index to its install is under a day. **Given** a build Google published after the last
  unattended run started, **when** the R4 check runs, **then** it notes the pending upgrade and exits 0. **Given**
  Google's origin is missing from the unattended-upgrade configuration, **when** the R4 check runs after an unattended
  run has had the chance to install a build, **then** it exits non-zero with a stable reason, the configuration file it
  read, and the deploy command.
- AE3. **Covers R5.** **Given** stable Chrome is installed, **when** Playwright launches it with `channel: 'chrome'` and
  `chromiumSandbox: true` on a boot where Ubuntu's `chrome` profile is loaded, **then** it starts and its renderers have
  their own user and PID namespaces. **When** the same launch runs with that profile unloaded, **then** it still starts
  sandboxed through the setuid helper.
- AE4. **Covers R7, R9.** **Given** crawl4ai is configured by dotfiles, **when** it crawls a page, **then** the browser
  process is `/opt/google/chrome/chrome` (or the Mac's Chrome) and its command line carries no `--no-sandbox`. **When**
  it crawls `https://dv-g3b-emudhra.we-have-a-problem.com/`, **then** the crawl fails with a certificate error, as AE1
  does for gstack.
- AE5. **Covers R11, R12.** **Given** Brett chose stable Chrome as the local default, **when** the deploy script's
  `--check` runs, **then** it passes with no chromium or headless-shell directory and no chromium aliases in the set.
  lmgroktfy's, meum-sites', and streamsgrp's suites, and agentnative-site's Chromium-family projects, pass locally on
  stable Chrome. agentnative-site's WebKit projects still pass on the provisioned WebKit.
- AE6. **Covers R10.** **Given** any of the four suites opens a pull request, **when** CI runs its e2e job, **then** the
  Chromium projects run on the pinned build that the suite's `@playwright/test` version installs, as they do today.
- AE7. **Covers R15.** **Given** a host where the Chrome deploy never ran, **when** a shell starts and gstack browse
  launches, **then** `GSTACK_CHROMIUM_PATH` is unset, browse launches its own pinned build as it does today, and the R4
  check exits 0 with a note that Chrome is not installed.
- AE8. **Covers R16.** **Given** a gstack browse daemon started before the morning's unattended upgrade replaced Chrome,
  **when** the R4 check runs, **then** it names that process and the command that restarts it.
- AE9. **Covers R18.** **Given** a host without stable Chrome, **when** an agent's script launches a browser the way the
  guidance says, **then** it exits before opening any page with a message that the host has no stable Chrome and names
  the deploy command, rather than Playwright's `Run "npx playwright install chrome"`.

### What Happens to the Pinned-Browser Machinery

| Item                                                             | Today                                                                     | Under the recommendation                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/playwright-browsers-deploy.sh`                          | provisions chromium, headless shell, WebKit, ffmpeg for Playwright 1.62.1 | provisions WebKit and ffmpeg only if Brett picks stable Chrome for local e2e. Otherwise it is unchanged, because the e2e suites still launch chromium from it.                                                                                                                                                       |
| Chromium aliases 1223 and 1228                                   | serve crawl4ai 0.8.9 (now 0.9.5, which uses 1248) and the 1.61.1 suites   | 1223's named consumer, crawl4ai 0.8.9, has moved to 1248, and no other Playwright 1.60.0 consumer was found. 1228 goes with the chromium entries above.                                                                                                                                                              |
| PR #431's `.links` registration and `--check`                    | registers the whole set                                                   | still needed for whatever the set keeps, because gstack's and crawl4ai's installs still run Playwright's cleanup against the shared cache                                                                                                                                                                            |
| gstack's own `playwright install chromium`                       | fetches 1248 into the shared cache when its probe fails                   | unchanged until upstream honors `GSTACK_CHROMIUM_PATH` in its probes (Dependencies). Harmless under #431.                                                                                                                                                                                                            |
| `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`   | one shared cache; no auto-download on `bun install`                       | both stay: WebKit and the tool-pinned builds still land in that one cache                                                                                                                                                                                                                                            |
| `config/apparmor.d/playwright` and `apparmor-playwright.service` | grant `userns` to pinned chromium and headless shell                      | unloaded per host once nothing on that host launches a pinned build sandbox-on (R13): on hosts where the Chrome deploy ran and gstack and crawl4ai point at stable Chrome. The profile stays in the repo while any host can still fall back to a pinned build (R15), and while gstack's headed sessions stay pinned. |
| `scripts/playwright-deps-deploy.sh`                              | entry point for binaries, AppArmor, opt-in apt deps                       | keeps the WebKit apt-deps role. Its `--chromium` flag goes with the chromium entries: it runs `bun x playwright install --with-deps chromium`, which downloads a chromium as well as the deps, and the Chrome deb's own dependencies cover those deps.                                                               |

### Scope Boundaries

- CI moving to `channel: 'chrome'` on the runner's preinstalled Chrome is deferred. The runner image's Chrome
  (156.0.8078.47 in image 20261026) moves on GitHub's schedule, which is the drift the pin exists to prevent.
- WebKit stays Playwright-provisioned. There is no system WebKitGTK build that Playwright drives.
- Playwright MCP is not adopted. None is configured on either machine. If one is ever added, it is pinned to an exact
  version that has cleared the age gate, at least 0.0.40 (CVE-2025-9611), and runs with stable Chrome.
- Browsers in containers or as root keep the sandbox off by necessity. No browser process was running on the Linux
  server at review time, and none of the consumers found runs one in a container.
- Lifting `kernel.apparmor_restrict_unprivileged_userns` host-wide
  (`docs/plans/2026-09-15-1428-feat-unprivileged-userns-host-plan.md`) is independent of this plan, and this plan needs
  no change to it.
- The headed GStack Browser on the Mac is a custom Chromium build and out of scope.
- emdash (an upstream third-party clone) and cf_office_hours (no Playwright config) are out of scope.
- Microsoft Edge is not installed and not proposed.

### Dependencies / Assumptions

- **PR #431 merges before the provisioning work.** The `.links` registration, the deploy script's `--check`, and
  `tests/playwright-browsers-deploy.bats` exist only on that branch, and R12 and AE5 build on them.
- **gstack upstream.** gstack's `ensure_playwright_browser()` in `setup` and its `bin/gstack-browser-ensure` probe with
  a bare `chromium.launch()`, so neither honors `GSTACK_CHROMIUM_PATH`, and `gstack-browser-ensure` ignores
  `GSTACK_SKIP_PLAYWRIGHT`. Skills run `gstack-browser-ensure` on every browser task. Brett files the issue; this plan
  does not wait on it.
- **gstack's CRLSet issue.** garrytan/gstack#3338 reports stable Chrome 155 trusting the eMudhra intermediates through
  `GSTACK_CHROMIUM_PATH`. Stable 156.0.8078.79 rejects them even with component updates disabled (Measured Findings), so
  the fix now ships in the binary. #3440's broader point stands, and it is not bounded by R2. gstack's default headless
  launch keeps Playwright's `--disable-component-update` (only its headed and extension paths strip it), and crawl4ai
  adds the flag itself. Chrome receives a CRLSet only through the component updater. So a revocation Google ships only
  by CRLSet never reaches these agents; R2 bounds only the lag behind a release that compiles the distrust into the
  binary, as 156.0.8078.79 did. The gstack issue Brett files also asks for the headless path to strip that flag.
- **Scripts that ignore the guidance still find a pinned build.** A default `chromium.launch()` from a Playwright 1.64.1
  script resolves gstack's chromium 1248 in the shared cache and runs it with `--no-sandbox`. Nothing errors, so R9 has
  no backstop for such a script while gstack keeps fetching 1248.
- **Ubuntu keeps shipping its `chrome` AppArmor profile.** It is part of the `apparmor` package on 24.04. If a later
  release drops it, Google's deb installs its own.
- **Playwright drives newer stable Chrome.** The measured case is 1.61.1 driving 156. A Chrome major far ahead of a
  suite's `@playwright/test` can eventually break that suite's local runs. Dependabot keeps the suites' Playwright
  moving.
- **Chrome adds about 447 MB and its apt dependencies.** If local e2e moves to stable Chrome, the chromium and
  headless-shell directories it replaces total about 650 MB per Playwright revision.

### Outstanding Questions

**Resolve Before Planning**

- **Should the e2e suites run on stable Chrome by default when run locally?** (Brett) Options: (a) yes: local runs use
  stable Chrome, CI keeps the pin, and dotfiles stops provisioning chromium entirely; (b) no: local and CI both keep the
  pin, and dotfiles keeps provisioning chromium for them. Recommendation: (a). Locally the suites only open their own
  builds and staging, so the security case is nil either way. Exact local and CI parity is already gone: the 1228 alias
  runs Chrome 151 locally while CI runs 149. lmgroktfy passed 16/16 on Chrome 156, no suite uses screenshot assertions,
  and (a) removes the per-version revision map, the aliases, and the extractor workaround for chromium. The cost of (a)
  is a suite that passes locally and fails in CI, or the reverse, on a browser-version difference. (b) is what
  Playwright recommends. Either way, gstack's and crawl4ai's own pinned builds stay in the shared cache until gstack
  honors `GSTACK_CHROMIUM_PATH` in its probes, so (a) ends the dotfiles download, not every pinned download.
- **What do gstack's headed sessions run on?** (Brett) gstack reads one variable, `GSTACK_CHROMIUM_PATH`, for headless,
  headed (`/open-gstack-browser`), and handoff launches. Its headed path loads the side-panel extension with
  `--load-extension`, which branded Chrome ignores (`browse/src/browser-manager.ts:876`: "Real Chrome
  (executablePath/channel) silently blocks --load-extension"). Options: (a) point gstack at stable Chrome on both
  machines and accept that headed and handoff sessions open without the side panel; (b) point it only where headed
  sessions do not run (the Linux server, which has no display) and keep the Mac on gstack's pinned build until gstack
  takes a headless-only variable, which the upstream issue also asks for; (c) hold gstack on its pinned build everywhere
  until upstream separates the paths. Recommendation: (b). The unattended untrusted browsing happens headless on the
  Linux server, and the side panel is the point of a headed session. The Mac's gstack 1.93.42 should move to 1.94.31.0
  or later regardless, where handoff began honoring the variable.
- **Is Chrome exempt from the seven-day release-age gate?** (Brett) Recommendation: yes, recorded as a named exemption
  in the supply-chain guide. Google's apt index serves only the newest stable build, so apt cannot hold Chrome back
  seven days without mirroring old debs. The builds the gate would delay are the ones fixing exploited-in-the-wild bugs.
  The gate's threat, a malicious upload to an open registry, does not match a vendor-signed first-party repository.
**Deferred to Planning**

- **The first execution gate is the sandbox measurement.** After the R1 deploy runs on the Linux server, and before any
  consumer is pointed at Chrome: does Chrome at `/opt/google/chrome/chrome` start with its sandbox on under the host's
  userns restriction (R5, AE3), and does `channel: 'chrome'` run a real suite? Expected: the namespace sandbox through
  Ubuntu's `chrome` profile, and the setuid helper when that profile is not loaded. A failure takes the Goal Capsule's
  stop condition.
- Where the shell-config block that owns the Chrome path lives, and which crawl4ai callers dotfiles configures: the
  crawl4ai skill's scripts and browser template, `crwl` through `-b` or a `-B` config file, and each importing repo such
  as scrawl2. crawl4ai's managed-browser modes (profiles, persistent contexts, CDP) resolve their binary through
  `~/.crawl4ai/chromium.path` rather than `chrome_channel`, so planning decides whether R7 covers them or excludes them.
- What populated `~/.cache/puppeteer` on the Linux server (bun's cache holds puppeteer and puppeteer-core 24.43.1), and
  whether that tool should get `PUPPETEER_EXECUTABLE_PATH` or the cache should go.
- The Mac's crawl4ai moves from 0.7.7 to a release that honors `CRAWL4AI_CHROMIUM_SANDBOX` (R7); planning lists each
  importing repo's crawl4ai version.
- The R4 check's source of truth for "newest stable": Google's apt index on Linux. On the Mac, Google stages each stable
  rollout over days, so the check reports the installed version and the updater's presence rather than comparing against
  Google's version history.
- When R4 runs unattended, and where a failure shows: the repo already surfaces host checks at Claude Code session start
  (`failed-user-units.sh`), silent when they pass.
- Whether `apparmor.service` runs on every boot of this host or only some, which decides whether the setuid fallback in
  AE3 is a backstop or a routine path.

### Sources / Research

- `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-deps-deploy.sh`, `config/apparmor.d/playwright`,
  `config/systemd/system/apparmor-playwright.service`, `config/shell/caches.sh` (`PLAYWRIGHT_BROWSERS_PATH`,
  `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`), `config/shell/supply-chain.sh`, `scripts/upgrade/brew.sh`,
  `docs/runbooks/playwright-browser-launch.md`, `stow/claude/dot-claude/guides/cli-tools.md`.
- Solutions: `docs/solutions/runtime-errors/playwright-chromium-sandbox-ubuntu-2404-2026-04-17.md`,
  `docs/solutions/runtime-errors/playwright-install-deletes-unregistered-browsers-from-shared-cache.md`,
  `docs/solutions/runtime-errors/playwright-browser-install-stall-manual-cache-install.md`.
- PR #431 (`fix/playwright-cache-gc-guard`), open: registration of the provisioned set.
- gstack at v1.94.33.0: `browse/src/browser-manager.ts` (`launch()`, `shouldEnableChromiumSandbox()`), `setup`
  (`ensure_playwright_browser()`), `bin/gstack-browser-ensure`, `qa/sections/browser-setup.md`. Issues
  garrytan/gstack#3338 and #3440 (open), #3645 and #2771 (closed), PR #3947 (merged 2026-11-03).
- crawl4ai 0.9.5 `browser_manager.py` (`chromium_sandbox_requested()`, `chrome_channel`).
- agentnative-site `playwright.config.ts` (its existing `PW_CHANNEL` switch) and `.lighthouserc.json`; lmgroktfy
  `apps/web/playwright.config.ts`.
- Google: Chrome Releases stable-channel posts of 2026-09-03, 2026-09-08, 2026-10-27, 2026-10-29, and 2026-11-03
  (chromereleases.googleblog.com); the apt repository at `https://dl.google.com/linux/chrome/deb/`.
- Playwright: the `chromiumSandbox` launch option (default false), browser channels, and the
  `reinstall_chrome_stable_linux.sh` that `playwright install chrome` runs, an apt install of Google's deb.
- actions/runner-images `images/ubuntu/Ubuntu2404-Readme.md`, image 20261026.354.1.

---

## Appendix

### Engineering Review (plan-eng-review, 2026-11-03)

The review ran unattended in an agent slot, with no question tool. Each choice below was auto-decided on its
recommendation, under the slot's standing instruction to settle review questions from code, docs, and precedent and
record them here. Brett's three Outstanding Questions are not review decisions and stay open.

#### Scope Challenge

- **What already exists:** the copy-deploy shape with `--check` and `--dest` (`scripts/sysctl-deploy.sh`,
  `tests/sysctl-deploy.bats`); the deleted-executable scan in `scripts/upgrade/lib/stale-procs.sh`; the browser
  environment in `config/shell/caches.sh`; Google's deb, which maintains its own source and keyring; Ubuntu's `chrome`
  AppArmor profile; unattended-upgrade's `Origins-Pattern`; Playwright's `channel`; gstack's `GSTACK_CHROMIUM_PATH`;
  crawl4ai's `CRAWL4AI_CHROMIUM_SANDBOX` and `chrome_channel`; agentnative-site's `PW_CHANNEL`; Puppeteer's
  `PUPPETEER_EXECUTABLE_PATH`.
- **Minimum change:** install, drop-in, check, pointers, and guidance. The provisioning shrink (R12) waits on #431 and
  the first Outstanding Question; AppArmor retirement (R13) waits on the hostile-web consumers moving; the Puppeteer
  cleanup is deferred.
- **Complexity:** about 17 dotfiles files [estimated]: 3 new (deploy script, apt drop-in, bats suite) and about 14 edits
  or retirements, plus one config line in each of three e2e repos. No new classes or services. The 8-file gate trips.
- **Search:** primary sources were fetched directly (Chrome Releases, Google's apt index, the npm registry,
  actions/runner-images); Aside was not used. A vendor apt repository with the OS's unattended upgrades is the standard
  path [Layer 1].
- **TODOS:** the repo has no tracked TODOS file; local TODO files are gitignored by policy.
- **Distribution:** nothing is published. The operator runs the deploy script per host.
- **Complexity selectors (auto-decided):** no feature cuts, because R12 and R13 are already conditional. Structure: the
  smaller arrangement (D1).
- **Scope result:** scope accepted as-is.

Scope findings:

- S1. [INFORMATIONAL] (confidence: 9/10) `scripts/playwright-browsers-deploy.sh` on dev has no `--check` (0 matches) and
  `tests/playwright-browsers-deploy.bats` does not exist, yet R12 and AE5 build on both. Disposition: accepted;
  Dependencies now says #431 merges first.
- S2. [INFORMATIONAL] (confidence: 8/10) The brief asked for one real consumer on `channel: 'chrome'`; only
  `executablePath` runs were possible without the install. Disposition: no change; it is the first execution gate
  (Deferred to Planning).

Reality rows:

- `REALITY: premise-table finding 25 premises, unverified=3 (Mac crawl4ai launch, sandbox at /opt, Mac gstack browse on
  stable Chrome) docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md`
- `REALITY: already-done pass no commit on origin/dev since 2026-11-02 touches the named Playwright, AppArmor, or
  shell-cache files scripts/playwright-browsers-deploy.sh:1`
- `REALITY: surface-check pass GSTACK_CHROMIUM_PATH browser-manager.ts:674, CRAWL4AI_CHROMIUM_SANDBOX
  browser_manager.py:48, Origins-Pattern /usr/bin/unattended-upgrade:794, PUPPETEER_EXECUTABLE_PATH
  Configuration.d.ts:36, browse goto (browse --help:5); --check is S1 scripts/playwright-browsers-deploy.sh:1`
- `REALITY: binding-decisions pass no recorded branch decision on Playwright or Chrome; the alias rule (leading
  consumers install their own build) is kept in the machinery table scripts/playwright-browsers-deploy.sh:100`
- `REALITY: numbers pass 447 MB, 651 MB (389+262), 929 MB, 22-26 s, 205/225 MB [measured: du, gtime]; ~17 files
  [estimated]; "within a day" from apt-daily-upgrade.timer [measured: systemctl]
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md`
- `REALITY: deferred-asks finding Brett's ask has five parts; the channel:'chrome' run and the /opt sandbox measurement
  wait on his install (Outstanding Questions)
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md`
- `REALITY: pr-count pass no ship policy; two dotfiles PRs (install and pointers; provisioning shrink after #431 and Q1)
  plus one per e2e repo, stated under Parallelization
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md`

#### 1. Architecture

```text
Google apt repo ──signed──▶ apt (unattended-upgrades, daily; Origins-Pattern drop-in)
                                 │
                                 ▼
                    /opt/google/chrome/chrome ◀── Ubuntu `chrome` AppArmor profile (userns)
                                 │                 └─ fallback: setuid chrome-sandbox
          shell config: one owner of the per-OS Chrome path (exports only if the binary exists)
                 ┌───────────────┼──────────────────┬──────────────────────────┐
                 ▼               ▼                  ▼                          ▼
          gstack browse      crawl4ai         agent scripts            e2e suites (local, Q1)
       GSTACK_CHROMIUM_PATH  sandbox on +    channel:'chrome' +        one switch; CI keeps the pin
                             chrome_channel  chromiumSandbox:true
                                 │
          check (--check): stale vs Google's index │ origin not covered │ running on replaced exe
```

- A1. [CRITICAL] (confidence: 8/10) gstack `browse/src/browser-manager.ts:674`:
  `const executablePath = process.env.GSTACK_CHROMIUM_PATH || undefined;` and line 678 throws
  `Chromium at GSTACK_CHROMIUM_PATH=... failed to launch`. An unconditional export breaks browse on every host without
  Chrome. Disposition: accepted (D2): R15, AE7.
- A2. [INFORMATIONAL] (confidence: 8/10) `AGENTS.md:5`: "deployed to thousands of headless Ubuntu servers"; R1 named
  only "the Linux server". Disposition: accepted (D3): the install is per host, as a Key Decision.
- A3. [INFORMATIONAL] (confidence: 6/10) unattended-upgrades replaces Chrome as root while a long-lived browse daemon
  keeps the old executable. `scripts/upgrade/lib/stale-procs.sh` handles this for Homebrew user services only. Medium
  confidence on misbehavior; high that the fix waits for a restart. Disposition: accepted (D4): R16, AE8; report, never
  restart.
- A4. [INFORMATIONAL] (confidence: 7/10) The per-OS Chrome path would be copied into the gstack pointer, the crawl4ai
  settings, the check, and docs (red flag 8, hand-synced list). Disposition: accepted (D5): one owner, as a Key
  Decision.
- A5. [INFORMATIONAL] (confidence: 7/10) `scripts/playwright-deps-deploy.sh:103`:
  `bun x playwright install --with-deps "${browsers[@]}"` fetches a chromium alongside the deps, a second chromium path
  once the set drops chromium (red flag 6). Disposition: accepted (D6): the machinery table retires `--chromium` with
  the chromium entries.

Design twice: shape A (chosen) is the vendor deb under apt and unattended upgrades, which hides signing, updates, and
the sandbox helper behind the OS package manager. Shape B is a user-space dotfiles timer fetching Chrome for Testing's
Stable channel into a cache: no sudo, but it rebuilds download, verification, and updates, needs a dotfiles AppArmor
glob again, and ships a build Google labels for testing. A is the deeper module behind the smaller surface. Red flags 6
and 8 are A5 and A4; no others apply.

Failure modes: a release upgrade disabling Google's source is re-enabled by the deb's cron job and caught by R4.
Google's index lagging the blog by hours (measured about 9 h on 2026-11-03) is why R2 counts from the apt index. A
Chrome major outrunning an old `@playwright/test` breaks local runs only, with CI pinned. Ubuntu's profile not loading
at boot falls to the setuid helper (AE3, to measure).

Security: the deb installs a `signed-by` keyring of its own; its management service stays inert unless the browser is
enrolled; nothing signs in to Chrome.

#### 2. Code quality

- Q1. [INFORMATIONAL] (confidence: 6/10) The Mac path, `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
  has spaces; every consumer that reads the pointer has to keep it whole. Disposition: accepted (D7): an edge-case test
  in the Test Plan.
- Q2. [INFORMATIONAL] (confidence: 7/10) R16's process scan duplicates `stale-procs.sh`'s `/proc` deleted-executable
  scan (red flag 6). Rubric: callers `stale_procs_restart /proc "$prefix"` in `scripts/upgrade/brew.sh` and the proposed
  R16 check (plan assumption). Disposition: accepted (D8): R16 reuses the scan and only reports.

The check follows the repo's script conventions (`ERROR:`/`NOTE:` on stderr, the fix command named, `--check` changes
nothing), as `scripts/sysctl-deploy.sh` does.

#### 3. Tests

Framework: bats through `scripts/run-tests` (AGENTS.md, Local gates mirror CI).

```text
CODE PATHS                                             USER FLOWS
[+] Chrome deploy script (new)                         [+] Operator opts a host in
  ├── [GAP] install via stubbed apt-get, --dest copy     └── [GAP] [→E2E] deploy → --check passes (live)
  └── --check                                          [+] Browsing agent on stable Chrome
      ├── [GAP] Chrome absent → note, exit 0             ├── [GAP] [→E2E] browse rejects eMudhra host (AE1, live)
      ├── [GAP] current → exit 0                         ├── [GAP] [→E2E] sandboxed renderers (AE3, live)
      ├── [GAP] stale vs index → exit 1, names command   └── [GAP] [→E2E] crawl4ai no --no-sandbox (AE4, live)
      ├── [GAP] origin not covered → exit 1            [+] Local e2e on stable Chrome (Q1)
      └── [GAP] running on replaced exe → reported       └── [GAP] [→E2E] suites + WebKit pass (AE5, live)
[+] Shell-config Chrome pointer (new)
  ├── [GAP] binary present → exports set
  ├── [GAP] binary absent → nothing exported (REGRESSION, CRITICAL)
  └── [GAP] Mac path with spaces stays whole

COVERAGE: 0/13 paths tested (all new)  |  Code paths: 0/8  |  User flows: 0/5
QUALITY: none yet  |  GAPS: 13 (5 live E2E, 0 eval)
```

Proposed tests, with value cards in the Test Plan artifact: a new `tests/chrome-deploy.bats` for the install and every
`--check` branch, over fixture Packages files, fixture apt config, and a fixture `/proc` tree; pointer cases added to
`tests/shell-config.bats`; the shrink cases added to `tests/playwright-browsers-deploy.bats` once #431 lands. The live
checks (AE1, AE3, AE4, AE5) are runtime and have no CI equivalent. The regression to protect is browse on hosts without
Chrome (AE7). Tests to retire: the chromium and alias cases of #431's suite, if chromium leaves the set. Test Plan:
`~/.gstack/projects/brettdavies-dotfiles/brett-dev-eng-review-test-plan-20261103-154325.md`.

#### 4. Performance

- P1. [INFORMATIONAL] (confidence: 7/10) Full Chrome against the headless shell: about 10% more peak RSS (225 MB against
  205 MB) and the same wall time on lmgroktfy [measured: gtime, one or two runs, load about 29]. Disposition: no action;
  re-measure on a quiet host if browse memory matters.
- P2. [INFORMATIONAL] (confidence: 6/10) The pointer block adds one file test to every shell start, inside the pre-push
  startup budget. Disposition: keep it to a single `[ -x ]` with no subprocess.

Disk: Chrome adds 447 MB [measured]; dropping chromium and the headless shell frees 651 MB per revision [measured].

#### Outside voice

Disabled (`codex_reviews` is `disabled`); recorded as skipped. No outside or replacement review ran.

#### Decision ledger

Each entry was auto-decided on its recommendation (unattended slot, standing authorization).

| ID  | Finding         | Options                                              | Chosen      | Accepted scope                                                                                                                         |
| --- | --------------- | ---------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | complexity gate | original arrangement; smaller arrangement            | smaller     | one deploy script whose `--check` is the R4/R16 check, one apt drop-in, one shell-config block for the path; second PR for R12 and R13 |
| D2  | A1              | conditional pointer; unconditional pointer plus docs | conditional | R15, AE7                                                                                                                               |
| D3  | A2              | per-host opt-in; fleet-wide install                  | per-host    | Key Decision, R1 wording                                                                                                               |
| D4  | A3              | report stale processes; restart them; do nothing     | report      | R16, AE8                                                                                                                               |
| D5  | A4              | one owner for the path; per-consumer copies          | one owner   | Key Decision                                                                                                                           |
| D6  | A5              | retire `--chromium` with chromium; keep it           | retire      | machinery table row                                                                                                                    |
| D7  | Q1              | edge-case test; none                                 | test        | Test Plan edge case                                                                                                                    |
| D8  | Q2              | reuse stale-procs scan; new scan                     | reuse       | R16 implementation constraint                                                                                                          |

Approval readiness: PASS (D1 to D8, auto-decided under the slot's standing authorization).

#### NOT in scope

- CI on the runner's Chrome, WebKit replacement, Playwright MCP, Edge, the headed GStack Browser: see Scope Boundaries.
- Restarting a user's browse daemon automatically: R16 reports instead, because the daemon may hold a live session.
- Patching gstack's probes: Brett files the upstream issue.

#### Parallelization

| Step                                     | Modules touched                                                      | Depends on               |
| ---------------------------------------- | -------------------------------------------------------------------- | ------------------------ |
| Install, check, pointers                 | `scripts/`, `config/`, `config/shell/`, `tests/`                     | —                        |
| Guidance and docs                        | `stow/claude/dot-claude/guides/`, `docs/runbooks/`, README           | install, check, pointers |
| Provisioning shrink, AppArmor retirement | `scripts/`, `config/apparmor.d/`, `config/systemd/system/`, `tests/` | #431, Q1, install        |
| e2e switch                               | lmgroktfy, meum-sites, streamsgrp, agentnative-site                  | Q1                       |

Lane A: install, check, pointers, then guidance (one PR). Lane B: e2e switch, independent repos. Lane C: provisioning
shrink after #431 and Q1. Launch A and B; merge A; then C.

#### Implementation Tasks

- [ ] **T1 (P1, human: ~4h / CC: ~30min)** — deploy — Chrome deploy script, apt drop-in, and `--check`
  - Surfaced by: Scope Challenge — D1; R1, R2, R4
  - Files: `scripts/`, `config/`, `tests/chrome-deploy.bats`
  - Verify: `scripts/run-tests tests/chrome-deploy.bats`; live `--check` on the server
- [ ] **T2 (P1, human: ~1h / CC: ~10min)** — shell — one owner for the Chrome path; exports only when the binary exists
  - Surfaced by: Architecture — A1, A4
  - Files: `config/shell/`, `tests/shell-config.bats`
  - Verify: AE7 on a host without Chrome
- [ ] **T3 (P1, human: ~1h / CC: ~10min)** — check — report Chrome processes on a replaced executable, reusing the
  stale-procs scan
  - Surfaced by: Architecture — A3; Code quality — Q2
  - Files: `scripts/upgrade/lib/stale-procs.sh`, the deploy script
  - Verify: AE8 fixture case
- [ ] **T4 (P2, human: ~1h / CC: ~15min)** — crawl4ai — stable Chrome with the sandbox on, both machines
  - Surfaced by: Requirements — R7
  - Files: `config/shell/`, crawl4ai skill scripts
  - Verify: AE4
- [ ] **T5 (P2, human: ~1h / CC: ~10min)** — docs — guidance and present-state docs
  - Surfaced by: Requirements — R8, R14
  - Files: `stow/claude/dot-claude/guides/cli-tools.md`, `docs/runbooks/playwright-browser-launch.md`, `README.md`
  - Verify: `markdownlint-cli2`; read-through
- [ ] **T6 (P1, human: ~2h / CC: ~20min)** — provisioning — shrink the set and retire `--chromium` (after #431 and Q1)
  - Surfaced by: Architecture — A5; Scope — S1
  - Files: `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-deps-deploy.sh`,
    `tests/playwright-browsers-deploy.bats`
  - Verify: AE5
- [ ] **T7 (P1, human: ~30min / CC: ~10min)** — live — sandbox and channel measurement after the install
  - Surfaced by: Scope — S2
  - Files: none
  - Verify: AE1, AE3

The task store also carries eight tasks from the 2026-11-03 eng review of
`docs/plans/2026-11-02-2324-feat-agent-slots-on-the-mac-plan.md`, unchanged; they are that plan's work, not this one's.

#### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 applicable rows emitted, 3 unverified premises
- Architecture Review: 5 issues found
- Code Quality Review: 2 issues found
- Test Review: diagram produced, 13 gaps identified
- Performance Review: 2 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed (no tracked TODOS file)
- Failure modes: 0 critical gaps flagged (A1's silent break is closed by R15)
- Unresolved decisions: 3, all the plan's Resolve Before Planning questions for Brett; none of this review's own choices
  is open
- Outside voice: codex, disabled (`codex_reviews`)
- Parallelization: 3 lanes, 2 parallel / 1 sequential
- Lake Score: N/A (no answers scored for Completeness)

### DX Review (plan-devex-review, 2026-11-03)

Run unattended under the same rule as the engineering review. Product type: Platform (host provisioning), with a CLI
surface (the deploy script and its `--check`) and a guidance surface agents read. Mode: DX POLISH, because this enhances
existing provisioning. No design doc exists; the `/office-hours` offer was skipped as unattended. The prior DX rows on
`dev` belong to other plans, so there is no trend to compare.

#### Developer Persona Card

```text
TARGET DEVELOPER PERSONA
========================
Who:       an AI coding agent in an agent slot on the Linux server or the Mac, unattended
Context:   asked to scrape a page, run /qa or /browse, or write a script that opens a URL nobody vetted
Tolerance: one launch attempt; it follows the first fix line an error prints, literally
Expects:   the always-loaded CLAUDE.md and the CLI tools guide to say which browser to launch and how
Secondary: the operator at a terminal, opting a host in with one sudo command
```

#### Developer Empathy Narrative

I am an agent asked to pull the text of a vendor's status page. The always-loaded instructions
(`stow/claude/dot-claude/CLAUDE.md:291`) tell me Playwright browsers are system-provided and never to run
`playwright install`, so I write `chromium.launch()`. It works in about a second. Nothing tells me that I just ran
Chrome for Testing 156.0.8078.4 with `--no-sandbox` (measured), or that this build still trusts a compromised CA
(measured). With the plan as first written, the guidance would say `channel: 'chrome'`. On a host without Chrome I would
get `Chromium distribution 'chrome' is not found at /opt/google/chrome/chrome` and `Run "npx playwright install chrome"`
(captured), and I would run it: an apt install as root that the slot denies, or that bypasses the dotfiles deploy where
sudo works.

#### Competitive DX Benchmark

| Tool                           | Start → result                              | Time + evidence type                                                                   | DX choice                                                                   | Source                        |
| ------------------------------ | ------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------- |
| Playwright library, default    | `chromium.launch()` → page loaded           | ~1-2 s [observed: probes]                                                              | pinned build, sandbox off by default                                        | `chromiumSandbox` docs; probe |
| Playwright `channel: 'chrome'` | launch → page in installed Chrome           | ~1-2 s once installed [observed: 157 via `executablePath`]; error if absent [observed] | relies on the OS install; prints `npx playwright install chrome`            | coreBundle.js; probe          |
| crawl4ai                       | `crwl <url>` → markdown                     | unknown here                                                                           | pinned build, `--no-sandbox` unless `CRAWL4AI_CHROMIUM_SANDBOX=true`        | `browser_manager.py:44-54`    |
| This plan                      | agent script → sandboxed stable Chrome page | <2 min including reading the guidance [estimated]                                      | one dotfiles variable, sandbox on, stop with the deploy command when absent | R8, R18                       |

Target (auto-decided): Champion, under 2 minutes, from reading the guidance to a page loaded in sandboxed stable Chrome.
That endpoint is unreachable on the Linux server today, because stable Chrome is not installed.

#### Magical Moment Specification

The operator's `--check` on an opted-in host prints one line naming the installed Chrome version, that unattended
upgrades cover it, and that nothing runs a replaced executable (R4, R16, R17). The agent's moment is AE1: the
compromised-CA test host fails with a certificate error, where the pinned build loaded it. Both use capabilities the
plan already has.

#### Developer Journey Map

```text
STAGE           | DEVELOPER DOES                                    | FRICTION POINTS                                   | STATUS
----------------|---------------------------------------------------|---------------------------------------------------|--------
1. Discover     | reads CLAUDE.md:291 and the CLI tools guide        | both say "pinned, never install"; no Chrome word  | fixed (R8, R14)
2. Install      | operator runs the deploy with sudo once per host   | sudo denied to agents; root needed for apt        | ok (operator step, D1 shape)
3. Hello World  | agent launches the dotfiles-named Chrome, sandbox  | absent-Chrome error prints an unsafe fix          | fixed (R18, AE9)
4. Real Usage   | gstack and crawl4ai through the pointers           | crawl4ai CLI needs `-b`/`-B` or global config     | deferred to planning (already listed)
5. Debug        | runs `--check`                                    | failure output had no stable reason or values     | fixed (R17)
6. Upgrade      | nothing: unattended upgrades daily                 | a running daemon keeps the old build              | fixed (R16)
```

#### First-Time Developer Confusion Report

```text
FIRST-TIME DEVELOPER REPORT
============================
Persona: agent in a slot, task "fetch this page"
T+0:00  Reads CLAUDE.md:291: browsers are system-provided; never run playwright install.
T+0:20  Writes chromium.launch(); page loads. Unaware it is pinned and unsandboxed.      → addressed by R8, R14
T+0:40  (plan as first written) switches to channel 'chrome' per the guide.
T+0:45  On a host without Chrome: "Run npx playwright install chrome". Runs it.          → addressed by R18, AE9
T+1:00  sudo denied by the slot, or apt installs Chrome outside the dotfiles deploy.    → addressed by R18
T+1:30  (after the plan) reads the variable, launches sandboxed stable Chrome, done.
```

#### Passes

- Pass 1, Getting Started: 6 → 8. The operator path is one sudo command plus `--check`; the agent path is one launch
  line. Residual: the operator install needs root on each host, by design.
- Pass 2, API/CLI/SDK: 6 → 8. One variable is the interface for every consumer (Key Decision, one owner); `--check`
  follows `scripts/sysctl-deploy.sh --check`. Residual: crawl4ai's CLI and SDK take the setting differently.
- Pass 3, Error Messages: 4 → 7. Finding DX1 below was a CAP4. The check's failures gain reasons and values (R17).
  Residual: what an old `@playwright/test` prints against a far newer Chrome is unknown.
- Pass 4, Documentation: 6 → 8. The always-loaded CLAUDE.md line joins R8 and R14.
- Pass 5, Upgrade: 7 → 8. Updates are unattended; stale processes are reported (R16).
- Pass 6, Dev Environment: 7 → 8. One variable covers the Mac path (spaces) and the Linux path; Google ships amd64 and
  arm64 debs (measured); CI unchanged (R10).
- Pass 7, Community: 3 → 3. Personal dotfiles; no community surface, and none proposed.
- Pass 8, DX Measurement: 5 → 7. `--check` is the standing measure, and the live checks (AE1, AE3, AE9) measure the
  clock once Chrome is installed. No telemetry proposed.

```text
ERROR PATH MATRIX (agent-ready-v1)
Path                             | Class      | what | fix  | recovery | code | context | trace | redaction | channel | Cap
agent launch, Chrome absent      | dependency | pass | fail | fail     | fail | pass    | N/A   | pass      | pass    | CAP4:launch:fix  → R18
--check, Chrome stale            | dependency | pass | pass | gap      | gap  | gap     | N/A   | pass      | pass    | CAP6:check:context → R17
--check, origin not covered      | config     | pass | pass | gap      | gap  | gap     | N/A   | pass      | pass    | CAP6:check:context → R17
deploy run without root          | usage      | gap  | gap  | N/A      | gap  | N/A     | N/A   | pass      | gap     | none (usage; D1 shape)
unexpected: apt-get fails        | dependency | gap  | gap  | gap      | gap  | gap     | gap   | pass      | gap     | CAP6:deploy:trace (planning: pass apt's stderr through, name the rerun)
```

- DX1. [CRITICAL] `CAP4:launch:fix unsafe fix on a host without Chrome`. Playwright prints
  `Run "npx playwright install chrome"`, which runs `reinstall_chrome_stable_linux.sh` (`apt-get install` as root) and
  contradicts the CLI guide. Corrected line, from the script the guidance shows: `stable Chrome is not installed on this
  host (DOTFILES chrome variable unset); ask the operator to run the Chrome deploy; not falling back to a pinned build`.
  Disposition: accepted (DX-D1): R8 uses `executablePath` from the dotfiles variable; R18; AE9.
- DX2. [HIGH] `CAP6:check:context failure output names no reason or values`. R4 named only the fix command. Precedent:
  `sd-commit-doc` ends failures with `reason:`, `state:`, `next:` lines, and the global error contract asks for a stable
  reason. Disposition: accepted (DX-D2): R17; AE2 extended.
- DX3. [INFORMATIONAL] The always-loaded `stow/claude/dot-claude/CLAUDE.md:291` is the first thing every agent reads and
  was outside R8 and R14. Disposition: accepted (DX-D3): both name it.
- DX4. [INFORMATIONAL] `crwl` takes browser settings through `-b key=value` and `-B <file>` (`crwl --help`).
  Disposition: no change; the existing Deferred to Planning item covers it.
- DX5. [INFORMATIONAL] A deploy run without root, and an apt failure, need the usage and dependency error shapes.
  Disposition: implementation constraint under D1's script shape, carried in the Implementation Tasks; no new
  requirement.

Decision ledger (auto-decided): DX-D1 `executablePath` from the dotfiles variable, stopping when absent (chosen) over
`channel: 'chrome'` with Playwright's error, and over a fallback to the pinned build. DX-D2 stable reasons and values in
check failures (chosen) over the fix command alone. DX-D3 include CLAUDE.md (chosen) over the guide alone. Outside
voice: disabled (`codex_reviews`), recorded as skipped.

NOT in scope: telemetry on agent launches; a `--json` form of `--check` (no current consumer reads one); a community
surface.

What already exists: `scripts/sysctl-deploy.sh --check` and its bats suite, `sd-commit-doc`'s `reason:`/`next:` lines,
gstack's `GSTACK_CHROMIUM_PATH` launch error, crawl4ai's `-b`/`-B` flags.

TODOS: none proposed; there is no tracked TODOS file.

Implementation tasks (DX):

- [ ] **DX-T1 (P1, human: ~30min / CC: ~5min)** — guidance — launch line with the dotfiles variable and the
  stop-when-absent branch
  - Surfaced by: Pass 3 — DX1
  - Files: `stow/claude/dot-claude/CLAUDE.md`, `stow/claude/dot-claude/guides/cli-tools.md`
  - Verify: AE9 on a host without Chrome
- [ ] **DX-T2 (P1, human: ~30min / CC: ~10min)** — check — stable reasons, compared values, distinct exits
  - Surfaced by: Pass 3 — DX2
  - Files: the deploy script, `tests/chrome-deploy.bats`
  - Verify: bats cases assert each reason line

## DX Review Scorecard

```text
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      | 8/10   | 6/10   | ↑      |
| API/CLI/SDK          | 8/10   | 6/10   | ↑      |
| Error Messages       | 7/10   | 4/10   | ↑      |
| Documentation        | 8/10   | 6/10   | ↑      |
| Upgrade Path         | 8/10   | 7/10   | ↑      |
| Dev Environment      | 8/10   | 7/10   | ↑      |
| Community            | 3/10   | 3/10   | =      |
| DX Measurement       | 7/10   | 5/10   | ↑      |
+--------------------------------------------------------------------+
| TTHW                 | <2 min | unreachable today (no stable Chrome) |
| Competitive Rank     | Champion (target)                            |
| Magical Moment       | designed via --check line and AE1            |
| Product Type         | Platform with a CLI and guidance surface     |
| Mode                 | POLISH                                       |
| Overall DX           | 7/10   | 6/10   | ↑      |
+====================================================================+
| DX PRINCIPLE COVERAGE                                               |
| Zero Friction      | covered                                        |
| Learn by Doing     | covered (copy-paste launch line, R8)           |
| Fight Uncertainty  | covered (R17, R18)                             |
| Opinionated + Escape Hatches | covered (one variable; env override) |
| Code in Context    | covered                                        |
| Magical Moments    | covered                                        |
| Agents Are Users   | covered (no interactive step; stop with a command) |
+====================================================================+
```

Prior column: this review's initial scores; no earlier DX review of this plan exists. Community stays at 3, honestly: no
community surface is in scope. Error Messages stays at 7 until the old-Playwright-versus-new-Chrome failure is observed.

Unresolved decisions from this review: none.

## GSTACK REVIEW REPORT

| Review         | Trigger                                                    | Why                             | Runs | Status             | Findings                                             |
| -------------- | ---------------------------------------------------------- | ------------------------------- | ---- | ------------------ | ---------------------------------------------------- |
| CEO Review     | `/plan-ceo-review`                                         | Scope & strategy                | 0    | —                  | —                                                    |
| Outside Review | codex, plan-eng-review and plan-devex-review outside voice | Independent 2nd opinion         | 2    | disabled           | —                                                    |
| Eng Review     | `/plan-eng-review`                                         | Architecture & tests (required) | 1    | ISSUES OPEN (PLAN) | 22 issues, 0 critical gaps                           |
| Design Review  | `/plan-design-review`                                      | UI/UX gaps                      | 0    | —                  | —                                                    |
| DX Review      | `/plan-devex-review`                                       | Developer experience gaps       | 1    | ISSUES OPEN        | score: 6/10 → 7/10, TTHW: unreachable today → <2 min |

- **OUTSIDE COVERAGE:** codex, plan-review phase, disabled by `codex_reviews` for both reviews; no findings.
- **VERDICT:** no review CLEAR yet — eng review required (both reviews' findings are accepted into the plan as mapped
  work).

**UNRESOLVED DECISIONS:**

- \+ 3 unresolved for Brett (plan Outstanding Questions): the local e2e browser, the seven-day gate exemption for
  Chrome, and what gstack's headed sessions run on
