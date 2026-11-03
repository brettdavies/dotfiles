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
  that carries Google's current stable security fixes, with its sandbox on. The machine downloads a Playwright-pinned
  Chromium only for consumers that still need a pinned build.
- **Means:** Google Chrome stable, installed from Google's signed apt repository on the Linux server and kept current by
  the host's unattended upgrades. On the Mac it is the existing install, kept current by Google's own updater. Consumers
  reach it by Playwright's `chrome` channel or an executable path.
- **Product authority:** Requirements govern behavior and Key Decisions record why. The measurements in this plan are
  the evidence. Where a solutions doc or runbook disagrees with a measurement here, the doc is what gets rewritten. The
  scope of the pinned-download removal waits on Brett's answer to the first Outstanding Question.
- **Open blockers:** the sandbox at Chrome's real install path is unmeasured until Brett installs the package (third
  Outstanding Question). Brett also has to decide the local browser for the e2e suites and whether Chrome is exempt from
  the seven-day gate (first and second Outstanding Questions).
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
sandbox on: gstack browse, crawl4ai, and agent scripts. Dotfiles keeps provisioning a Playwright-pinned Chromium only
where a test suite's reproducibility needs it.

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
read-only on the Mac (macOS 27.0, arm64), 2026-11-03. Chrome stable 156.0.8078.79 was taken from Google's apt
repository: its sha256 matched the Packages index, and it was extracted into a scratch directory, not installed.

| Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Evidence                                                                                           |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Playwright 1.61.1 resolves chromium 1228 to the 1234 alias, Chrome 151.0.7922.34. gstack's and crawl4ai's Playwright 1.64.1 run chromium 1248, Chrome for Testing 156.0.8078.4.                                                                                                                                                                                                                                                                              | `browser.version()` from each package's `chromium.launch()`; the browsers.json of 1.64.1           |
| Playwright's default launch passes `--no-sandbox`, and no child process gets its own user or PID namespace. With `chromiumSandbox: true` the pinned headless shell gets both namespaces and seccomp filter mode, under the dotfiles `playwright-chromium-headless` AppArmor label (the profile attaches through the alias symlink).                                                                                                                          | `/proc/<pid>/cmdline`, `ns/user`, `ns/pid`, `status`, `attr/current` of the browser tree           |
| Both pinned builds (151.0.7922.34 and 156.0.8078.4) load `https://dv-g3b-emudhra.we-have-a-problem.com/` with status 200 and the page's "That's bad!" text. Stable 156.0.8078.79, launched by Playwright with its default `--disable-component-update`, rejects it with `net::ERR_CERT_REVOKED`.                                                                                                                                                             | navigation through Playwright on each build                                                        |
| Chrome for Testing 151.0.7922.34 predates two fixes Google reports as exploited in the wild: CVE-2026-85046 (fixed in 152.0.7977.82, 2026-09-03) and CVE-2026-87491 (fixed in 153.0.8010.36, 2026-09-08). 156.0.8078.4 predates the four Criticals fixed in 156.0.8078.73 (2026-10-27: CVE-2026-118306, -118331, -118348, -118344) and CVE-2026-76024 (156.0.8078.79, 2026-10-29). Chrome 157.0.8103.38 went stable on 2026-11-03 with seven more Criticals. | Chrome Releases stable-channel posts                                                               |
| No Playwright release since 1.64.1 (2026-10-14). Playwright main (1.65.0-alpha-2026-11-03) pins 158.0.8127.2, which matches Chrome's current beta.                                                                                                                                                                                                                                                                                                           | npm registry times; the alpha's browsers.json                                                      |
| Playwright 1.61.1 drives full Chrome 156.0.8078.79 through `executablePath`: lmgroktfy's suite passes 16/16 in 22.3 s, against 16/16 in 22.0 s on the pinned build.                                                                                                                                                                                                                                                                                          | scratch config over the repo's tests and `dist/`                                                   |
| At a path no AppArmor profile covers, Chrome 156 with its sandbox on falls back to the setuid helper and aborts because the scratch copy is not root-owned mode 4755. With `--no-sandbox` it renders and no library is missing.                                                                                                                                                                                                                              | direct headless launch; `ldd`                                                                      |
| `channel: 'chrome'` resolves only to `/opt/google/chrome/chrome`.                                                                                                                                                                                                                                                                                                                                                                                            | Playwright 1.61.1 launch error; coreBundle.js in 1.64.1                                            |
| Ubuntu's `apparmor` package ships `/etc/apparmor.d/chrome`, granting `userns` to `/opt/google/chrome/chrome`, and it is loaded on the current boot as `chrome`. Google's deb ships its own equivalent profile and installs it only when Ubuntu's is absent.                                                                                                                                                                                                  | `dpkg -S`, `/sys/kernel/security/apparmor/policy/profiles/`, the deb's postinst                    |
| On the current boot (2026-10-05) `apparmor.service` ran and loaded `/etc/apparmor.d`. The runbook says it is skipped at boot on this host.                                                                                                                                                                                                                                                                                                                   | `systemctl show apparmor.service -p ConditionResult` is `yes`; `journalctl -b -u apparmor.service` |
| Installing the deb installs `/opt/google/chrome` with a setuid `chrome-sandbox` and adds Google's apt source with the keyring `/usr/share/keyrings/google-chrome.gpg`. It also adds `/etc/cron.daily/google-chrome`, which keeps that source in place, creates a `chromemgmt` group, and registers update-alternatives for `google-chrome` and `x-www-browser`.                                                                                              | the deb's control files and payload                                                                |
| Google's apt index lists one version per channel: stable 156.0.8078.79 at 12:14 UTC on 2026-11-03, the day 157 went stable.                                                                                                                                                                                                                                                                                                                                  | `dists/stable/main/binary-amd64/Packages.gz`                                                       |
| unattended-upgrades is enabled on the Linux server, but its Allowed-Origins cover only Ubuntu's own origins. The repository's `Origin: Google LLC` is not among them.                                                                                                                                                                                                                                                                                        | `/etc/apt/apt.conf.d/50unattended-upgrades`, `systemctl is-enabled apt-daily-upgrade.timer`        |
| The Mac runs Google Chrome 156.0.8078.80 from Google's own installer, not Homebrew (the `google-chrome` cask reports not installed, `auto_updates`), and Google's user-level updater is present.                                                                                                                                                                                                                                                             | `defaults read`, `brew info --cask`, `~/Library/Application Support/Google/GoogleUpdater`          |
| GitHub's Ubuntu 24.04 runner image 20261026 ships Google Chrome 156.0.8078.47.                                                                                                                                                                                                                                                                                                                                                                               | actions/runner-images `Ubuntu2404-Readme.md`                                                       |
| Lighthouse CI cannot find a Chrome on the Linux server today: chrome-launcher 0.13.4 raises `ERR_LAUNCHER_PATH_NOT_SET`. Both repos' `.lighthouserc.json` set `--no-sandbox` and no `chromePath`.                                                                                                                                                                                                                                                            | `Launcher.getInstallations()` from agentnative-site's install                                      |
| None of the four e2e suites uses screenshot or snapshot assertions.                                                                                                                                                                                                                                                                                                                                                                                          | search of the suites' specs                                                                        |

### Consumer Risk

Who opens pages Brett does not control, on which browser, with or without the sandbox. "Pinned" means Chrome for Testing
as provisioned by Playwright or dotfiles.

| Consumer                                                                                    | Machine                           | Pages it opens                                                                   | Browser today                                                        | Sandbox today                                                | Under this plan                                                            |
| ------------------------------------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| gstack browse (`/browse`, `/qa`, `/scrape`, handoff, cookie import)                         | Linux, gstack 1.94.33.0           | arbitrary URLs, including credentialed sessions                                  | pinned 156.0.8078.4                                                  | on, through the dotfiles AppArmor profile                    | stable Chrome, sandbox on (R6)                                             |
| gstack browse                                                                               | Mac, gstack 1.93.42               | same                                                                             | pinned 151.0.7922.34                                                 | on                                                           | stable Chrome, sandbox on (R6)                                             |
| crawl4ai CLI and the crawl4ai skill's scripts                                               | Linux, 0.9.5 on Playwright 1.64.1 | arbitrary sites                                                                  | pinned 156.0.8078.4                                                  | off (`--no-sandbox` unless `CRAWL4AI_CHROMIUM_SANDBOX=true`) | stable Chrome, sandbox on (R7)                                             |
| crawl4ai CLI                                                                                | Mac, 0.7.7 on Playwright 1.56.0   | arbitrary sites                                                                  | none: the Mac cache holds no chromium for 1.56.0 (unverified launch) | off                                                          | stable Chrome, sandbox on (R7)                                             |
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
  Google's package itself installs, and unattended upgrades already run daily on the host. A dotfiles download script
  would rebuild what apt provides, the same shape as the pinned-set script this plan shrinks. Governs R1, R2.
- **The Mac keeps Google's own updater, not Homebrew.** Chrome is already installed outside Homebrew and updated by
  Google. The cask declares `auto_updates`, so `brew-upgrade`'s `bu --no-greedy` would never upgrade it anyway. Governs
  R3.
- **Dotfiles adds no AppArmor profile for stable Chrome.** Ubuntu's own `chrome` profile already grants `userns` at the
  install path, and the setuid helper is the fallback when no profile is loaded. Both claims are measured only once the
  package is installed (third Outstanding Question). Governs R5.
- **gstack moves by pointing, not patching.** `GSTACK_CHROMIUM_PATH` reaches every browse launch path, so dotfiles sets
  it and edits nothing inside gstack. gstack keeps fetching its own pinned Chromium on each Playwright bump until
  upstream fixes its probes (Dependencies). PR #431's registration keeps that fetch from deleting anything else. Governs
  R6.
- **The pinned-set machinery shrinks to what still launches from it.** It does not disappear outright, because WebKit
  has no system alternative and gstack and crawl4ai still install their own pinned builds into the shared cache. Governs
  R12, R13.

### Requirements

**Install and updates**

- R1. The Linux server has Google Chrome stable installed from Google's signed apt repository at its standard path. The
  install is declared in dotfiles and applied by a deploy script the operator runs, never by an ad hoc `sudo` command.
- R2. Chrome on the Linux server updates without operator action within a day of Google publishing a new stable build to
  its apt repository.
- R3. The Mac keeps its existing Google-updated Chrome. Dotfiles neither installs a second copy nor moves it under
  Homebrew.
- R4. A check that changes nothing reports, on each machine, when Chrome is missing or older than the newest stable
  build Google offers that machine's update channel, and names the command that fixes it.

**Sandbox**

- R5. Stable Chrome launched from Playwright with `chromiumSandbox: true` starts with Chromium's sandbox active on the
  Linux server, under the host's userns restriction, without the dotfiles Playwright AppArmor profile.

**Browsing agents**

- R6. gstack browse on both machines launches stable Chrome with its sandbox on, through every launch path gstack
  exposes for a custom browser.
- R7. crawl4ai on both machines (the CLI, the crawl4ai skill's scripts, and repos that import it) launches stable Chrome
  with its sandbox on.
- R8. The guidance agents read before writing browser automation tells any script that opens pages Brett does not
  control to launch stable Chrome with the sandbox on. That guidance is the CLI tools guide and the browser-related
  skills, and its form is `channel: 'chrome'` with `chromiumSandbox: true` for Playwright, or the equivalent for other
  libraries.
- R9. No browsing agent on either machine passes `--no-sandbox` outside a context where the sandbox cannot work (root, a
  container, CI).

**Test suites**

- R10. Each e2e suite's CI keeps running its Chromium-family projects on the Playwright-pinned build.
- R11. Each e2e suite can run its Chromium-family projects on stable Chrome locally through one switch with the same
  name in every suite. Whether that switch is the local default is the first Outstanding Question.

**Provisioning**

- R12. The dotfiles-provisioned Playwright set carries only the browsers some consumer on the machine still launches
  from it. Its registration with Playwright's cleanup, its `--check`, and its aliases cover exactly that set.
- R13. No AppArmor grant stays deployed for a browser binary that nothing launches with its sandbox on.

**Docs**

- R14. The Playwright runbook, the CLI tools guide, and the solutions docs on Playwright launch describe which consumers
  use stable Chrome and which use a pinned build, and why. Each states the boot-time AppArmor behavior as measured.

### Acceptance Examples

- AE1. **Covers R6, R9.** **Given** stable Chrome is installed and gstack is pointed at it, **when**
  `browse goto https://dv-g3b-emudhra.we-have-a-problem.com/` runs, **then** the navigation fails with a certificate
  error, and the browser's renderer processes run in their own user namespace.
- AE2. **Covers R2, R4.** **Given** Google publishes a new stable build, **when** the host's next daily
  unattended-upgrade run completes, **then** the installed version matches it and the R4 check passes. **Given**
  Google's origin is missing from the unattended-upgrade configuration, **when** the R4 check runs a day after a
  release, **then** it exits non-zero and names the deploy command.
- AE3. **Covers R5.** **Given** stable Chrome is installed, **when** Playwright launches it with `channel: 'chrome'` and
  `chromiumSandbox: true` on a boot where Ubuntu's `chrome` profile is loaded, **then** it starts and its renderers have
  their own user and PID namespaces. **When** the same launch runs with that profile unloaded, **then** it still starts
  sandboxed through the setuid helper.
- AE4. **Covers R7, R9.** **Given** crawl4ai is configured by dotfiles, **when** it crawls a page, **then** the browser
  process is `/opt/google/chrome/chrome` (or the Mac's Chrome) and its command line carries no `--no-sandbox`.
- AE5. **Covers R11, R12.** **Given** Brett chose stable Chrome as the local default, **when** the deploy script's
  `--check` runs, **then** it passes with no chromium or headless-shell directory and no chromium aliases in the set.
  lmgroktfy's, meum-sites', and streamsgrp's suites, and agentnative-site's Chromium-family projects, pass locally on
  stable Chrome. agentnative-site's WebKit projects still pass on the provisioned WebKit.
- AE6. **Covers R10.** **Given** any of the four suites opens a pull request, **when** CI runs its e2e job, **then** the
  Chromium projects run on the pinned build that the suite's `@playwright/test` version installs, as they do today.

### What Happens to the Pinned-Browser Machinery

| Item                                                             | Today                                                                     | Under the recommendation                                                                                                                                                           |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/playwright-browsers-deploy.sh`                          | provisions chromium, headless shell, WebKit, ffmpeg for Playwright 1.62.1 | provisions WebKit and ffmpeg only if Brett picks stable Chrome for local e2e. Otherwise it is unchanged, because the e2e suites still launch chromium from it.                     |
| Chromium aliases 1223 and 1228                                   | serve crawl4ai 0.8.9 (now 0.9.5, which uses 1248) and the 1.61.1 suites   | 1223's named consumer, crawl4ai 0.8.9, has moved to 1248, and no other Playwright 1.60.0 consumer was found. 1228 goes with the chromium entries above.                            |
| PR #431's `.links` registration and `--check`                    | registers the whole set                                                   | still needed for whatever the set keeps, because gstack's and crawl4ai's installs still run Playwright's cleanup against the shared cache                                          |
| gstack's own `playwright install chromium`                       | fetches 1248 into the shared cache when its probe fails                   | unchanged until upstream honors `GSTACK_CHROMIUM_PATH` in its probes (Dependencies). Harmless under #431.                                                                          |
| `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`   | one shared cache; no auto-download on `bun install`                       | both stay: WebKit and the tool-pinned builds still land in that one cache                                                                                                          |
| `config/apparmor.d/playwright` and `apparmor-playwright.service` | grant `userns` to pinned chromium and headless shell                      | retired once no pinned build launches sandbox-on (R13). That holds when gstack and crawl4ai run on stable Chrome, because Playwright's default and the e2e suites run sandbox-off. |
| `scripts/playwright-deps-deploy.sh`                              | entry point for binaries, AppArmor, opt-in apt deps                       | keeps the WebKit apt-deps role. Its `--chromium` deps are what the Chrome deb's own dependencies install.                                                                          |

### Scope Boundaries

- CI moving to `channel: 'chrome'` on the runner's preinstalled Chrome is deferred. The runner image's Chrome
  (156.0.8078.47 in image 20261026) moves on GitHub's schedule, which is the drift the pin exists to prevent.
- WebKit stays Playwright-provisioned. There is no system WebKitGTK build that Playwright drives.
- Playwright MCP is not adopted. None is configured on either machine. If one is ever added, it is pinned to an exact
  version that has cleared the age gate, at least 0.0.40 (CVE-2025-9611), and runs with stable Chrome.
- Browsers in containers or as root keep the sandbox off by necessity. No container on either machine runs a browser
  today.
- Lifting `kernel.apparmor_restrict_unprivileged_userns` host-wide
  (`docs/plans/2026-09-15-1428-feat-unprivileged-userns-host-plan.md`) is independent of this plan, and this plan needs
  no change to it.
- The headed GStack Browser on the Mac is a custom Chromium build and out of scope.
- emdash (an upstream third-party clone) and cf_office_hours (no Playwright config) are out of scope.
- Microsoft Edge is not installed and not proposed.

### Dependencies / Assumptions

- **gstack upstream.** gstack's `ensure_playwright_browser()` in `setup` and its `bin/gstack-browser-ensure` probe with
  a bare `chromium.launch()`, so neither honors `GSTACK_CHROMIUM_PATH`, and `gstack-browser-ensure` ignores
  `GSTACK_SKIP_PLAYWRIGHT`. Skills run `gstack-browser-ensure` on every browser task. Brett files the issue; this plan
  does not wait on it.
- **gstack's CRLSet issue.** garrytan/gstack#3338 reports stable Chrome 155 trusting the eMudhra intermediates through
  `GSTACK_CHROMIUM_PATH`. Stable 156.0.8078.79 rejects them even with component updates disabled (Measured Findings), so
  the fix now ships in the binary. #3440's broader point stands: a Playwright-launched profile never receives component
  updates, so revocations that arrive only by CRLSet reach it with the next binary update and no sooner. Daily updates
  (R2) bound that delay.
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
  Playwright recommends.
- **Is Chrome exempt from the seven-day release-age gate?** (Brett) Recommendation: yes, recorded as a named exemption
  in the supply-chain guide. Google's apt index serves only the newest stable build, so apt cannot hold Chrome back
  seven days without mirroring old debs. The builds the gate would delay are the ones fixing exploited-in-the-wild bugs.
  The gate's threat, a malicious upload to an open registry, does not match a vendor-signed first-party repository.
- **Does stable Chrome's sandbox work at `/opt/google/chrome/chrome` under this host's userns restriction, and does
  `channel: 'chrome'` run a real suite?** (measurement, blocked on Brett installing the package) Needed for R5 and AE3.
  Expected: the namespace sandbox through Ubuntu's `chrome` profile, and the setuid helper when that profile is not
  loaded.

**Deferred to Planning**

- How Google's origin joins unattended upgrades: a copy-deployed `apt.conf.d` drop-in in the `config/sysctl.d` pattern,
  and whether an `Origins-Pattern` in a separate file adds to the stock Allowed-Origins rather than replacing them.
- Where the machine-wide pointers live (likely `config/shell/*.sh` exports for `GSTACK_CHROMIUM_PATH` and
  `CRAWL4AI_CHROMIUM_SANDBOX`), and how crawl4ai's CLI and skill scripts pick up `chrome_channel` without per-script
  edits.
- What populated `~/.cache/puppeteer` on the Linux server (bun's cache holds puppeteer and puppeteer-core 24.43.1), and
  whether that tool should get `PUPPETEER_EXECUTABLE_PATH` or the cache should go.
- Whether the Mac's crawl4ai 0.7.7 launches at all today, and whether the Mac's gstack 1.93.42 should move to the Linux
  server's version first.
- The R4 check's source of truth for "newest stable", per machine: Google's apt index on Linux, and on the Mac either
  Google's version history API or the updater's own state.
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
