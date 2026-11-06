---
title: System Browser Set and Agent Browsing - Plan
type: feat
date: 2026-11-03
topic: system-browser-set-and-agent-browsing
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# System Browser Set and Agent Browsing - Plan

## Goal Capsule

- **Objective:** Two browsers on every host that deploys them, and no others beyond what a repo's suite needs: Chrome
  for Testing (CfT) for tests, gstack, crawl4ai, and scripts, and Google Chrome stable for agents on pages nobody
  vetted, with the sandbox on, certificate checks enforced, and revocation data live once a session has run for about 15
  seconds. dotfiles owns both, keeps both current, and points every consumer at them through config and environment
  variables. No consumer downloads a browser.
- **Means:** One CfT build (full and headless shell) and one ffmpeg, aliased for the Playwright revisions consumers ask
  for, behind a wrapper at the alias path that drops the sandbox-off flags and clears the environment, and the one
  WebKit build agentnative-site's suite uses, which matches the Playwright library the repos pin and has no alias. A
  hardened launcher over Chrome, driven by a pinned agent-browser without its skill, and the same launcher over CfT for
  gstack. One Playwright library version across our repos, a check for drift from it, and a check for browsers outside
  the set.
- **Brett's direction (verbatim):** "let's harden a single system playwright and tests. We update it separately from any
  repo. repo's use what's available on the system, not their own preferences. gstack, etc incl"; "also need to ensure
  that our two browsers chrome and cft are updated often."; "to limit the number of browsers we have and also highly
  control which browsers different tools use through direct config and ENV VARs". His answers are in Settled Decisions.
- **Product authority:** Requirements govern behavior and Key Decisions record why. The measurements in this plan are
  the evidence. Where a solutions doc or runbook disagrees with a measurement here, the doc is what gets rewritten.
- **Status:** No phase is built on `dev`; PR #431's `.links` registration and `--check` are. Phase 1 starts from `dev`
  once this plan's three reviews are done. The stale builds stay until phase 1 deploys (decision 11).
- **Execution profile:** User-space provisioning, shell config, a launcher, an alias wrapper, a stowed shim, doc
  updates, and hourly update jobs. Chrome adds a system package and an apt timer that the operator applies, because the
  agent's settings deny `sudo`. Proof is runtime measurement on both machines. bats covers the script seams.
- **Stop conditions:** Stop and bring the finding to Brett if a real suite fails on a candidate CfT build where it
  passes on the set's current build, if the launcher or wrapper breaks a consumer's pipe connection, if any browser
  behind them runs a renderer without its own user and PID namespaces and seccomp filter mode on the Linux server, or
  without Chrome's seatbelt switch on the Mac, or if a phase's diff passes 1.5 times its size budget before review.
- **Who finishes:** Each phase except phase 3, a measurement gate, is one PR, built by its own agent slot from `dev`
  with the phase's `Touches:` and `Adds:` lines as its scope (Build Phases). The operator runs every `/etc` step. Brett
  files the gstack issue, which is drafted and pending with him.

---

## Product Contract

### Summary

Two browsers, one owner. CfT serves tests, gstack with its headed sessions, crawl4ai, and scripts. Google Chrome stable,
behind a hardened launcher and driven by a pinned agent-browser, serves agents on pages nobody vetted. WebKit stays
beside them because agentnative-site's `mobile-ios`, `tablet`, and `web-audit-webkit` projects use it, and no other repo
in scope does. dotfiles names every version once, points every consumer at them, turns every download off, and reports
anything else it finds on a host.

The per-Playwright-version browser map goes. One CfT build and one ffmpeg are aliased for what a consumer at Playwright
1.57 or later can ask for, and one WebKit build serves the pinned library. Chromium and ffmpeg alias in both directions.
WebKit does not alias: it is the revision the Playwright library the repos pin names, because a library fails on a
WebKit far from its own (measured). Consumers at 1.56 or earlier need `executablePath` or an upgrade. Every Chromium
alias's executable is a wrapper that drops the sandbox-off flags and clears the environment, so a bare
`chromium.launch()` runs sandboxed with no secrets in the browser. A new build reaches the wrappers only after it
launches through one, and the build they ran before stays on disk until the next move.

Both browsers stay current without a person. An hourly job takes each new Chrome stable release's CfT build through the
real suites and moves the pin, and hosts pick it up within the hour. Chrome updates from Google's apt repository on an
hourly timer. Browser builds are exempt from the seven-day gate; agent-browser and the Playwright library stay under it.
Our repos share one Playwright library version named in dotfiles, while gstack and crawl4ai keep the versions they ship
and run the system browsers. Browser updates never wait on the library pin. CI is unchanged.

### Problem Frame

The Linux server runs its browser consumers on CfT builds that Playwright pins. The canonical set carries CfT
151.0.7922.34 for Playwright 1.61.1 and 1.62.1; gstack and crawl4ai add their own 156.0.8078.4. The Mac's gstack runs
CfT 151.0.7922.34. CfT Stable is 157.0.8103.38 (checked 2026-11-05). Three things follow.

- **Staleness.** Both pinned builds trust a CA intermediate whose key was compromised on 2026-10-17, and the 151 build
  predates two fixes Google reports as exploited in the wild.
- **Sandbox off.** Playwright's default launch passes `--no-sandbox`, and crawl4ai does the same.
- **Upkeep.** A revision map per Playwright version, alias symlinks for lagging tools, an io_uring extractor workaround,
  and a `.links` registration exist only to keep each tool's own pin satisfied. On 2026-11-03 another tool's
  `playwright install` deleted the canonical set and broke three repos' e2e at once.

### What Playwright Requires From a Browser

Playwright pins a build for reproducibility. It does not enforce the pin.

| Aspect            | What Playwright does                                                                                                                                                                                                                                                                  | Evidence                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Which file runs   | Default headless launch: `<browsers>/chromium_headless_shell-<rev>/chrome-headless-shell-linux64/chrome-headless-shell`. `channel: 'chromium'`: `<browsers>/chromium-<rev>/chrome-linux64/chrome`. `channel: 'chrome'`: only `/opt/google/chrome/chrome`. `executablePath`: any file. | `EXECUTABLE_PATHS` in `coreBundle.js`                   |
| Revision          | `browsers.json` names a revision and a `browserVersion`. They choose the directory and the download URL. Nothing compares the running build with the pin.                                                                                                                             | Aliased runs below                                      |
| Protocol          | CDP over `--remote-debugging-pipe`, with no minimum or maximum version check. A few code paths branch on `majorVersion() >= 143`. A method Chrome removes fails at runtime as a protocol error, not at launch.                                                                        | `coreBundle.js`; a launcher that `exec`s keeps the pipe |
| Support statement | `executablePath`: "Note that Playwright only works with the bundled Chromium, Firefox or WebKit, use at your own risk." Channels: "the current Playwright version will support Stable and Beta channels."                                                                             | `types.d.ts`; playwright.dev/docs/browsers              |
| Directory layout  | Playwright 1.57 and later use `chrome-linux64`. Playwright 1.56 and earlier use `chrome-linux`, so a CfT alias cannot serve them; they need `executablePath` or an upgrade.                                                                                                           | `registry/index.js` of 1.55.1, 1.57.0, 1.59.1           |
| Install markers   | `INSTALLATION_COMPLETE` makes `playwright install` a no-op. `DEPENDENCIES_VALIDATED` skips the host check. Alias directories carry both.                                                                                                                                              | `scripts/playwright-browsers-deploy.sh`                 |
| Cleanup           | `playwright install` deletes directories no `.links` client claims, unless `PLAYWRIGHT_SKIP_BROWSER_GC` is set.                                                                                                                                                                       | `coreBundle.js` line 29090; solutions doc               |
| WebKit            | Playwright's own patched build; no branded Safari. It has its own revision per release, and a newer Playwright cannot drive an older one.                                                                                                                                             | playwright.dev/docs/browsers; measured below            |
| ffmpeg            | A revision per Playwright release. Any named browser install adds it, and video recording fails if it is missing. One build served both revisions in use.                                                                                                                             | `coreBundle.js`; measured below                         |

**Drift, measured with a 23-step probe.** The probe covers launch, context, tracing, navigation, fill, click, role
locators, aria snapshot, frames, evaluate, console, workers, routing, popups, downloads, dialogs, screenshots, PDF,
cookies and storage state, media emulation, coverage, video, and close. The rows at CfT 157 ran against the full binary
and the headless shell; the canary and CfT 151 rows ran against the full binary.

| Playwright                                     | Its pin       | Build under test          | Drift             | Result                                                                                                                                                                                               |
| ---------------------------------------------- | ------------- | ------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.40.0, 1.45.0, 1.49.1                         | 120, 127, 131 | CfT 157.0.8103.38         | +37 to +26 majors | 22 of 23 steps; video not run (no ffmpeg for those revisions here). A `Target closed` rejection stays unhandled, and Node 26 exits on it unless trapped. Not checked against each version's own pin. |
| 1.52.0, 1.55.1, 1.57.0, 1.59.1, 1.60.0, 1.62.1 | 136 to 151    | CfT 157                   | +21 to +6         | 22 of 23; video not run for the same reason                                                                                                                                                          |
| 1.61.1, 1.64.1                                 | 149, 156      | CfT 157                   | +8, +1            | 23 of 23                                                                                                                                                                                             |
| 1.61.1, 1.64.1                                 | 149, 156      | CfT 159.0.8141.0 (canary) | +10, +3           | 23 of 23                                                                                                                                                                                             |
| 1.64.1                                         | 156           | CfT 151.0.7922.34         | -5                | 23 of 23                                                                                                                                                                                             |

No break appeared across that range, and nothing guarantees the next build. So the set moves through a gate that runs
the real suites, and a Chrome change that breaks Playwright stops at the bump instead of reaching every consumer at
once.

**Real suites on the Linux server, from scratch clones.** Each arm used a scratch `PLAYWRIGHT_BROWSERS_PATH` with the
revision the suite asks for mapped to the build under test. "Shell" is Playwright's default headless shell; "full" is
the same suite with `channel: 'chromium'`.

| Consumer                                                                | Playwright      | Control build                                             | CfT 157 shell                                                             | CfT 157 full                  |
| ----------------------------------------------------------------------- | --------------- | --------------------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------- |
| lmgroktfy (`apps/web`)                                                  | 1.61.1          | 16 of 16, 22.5 s (CfT 151)                                | 16 of 16, 22.1 s                                                          | 16 of 16, 22.6 s              |
| meum-sites                                                              | 1.61.1          | 65 of 65, 115.8 s (CfT 151)                               | 65 of 65, 105.4 s                                                         | 65 of 65, 118.9 s             |
| agentnative-site (`chromium`, `mobile-android`, `mobile-ios`, `tablet`) | 1.61.1          | 260 pass, 10 fail, 8 skip, 116.8 s (CfT 151, WebKit 2311) | same 260 and same 10, 114.1 s                                             | same 260 and same 10, 146.6 s |
| gstack browse (10 of its `browse/test` files, 406 tests)                | 1.64.1          | 404 pass, 2 fail, 61.9 s (CfT 156)                        | 404 pass, same 2 fail, 59.1 s                                             | not run                       |
| streamsgrp                                                              | 1.61.1          | no browser launched                                       | no browser launched                                                       | no browser launched           |
| crawl4ai 0.9.5 (`crwl crawl`)                                           | 1.64.1 (Python) | not run                                                   | fixture page, example.com, and news.ycombinator.com all returned markdown | not run                       |

- agentnative-site's 10 failures and gstack's 2 are the same tests on every arm, so the browser does not cause them. The
  first agentnative-site failure is an origin assertion against the production origin in a scratch build.
- streamsgrp's 19 tests all use the `request` fixture and never open a page. Against a local `wrangler dev` they gave 1
  pass and 18 fails on every arm, because that local worker answers its routes differently from staging. Its Access
  token was not read for this run.
- WebKit tolerates drift in one direction only. agentnative-site's `mobile-ios` and `tablet` projects gave 88 pass, 4
  fail, 8 skip on Playwright 1.61.1 with WebKit 2311 (its own), 2336, and 2370 (1.64.1's) aliased as 2311, and on
  Playwright 1.64.1 with its own 2370; the 4 fails match. Playwright 1.64.1 on the older WebKit 2311 fails on `newPage`
  with `Protocol error (Page.overrideSetting): Unknown setting: PushAPIEnabled` and hit the run's 280 s limit, and
  Playwright 1.61.1 on the newer WebKit 2388 fails 98 of 100 on `newPage` with
  `Protocol error (Emulation.setAuthCredentials)`. So the set's WebKit is the revision the pinned library names.
- One ffmpeg serves both revisions in use. Playwright 1.61.1 and 1.64.1 each passed the video step with the ffmpeg 1011
  build and with the 1013 build under either revision name.
- Nothing here ran on the Mac; its first run is the deploy gate (AE2).

**gstack and crawl4ai need no pointer.** With revision 1248 aliased, gstack's own probe (`bin/gstack-browser-ensure`)
printed `BROWSER_OK node 157.0.8103.38`, and its bare `chromium.launch()` calls resolve the same way. The probe that
ignores `GSTACK_CHROMIUM_PATH` stops being a problem, because nothing is left for it to fetch. crawl4ai's default
`chromium` channel resolves through the same alias.

**CfT works for tests.** For this purpose it is also preferable to Chrome stable: it can be pinned to a version, it
ships the headless shell that Playwright's default launch runs, and it has no updater to move it between runs.

### Is CfT Safe for Open-Web Browsing

Chromium's security FAQ answers directly: "It does not auto-update. Therefore, it may lack recent fixes for security
bugs. Security bugs can more easily be exploited once their fixes are published in the main Chromium source code
repository and so it is unsafe to use Chrome for Testing to access any untrusted website. You should use Chrome for
Testing only for browser automation and testing purposes, consuming only trustworthy content." It says the same of
`chrome-headless-shell`.

The FAQ's stated reason is staleness. A timer narrows that reason and leaves a gap: some stable releases never get a CfT
build. Every point below was measured on the same version, 157.0.8103.38, except where marked.

| Point                                                                 | CfT                                                                                                                                                                                                                                                                                    | Chrome stable                                                                                                                                              |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Google's position                                                     | Unsafe on untrusted sites                                                                                                                                                                                                                                                              | The browser Google ships to users; no such restriction                                                                                                     |
| Update path                                                           | None. dotfiles would poll and download.                                                                                                                                                                                                                                                | Signed apt index; Google's updater on the Mac                                                                                                              |
| Time behind Linux stable, last 20 releases (2026-08-06 to 2026-11-03) | 15 releases: 0.3 to 1.5 h, median 0.8 h. 3 releases: a newer CfT already existed. 2 releases: no CfT at that version, about 5 days behind.                                                                                                                                             | The Linux stable build, by definition. Each host's unattended run adds up to a day.                                                                        |
| The two gaps                                                          | 151.0.7922.108 (41 security fixes): 122 h until CfT 151.0.7922.138. 154.0.8037.97 (11 security fixes): 113.5 h until CfT 155.                                                                                                                                                          | Shipped                                                                                                                                                    |
| Integrity of the download                                             | HTTPS from `storage.googleapis.com`; the JSON API lists URLs and publishes no hash                                                                                                                                                                                                     | SHA256 in a signed apt index                                                                                                                               |
| Compiled-in distrust, default flags                                   | Rejects the compromised-CA host with `ERR_CERT_REVOKED`                                                                                                                                                                                                                                | Same                                                                                                                                                       |
| CRLSet under Playwright's default flags                               | None: `--disable-component-update` blocks it, and `revoked.badssl.com` loads with status 200                                                                                                                                                                                           | Same                                                                                                                                                       |
| CRLSet with that one flag removed                                     | Version 10881 arrives at about 62 s; `revoked.badssl.com` then fails with `ERR_CERT_REVOKED`                                                                                                                                                                                           | Version 10881 at about 70 s; same result                                                                                                                   |
| Time until a revoked certificate fails, one context held open         | 63 to 65 s on a fresh profile; 14 s with `--component-updater=fast-update`; 9 s on a relaunch of a profile holding a CRLSet; 6 s with the seeded config below                                                                                                                          | 63 to 65 s; 14 s with that flag; 7 s on a relaunch                                                                                                         |
| First navigation of any session                                       | `revoked.badssl.com` loads with status 200 in every arm, the seeded config included                                                                                                                                                                                                    | Same                                                                                                                                                       |
| A public page reaching loopback                                       | Blocked: `fetch` from `https://example.com` to `127.0.0.1` fails, and the listener records no hit, on the full binary and the shell                                                                                                                                                    | Same                                                                                                                                                       |
| Other components with that flag removed                               | 5 of 21 populated (CRLSet, Subresource Filter, Hyphenation, MEI Preload, Widevine); PKI Metadata stays 0.0.0.0. `--chrome-for-testing-config` with `requiredComponents: ["*"]` brings 21 of 21 to the versions Chrome holds, except Origin Trials.                                     | 20 of 21 populated, PKI Metadata 1825, no config                                                                                                           |
| Safe Browsing test pages (`testsafebrowsing.appspot.com`, 230 s wait) | Blocked with `ERR_BLOCKED_BY_CLIENT` on 2 of 2 runs when both `--disable-component-update` and `--disable-background-networking` are removed. Loaded with either flag still present, on 1 of 1 run per arm.                                                                            | Blocked on 2 of 2 runs with both removed, and on 1 of 1 with only `--disable-background-networking` removed. Loaded while that flag stayed.                |
| Sandbox                                                               | On unless the launcher disables it. Needs an AppArmor `userns` grant at its path. The dotfiles profile's `chromium-*` glob covers the set, through aliases too. Elsewhere it dies with `FATAL ... No usable sandbox!`. It ships `chrome_sandbox`, not setuid, so there is no fallback. | Same sandbox. Ubuntu's `chrome` profile covers `/opt/google/chrome/chrome`, and a setuid `chrome-sandbox` is the fallback. Measured only at first install. |
| Sandbox measured on the host                                          | CfT 156.0.8078.4 at the covered path: renderers in their own user and PID namespaces, seccomp mode 2, label `playwright-chromium`. CfT 157 at that path waits for the first deploy, because this research left the real cache untouched.                                               | First deploy gate                                                                                                                                          |
| `--load-extension`                                                    | Works: the extension's service worker and panel page load                                                                                                                                                                                                                              | Blocked: no service worker appears                                                                                                                         |
| Headed UI                                                             | A non-removable "Chrome for Testing" banner                                                                                                                                                                                                                                            | None                                                                                                                                                       |

**`requiredComponents` has a cost.** A CfT launch with that config dies when the update servers are unreachable, even
with every component already on disk: through a dead proxy the browser closed about 250 ms after launch. The CfT docs
state this ("Fail Fast"). It fits a testing tool, and it makes every browser start depend on Google's update servers.
Without it, removing the flag gives CRLSet and Safe Browsing in about a minute to a few minutes. The first CRLSet needs
an open browser context.

**No session starts with revocation data.** Every session's first page has only what is compiled in, on either build. A
short crawl never gets more. Safe Browsing was confirmed at a 230 s wait and not at 150 s.

**A hardened launch needs six things**, on either build:

1. No `--no-sandbox` and no `--disable-setuid-sandbox`.
2. An AppArmor `userns` grant at the binary's real path on Ubuntu.
3. No `--disable-component-update`, for CRLSet.
4. No `--disable-background-networking`, for Safe Browsing. This lets the browser's background traffic to Google
   through.
5. No `--ignore-certificate-errors`, and any tool setting that ignores HTTPS errors turned off.
6. A clean environment. A browser inherits its caller's: a control launch showed 169 variables in the browser process, a
   planted token among them, and agent shells carry API keys from `~/.secrets`. Through a wrapper that clears the
   environment it showed 5 and no token.

**One launcher enforces this for every tool that accepts an executable path.** A trial script that drops those flags and
`exec`s the real binary was measured under a `chromium.launch()` naming it with no sandbox option: no `--no-sandbox` on
the process, renderers sandboxed, label `playwright-chromium`, pipes intact, `revoked.badssl.com` loading at launch and
failing with `ERR_CERT_REVOKED` after 100 s. Under agent-browser, the launcher kept `--args "--no-sandbox"` from
reaching the browser, and the revoked host failed by 140 s. The launcher was not measured over Chrome stable or on the
Mac.

**A sandbox-only wrapper at the alias reaches bare launches too.** Playwright has no environment setting for its
`--no-sandbox` default, so the alias path is the only layer a bare `chromium.launch()` passes through. A trial wrapper
there dropped only the sandbox-off flags, cleared the environment, and `exec`ed the AppArmor-covered CfT 151 build.
Default launches then ran renderers in their own user and PID namespaces with seccomp mode 2, on the shell and the full
binary. Real suites matched their controls at similar wall time: lmgroktfy 16 of 16 on both, meum-sites 65 of 65,
agentnative-site's `chromium` and `mobile-android` projects 172 pass with the same 6 fails. gstack's 10 test files gave
403 of 406: the same 2 fails, plus one test asserting that the process's command line starts with the configured path,
which a wrapper's `exec` changes. The cost is that a host whose AppArmor profile is not loaded fails every Playwright
launch with `No usable sandbox!`, where today only sandbox-on launches fail. R20 accepts that cost.

### "No Chrome?"

Chrome is not needed for tests, gstack, crawl4ai, or scripts, where CfT is the better fit. It is kept for one job:
agents on pages nobody vetted, on a build Google supports for that.

|                      | Chrome stable                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Buys**             | Google's supported browser for untrusted pages. Every Linux stable release, including those CfT skips (41 and 11 security fixes in the last 20 releases). A signed update path. A setuid sandbox fallback when no AppArmor profile is loaded. PKI Metadata and the other components with no config. The standard path that Playwright CLI, Playwright MCP, Chrome DevTools, and agent-browser all find by themselves. |
| **Costs on Linux**   | One operator `sudo` deploy per host. Google's apt source and keyring, `/etc/cron.daily/google-chrome`, a `chromemgmt` group, and update-alternatives entries for `google-chrome` and `x-www-browser`. An hourly system timer for the list refresh and upgrade. 453 MB. A version that moves on Google's schedule, with running browsers left on the replaced executable until restarted.                              |
| **Costs on the Mac** | None new: Chrome 156.0.8078.80 is already installed and updated by Google.                                                                                                                                                                                                                                                                                                                                            |
| **Cannot do**        | Load gstack's side panel, because branded Chrome blocks `--load-extension`. So gstack runs on CfT.                                                                                                                                                                                                                                                                                                                    |

### Agent Browsers

Each tool was installed into a scratch directory at the newest version the seven-day gate allows on 2026-11-03, and
driven through one job on a local page: open, snapshot, fill, click, read a heading, follow a link to a new tab. All
three candidates finished it.

|                                            | Playwright CLI                                                                                                                                                | Chrome DevTools for agents (CLI)                                                                                                | agent-browser                                                                                                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Publisher, license                         | Microsoft, Apache-2.0                                                                                                                                         | Google, Apache-2.0                                                                                                              | Vercel Labs, Apache-2.0                                                                                                                                          |
| Newest / newest the gate allows            | 0.1.23 / 0.1.22 (2026-09-28)                                                                                                                                  | 1.12.0 / 1.12.0 (2026-10-22)                                                                                                    | 0.41.2 / 0.40.0 (2026-10-27)                                                                                                                                     |
| Size installed                             | 19 MB (bundles `playwright-core` 1.64.0-alpha)                                                                                                                | 15 MB, no dependencies                                                                                                          | 115 MB (native binaries for seven platforms); bun blocks its postinstall and the launcher still works                                                            |
| Browser by default                         | `chrome` channel at `/opt/google/chrome/chrome`; absent, it fails and prints `Run "npx playwright install chrome"`                                            | Stable at `/opt/google/chrome/chrome`; absent, it fails                                                                         | Its own download, then Chrome on PATH, then `~/.cache/puppeteer`, then `~/.cache/ms-playwright`. On this host that means the Puppeteer cache's stale 133 or 150. |
| Downloads a browser                        | Only if asked (`install-browser`)                                                                                                                             | No                                                                                                                              | `agent-browser install` downloads CfT; `doctor --fix` can reinstall                                                                                              |
| Points at a chosen binary by               | `PLAYWRIGHT_MCP_EXECUTABLE_PATH`, or a config named by `PLAYWRIGHT_MCP_CONFIG`                                                                                | `--executablePath` on `start`                                                                                                   | `AGENT_BROWSER_EXECUTABLE_PATH`                                                                                                                                  |
| Sandbox                                    | On for branded channels; off for CfT and `executablePath` unless `PLAYWRIGHT_MCP_SANDBOX=true`. Measured on with it set.                                      | On, measured at the covered CfT path                                                                                            | On unless `CI` is set, or root, or a container. Measured on at the covered path. At an uncovered path it fails and suggests `--args "--no-sandbox"`.             |
| CRLSet with no launcher                    | Blocks it; `ignoreDefaultArgs` in the config lifts that (measured `ERR_CERT_REVOKED`)                                                                         | Does not block it (measured `ERR_CERT_REVOKED`)                                                                                 | Hard-coded; only the launcher lifts it                                                                                                                           |
| Separating two agents                      | `PLAYWRIGHT_CLI_SESSION` or `-s=`; measured apart                                                                                                             | One browser for all, including with `CHROME_DEVTOOLS_MCP_SESSION_ID`; a per-agent `XDG_RUNTIME_DIR` separated them              | `AGENT_BROWSER_SESSION`; measured apart                                                                                                                          |
| Phones home                                | Update check, off with `NO_UPDATE_NOTIFIER` or `CI`                                                                                                           | Usage statistics on by default; update check. `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`, `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS` | None documented; `upgrade` is a command                                                                                                                          |
| Guardrails for untrusted pages             | `PLAYWRIGHT_MCP_ALLOWED_ORIGINS`, which its docs say is not a security boundary; file access limited to workspace roots                                       | None                                                                                                                            | `--allowed-domains` (measured blocking), `--content-boundaries` (measured nonce markers), `--max-output` (measured cap), `--action-policy`, encrypted auth vault |
| Marks page content as untrusted            | No; snapshots return bare                                                                                                                                     | No                                                                                                                              | `--content-boundaries`, off by default. gstack browse wraps reads in an untrusted-content envelope                                                               |
| Certificate bypass a launcher cannot strip | `PLAYWRIGHT_MCP_IGNORE_HTTPS_ERRORS`                                                                                                                          | `--acceptInsecureCerts`                                                                                                         | `--ignore-https-errors`                                                                                                                                          |
| Known advisories                           | `@playwright/mcp` before 0.0.40 (CVE-2025-9611); `playwright` before 1.55.1 (CVE-2025-59288)                                                                  | Before 1.1.0 (CVE-2026-53765, CVE-2026-53766)                                                                                   | None listed                                                                                                                                                      |
| Release pace                               | About monthly lately                                                                                                                                          | 2 in the last 3 weeks                                                                                                           | 6 in the last 9 days                                                                                                                                             |
| Install under the gate                     | `bunx @playwright/cli@0.1.22`; the gate rejected 0.1.23 with `blocked by minimum-release-age`. Its banner prints `npm install -g ...@latest` unless silenced. | `bunx chrome-devtools-mcp@1.12.0`                                                                                               | `bunx agent-browser@0.40.0`; never `agent-browser upgrade`                                                                                                       |
| Homebrew formula                           | `playwright-cli` 0.1.23                                                                                                                                       | `chrome-devtools-mcp` 1.12.0                                                                                                    | `agent-browser` 0.41.1                                                                                                                                           |

Homebrew installs fall outside the seven-day gate, so these tools install through bun at exact pins.

**Token cost with Claude Code.** From Maximilian Fabian Kirchner's benchmark, published 2026-10-31, with Claude Code
2.1.303, Opus 5.5 at medium effort, and Chrome 155: one signed-in web-app job, 12 runs per setup, across macOS, WSL, and
Windows. Its 216-row table recomputes to the published medians. It did not run on a Linux server, and it measures one
job.

| Setup (median)       | Playwright              | Chrome DevTools   | agent-browser       |
| -------------------- | ----------------------- | ----------------- | ------------------- |
| CLI + official skill | 332K input, $0.32, 90 s | 341K, $0.32, 97 s | 652K, $0.48, 104 s  |
| CLI, no skill        | 353K, $0.33, 99 s       | 348K, $0.32, 98 s | 304K, $0.28, 96 s   |
| MCP                  | 513K, $0.41, 98 s       | 517K, $0.40, 72 s | 1.59M, $1.02, 106 s |

Connection matters more than tool. The CLI forms sit within about 15 percent of each other, excluding agent-browser's
skill. MCP costs about 1.5 times as much, or 5 times for agent-browser. A script over CDP did the same job in a median
1.5 s with no model calls, which is the pattern for any repeated job. Most of each run is model time; the tool itself
took 4 to 18 s.

**What each tool loads, measured here at the versions above** (about 4 characters per token):

|                                 | Playwright CLI                                                | Chrome DevTools                        | agent-browser                                                                                     | gstack browse              |
| ------------------------------- | ------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------- |
| `--help`                        | 7,651                                                         | 21,572                                 | 28,109, opening with "Start here (for AI agents): agent-browser skills get core --full" (150,835) | 2,635                      |
| Official skill                  | 15,428                                                        | 12,031                                 | 3,457 stub plus 39,038 guide                                                                      | 34,684 (`browse/SKILL.md`) |
| MCP `tools/list`                | 20,286 (25 tools)                                             | 29,661 (32 tools); 1,201 with `--slim` | 82,282 (29 tools, core profile)                                                                   | none                       |
| Snapshot of a 200-row test page | 18,534 (or a 265-character reply with the snapshot in a file) | 7,970                                  | 13,521                                                                                            | 16,736                     |

**Others considered, not trialed:**

- browser-use (0.13.14, MIT) and Stagehand (4.3.0, MIT) run a model of their own inside the tool, a second agent loop on
  top of Claude Code.
- browser-harness (0.1.13, MIT), mcp-chrome, and gstack's Aside drive the person's real signed-in browser, a different
  trust model.
- Lightpanda (AGPL-3.0) and Obscura (Apache-2.0) are non-Chromium engines; agent-browser's own docs warn of Obscura's
  fidelity limits.
- patchright (Apache-2.0) and Camoufox (MPL-2.0) aim at evading bot detection, which is not this plan's goal.
- dev-browser (1.0.0, MIT) is a skill over Playwright with no advantage over the Playwright CLI for this job.

### The Split

| Consumer                               | Browser                         | How it is pointed                                                            | Who updates the browser                                |
| -------------------------------------- | ------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------ |
| e2e suites, locally                    | System CfT through the wrapper  | `PLAYWRIGHT_BROWSERS_PATH`                                                   | Hourly job, gated on the suites (R4)                   |
| e2e suites, CI                         | Each repo's own pinned build    | The repo's workflow                                                          | Unchanged                                              |
| gstack, headless and headed            | System CfT through the launcher | `GSTACK_CHROMIUM_PATH`; `PLAYWRIGHT_BROWSERS_PATH` for its probes            | Same hourly job                                        |
| crawl4ai                               | System CfT through the wrapper  | `PLAYWRIGHT_BROWSERS_PATH`; `~/.crawl4ai/chromium.path` for its managed mode | Same hourly job                                        |
| Bare Playwright scripts                | System CfT through the wrapper  | `PLAYWRIGHT_BROWSERS_PATH`                                                   | Same hourly job                                        |
| Puppeteer, Lighthouse, chrome-launcher | System CfT through the wrapper  | `PUPPETEER_EXECUTABLE_PATH`, `CHROME_PATH`                                   | Same hourly job                                        |
| agent-browser, on pages nobody vetted  | Chrome through the launcher     | The shim sets `AGENT_BROWSER_EXECUTABLE_PATH`                                | Hourly apt timer on Linux; Google's updater on the Mac |

**How far each runs behind Linux stable, over the last 20 releases.** Chrome: at most about an hour on all 20 [estimated
from the timer]. CfT: at most about 4 hours on 18 [estimated: 0.3 to 1.5 h for CfT to publish (measured), up to 1 h for
the check, the suites and CI, then up to 1 h for a host's pickup], and about 5 days on the 2 releases CfT built no
version for. Those two gaps are CfT's own and no cadence closes them, which is part of why Chrome carries the untrusted
pages.

**Why hourly.** Releases are rare, so the interval sets only how long a release waits to be noticed: 20 Linux stable
releases in 89 days is one about every 4.4 days. Suites, downloads, and upgrades run per release whatever the interval,
and a check that finds nothing costs one small fetch (349 bytes for CfT's channel data, 1,408 for Google's
`Packages.gz`). CfT takes a median 0.8 h to publish, so hourly is where the wait for the check stops being the larger
part of the lag. Daily would add up to 24 h at each of two hops against a 4.4-day release cycle, and would leave Chrome,
the browser carrying the untrusted pages, behind the test set. Every 15 minutes would save at most 45 minutes per hop
for four times the requests, while CfT's own publishing still takes most of an hour.

**Why Chrome for untrusted pages.** Chromium's FAQ calls CfT unsafe for untrusted sites and Google supports Chrome for
them. Chrome ships every Linux stable release, signed, with a setuid sandbox fallback. CfT remains better for everything
else: it has a headless shell, honors `--load-extension`, needs no `sudo`, and stays behind a suite gate. Both receive
CRLSet and Safe Browsing the same way once the flags are gone.

**Why agent-browser, without its skill.** Brett asked "Why not vercel agent-browser?", and the evidence supports it. It
is the cheapest setup in the benchmark (304K input, $0.28, against 353K and 348K for the other two CLIs without skills).
It is the only tool trialed with content boundaries, and the only one with a domain allowlist its docs do not disclaim.
Its costs each have an answer here:

- **Release churn** (6 releases in 9 days): an exact pin under the seven-day gate.
- **Auto-detecting stale caches:** the shim always sets the executable path, and the Puppeteer cache goes.
- **Install and repair verbs that download Chrome:** the shim refuses them.
- **Certificate checks a flag, a variable, or a project `agent-browser.json` can turn off (measured), which the launcher
  cannot strip:** the shim names its own config and refuses the flags.
- **A 28,109-character `--help` that opens by pointing at a 150,835-character skill, and a skill that doubles its token
  cost (652K against 304K):** no skill is loaded, and the guidance carries the commands agents need.

### Other Measured Findings

Measured on the Linux server (Ubuntu 24.04.5, kernel 6.8.0-146, `kernel.apparmor_restrict_unprivileged_userns = 1`) and
read-only on the Mac (macOS 27.0, arm64), 2026-11-03. Chrome stable was taken from Google's apt repository, sha256
checked against the Packages index, and extracted into a scratch directory, not installed.

| Finding                                                                                                                                                                                                                                                                                                                                 | Evidence                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Playwright's default launch passes `--no-sandbox`, and no child process gets its own user or PID namespace. With `chromiumSandbox: true` the pinned headless shell gets both namespaces and seccomp filter mode, under the dotfiles `playwright-chromium-headless` label, through the alias symlink.                                    | `/proc/<pid>` of the browser tree                                                  |
| Both pinned builds (151.0.7922.34 and 156.0.8078.4) load `https://dv-g3b-emudhra.we-have-a-problem.com/` with status 200. Stable 156.0.8078.79 and later reject it under Playwright's default flags.                                                                                                                                    | Navigation through Playwright on each build                                        |
| CfT 151.0.7922.34 predates CVE-2026-85046 (fixed in 152.0.7977.82, 2026-09-03) and CVE-2026-87491 (fixed in 153.0.8010.36, 2026-09-08), both reported exploited. 156.0.8078.4 predates the four Criticals fixed in 156.0.8078.73 and CVE-2026-76024 (156.0.8078.79). 157.0.8103.38 went stable on 2026-11-03 with seven more Criticals. | Chrome Releases                                                                    |
| Playwright 1.64.1 (2026-10-14) is the newest release. Playwright main pins 158.0.8127.2, Chrome's current beta.                                                                                                                                                                                                                         | npm registry; the alpha's `browsers.json`                                          |
| Ubuntu's `apparmor` package ships `/etc/apparmor.d/chrome`, granting `userns` to `/opt/google/chrome/chrome`, loaded on the current boot. Google's deb installs its own equivalent only when Ubuntu's is absent.                                                                                                                        | `dpkg -S`; `/sys/kernel/security/apparmor/policy/profiles/`                        |
| On the current boot `apparmor.service` ran and loaded `/etc/apparmor.d`.                                                                                                                                                                                                                                                                | `systemctl show apparmor.service -p ConditionResult`; journal                      |
| Google's apt index lists one version per channel. On 2026-11-03 amd64 stable was 156.0.8078.79 at 12:14 UTC and 157.0.8103.38 from 21:28 UTC.                                                                                                                                                                                           | `Packages.gz`, `Release`                                                           |
| unattended-upgrades is enabled on the Linux server, its Allowed-Origins cover only Ubuntu's own, and an `Origins-Pattern` drop-in adds an origin without replacing the stock list.                                                                                                                                                      | `/etc/apt/apt.conf.d/50unattended-upgrades`; `/usr/bin/unattended-upgrade:787-797` |
| The Mac runs Chrome 156.0.8078.80 from Google's installer, with Google's user-level updater present. Its gstack is 1.93.42.0, its shared cache holds chromium 1228 and 1234, and its crawl4ai is 0.7.7 on Playwright 1.56.0, below the alias floor.                                                                                     | `ssh`, read-only                                                                   |
| Lighthouse CI cannot find a Chrome on the Linux server: chrome-launcher 0.13.4 raises `ERR_LAUNCHER_PATH_NOT_SET`.                                                                                                                                                                                                                      | `Launcher.getInstallations()`                                                      |
| None of the four e2e suites uses screenshot or snapshot assertions.                                                                                                                                                                                                                                                                     | Search of the suites' specs                                                        |
| GitHub's Ubuntu 24.04 runner image 20261026 ships Google Chrome 156.0.8078.47.                                                                                                                                                                                                                                                          | actions/runner-images                                                              |
| Disk: CfT full 409 MB, headless shell 278 MB, Chrome 453 MB, the Puppeteer cache 929 MB.                                                                                                                                                                                                                                                | `du`                                                                               |

Brett's supplied Playwright security notes check out against these sources: the 156.0.8078.4 pin, the `.73` to `.80`
releases, `chromiumSandbox` defaulting off, and the MCP CVE and its 0.0.40 fix. The Playwright CLI and MCP do default to
Chrome rather than a bundled build. The phrase "Do not use it on the hostile web" was not found in the Playwright pages
read here; Chromium's FAQ states the same thing.

### Consumer Risk

Who opens pages Brett does not control, what they run today, and where each goes.

| Consumer                                                            | Machine                         | Pages it opens                                                      | Browser today                            | Sandbox today                               | Under this plan                                                                                                                           |
| ------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| gstack browse (`/browse`, `/qa`, `/scrape`, handoff, cookie import) | Linux, 1.94.33.0                | Arbitrary URLs, credentialed sessions too                           | CfT 156.0.8078.4                         | On, through the dotfiles AppArmor profile   | System CfT through the launcher's CfT entry, sandbox on, clean environment, CRLSet and Safe Browsing (R6, R9)                             |
| gstack browse, headed                                               | Mac, 1.93.42.0                  | Same; its skill prefers Aside there                                 | CfT 151.0.7922.34                        | On                                          | System CfT through the launcher's CfT entry, side panel works (R6), moving within hours of a stable release (R4)                          |
| crawl4ai CLI and skill scripts                                      | Linux, 0.9.5                    | Arbitrary sites                                                     | CfT 156.0.8078.4                         | Off unless `CRAWL4AI_CHROMIUM_SANDBOX=true` | System CfT through the wrapper, sandbox on, clean environment, certificate checks on for covered callers; no CRLSet or Safe Browsing (R7) |
| crawl4ai CLI                                                        | Mac, 0.7.7 on Playwright 1.56.0 | Arbitrary sites                                                     | None found in the cache for 1.56.0       | Off                                         | Moves to a release at or above 0.9.5, then as Linux, with the same limit (R7)                                                             |
| Agent CLI, new                                                      | Both                            | Arbitrary sites                                                     | Not installed                            | n/a                                         | agent-browser at a pinned version, through the launcher over Chrome (R9, R10)                                                             |
| Ad hoc agent scripts                                                | Both                            | Arbitrary sites                                                     | Default pinned build with `--no-sandbox` | Off                                         | System CfT through the wrapper, sandboxed with a clean environment (R20); the guidance routes untrusted pages to agent-browser (R11)      |
| Puppeteer downloads in `~/.cache/puppeteer`                         | Linux                           | No consumer identified; agent-browser's auto-detect would find them | CfT 133.0.6943.141, 150.0.7871.24        | Unknown                                     | Removed; `PUPPETEER_EXECUTABLE_PATH` names the set and downloads are off (R22, R23)                                                       |
| Codex browser plugin, Cursor `browser-tools-mcp@1.2.0`              | Mac                             | Arbitrary sites                                                     | Mac's Chrome                             | On                                          | Unchanged                                                                                                                                 |
| e2e suites: lmgroktfy, agentnative-site, meum-sites, streamsgrp     | Linux                           | Own builds and own staging                                          | CfT 151 locally; CfT 149 in CI           | Off                                         | System CfT through the wrapper (R5, R20); CI unchanged                                                                                    |
| Lighthouse CI (agentnative-site, meum-sites)                        | Linux                           | Own site                                                            | Cannot launch locally                    | Off by config                               | `CHROME_PATH` names the set (R22)                                                                                                         |

### Key Decisions

- **One physical build, aliased per revision.** The set holds one CfT build, its headless shell, one WebKit, and one
  ffmpeg. The Chromium and ffmpeg revisions a consumer asks for resolve to them. Real suites at 1.61.1 and 1.64.1 passed
  as they do on their pins, and the alias mechanism is already live for 1228. Governs R1, R2, R5, R6, R7.
- **Aliases come from released `browsers.json` files, and WebKit has none.** Every Chromium and ffmpeg revision a
  released Playwright at 1.57 or later names gets an alias, and the hourly job reads the newest release's file every run
  and adds those revisions by a pin-only PR, so a new release is covered within about an hour of publication, ahead of a
  repo the seven-day gate holds back. gstack and crawl4ai, which the gate does not hold, can still meet a release in
  that hour. A repo can only ask for a released revision, so no range of guessed revisions is needed. A WebKit alias in
  either direction fails on `newPage` (measured: 2388 under 1.61.1, 2311 under 1.64.1), so WebKit's pin is the revision
  the pinned library's `browsers.json` names, and a Playwright that names another revision finds no WebKit. Governs R2,
  R4.
- **The version is pinned in the repo, and a job moves it forward only.** Machines run the same dotfiles version, so the
  pin belongs in dotfiles. The job follows the bump pattern in
  `docs/plans/2026-11-02-2155-feat-yazi-plugin-auto-bump-plan.md`, including its squash-merge without a person, because
  the suites are the gate. Hosts read the pin file from `dev` over HTTPS at raw.githubusercontent.com rather than
  through git. The repo is public, so this needs no key, and on the Mac every git-over-SSH call goes through 1Password's
  agent, which an unattended timer cannot count on. Any commit can reach `dev`'s pin (its ruleset has no pull-request
  rule), so a host parses the file as data and refuses a version lower than it has. Governs R4, R24.
- **The bump records a hash.** CfT publishes none, so the bump writes the sha256 of each archive it verified into the
  pin, and hosts check against it. Governs R3, R4.
- **Every browser build is exempt from the seven-day gate.** The gate's threat, a malicious upload to an open registry,
  does not match a vendor-signed repository or Google's own bucket, and the regressions a week of bake time would
  surface are what the suite run catches. Google's apt index serves only the newest build, so holding Chrome back would
  mean mirroring old debs. The exemption covers WebKit too; its revision comes from the pinned library's
  `browsers.json`. WebKit and ffmpeg come from `cdn.playwright.dev`, which signs nothing: their archives are trusted on
  first download and held to the recorded sha256 afterward, and the revision numbers are read from an npm tarball as
  integers, with no install and no script run. agent-browser and the Playwright library are npm packages and stay under
  the gate. Governs R3, R4, R10, R13, R21.
- **Tests and untrusted browsing get separate browsers.** Reproducibility and security pull a browser's update cadence
  in opposite directions. Governs R4, R9, R13.
- **gstack runs on CfT in every session, through the launcher.** The side panel needs `--load-extension`, which CfT
  honors and Chrome blocks (measured), and one browser for gstack keeps one pointer. gstack browse also opens arbitrary
  URLs and credentialed sessions, so it inherits Google's statement about CfT, and the launcher gives it CRLSet and Safe
  Browsing on its headless path, where gstack's own flags would otherwise withhold them. gstack passes nothing else on
  the launcher's list except `--no-sandbox` for root, CI, and containers (read from its source). Governs R6, R9.
- **Two layers of hardening.** The alias wrapper (R20) gives every launch through the set the sandbox and a clean
  environment. The launcher (R9) adds what browsing untrusted pages wants: CRLSet, Safe Browsing, and certificate checks
  that no flag can turn off, over Chrome for agents and over CfT for gstack. Condition 2 stays with the AppArmor deploy.
  Governs R9, R20.
- **Tests stay outside the launcher.** Suites use the alias path: their pages are trusted, and background network
  traffic and component downloads would make runs less hermetic. Governs R5.
- **CLI, not MCP, for agents.** Benchmarked at 1.5 to 5 times less input than MCP for the same job, and an MCP schema
  sits in context for the whole session. Governs R10.
- **Per-agent sessions from the working tree.** agent-browser defaults to one shared browser across agents on a host,
  which would mix tabs and cookies across slots. The shim in R10 derives the session from the working tree, and a slot
  has its own tree. Governs R10.
- **Explicit pointers as well as aliases.** Each consumer that takes a path or a variable gets one, so which browser a
  tool runs is visible in config rather than inferred from a cache layout. The aliases remain for what takes neither: a
  bare `chromium.launch()`, gstack's probes, and crawl4ai's Playwright mode. Governs R22.
- **The install is per host for Chrome, and shared for the set.** The repo deploys to many headless servers that run no
  browser, so the Chrome deploy is opt-in per host. A host without it keeps every consumer on the set, and only
  agent-browser stops, with the launcher's error. Governs R13, R15.
- **The Mac keeps Google's own updater.** Chrome there is outside Homebrew, and the cask declares `auto_updates`.
  Governs R14.
- **Dotfiles adds no AppArmor profile for Chrome and needs no new one for CfT.** Ubuntu's `chrome` profile covers the
  install path, and the existing `chromium-*` glob covers the set when its directories keep that prefix. Governs R3,
  R13.
- **One library version, flagged rather than enforced.** A repo that drifts still runs, because the aliases carry its
  revision, so drift is a report and never a block, and no browser update waits on it. Governs R21.
- **Aliases and wrappers, not per-consumer configuration.** The other shape puts `executablePath` in each repo's
  Playwright config and each tool's own setting, with no aliases. It leaks the browser's path into four repos and three
  tools, cannot reach a bare `chromium.launch()` or gstack's probes, and contradicts "repo's use what's available on the
  system". Aliases hide the revision behind Playwright's own directory lookup, and the wrapper hides the launch policy
  behind one executable. Governs R2, R20.
- **One parser for the pin.** The pin reaches hosts from a branch any commit can change, and its values become download
  URLs, directory names, and package names handed to `bun x` under `sudo`. Every reader goes through one parser that
  accepts only the listed shapes. Governs R25.
- **A directory's name is not its version.** Real directories are numbered from the CfT build and patch so that
  Playwright's cleanup, which parses revisions as integers, can claim them, and that number ignores the Chrome major and
  minor. So each directory's record binds the archive's sha256 and the URL it came from, which carries the full version.
  A relabelled version then fetches from its own URL, and an invented one finds nothing there. Governs R26.
- **A move tests the path production takes.** The launch that gates a move goes through a wrapper rendered for the
  candidate, with the cleared environment and Playwright's default flags. A launch of the raw build with the deploy's
  own environment would pass a build that needs a variable the wrapper clears, such as the `LD_LIBRARY_PATH` that
  `config/shell/local-paths.sh` exports on the Linux server. Governs R27.
- **The running build is read from the wrapper.** The wrapper names the build every launch runs, so it is the one record
  a move cannot lose. Retention reads the previous build from it, and the version floor reads that build's provenance
  record. Governs R24, R27.
- **The launch gate loads a fixture extension.** The property gstack's side panel needs is `--load-extension` on the
  candidate. A minimal extension committed in dotfiles proves it on both machines, whether or not gstack is installed.
  Governs R27.
- **System libraries come before the first launch.** A new host lacks some of Chromium's libraries, and the move's
  launch is the first thing that needs them. Governs R28.
- **Machinery for unattended moves arrives with them.** The version floor, the deploy lock, and download stall limits
  guard moves nobody watches. Phases 1 and 2 deploy only when a person runs the script, so these arrive with each host's
  hourly pickup. Governs R24.

### Requirements

**System browser set**

- R1. Each host that deploys it, the Linux server and the Mac alike, holds exactly one CfT build (full and headless
  shell) plus the previous one until the next move (R27), one WebKit build, and ffmpeg in `$PLAYWRIGHT_BROWSERS_PATH`,
  at versions named once in the pin (R25). WebKit is there for agentnative-site's `mobile-ios`, `tablet`, and
  `web-audit-webkit` projects, and leaves the pin when no repo's suite uses it. On the Mac the WebKit archive is the one
  the registry of the library the pin names (R25) selects for that macOS release, and a Mac older than the pin's WebKit
  supports is refused before anything downloads. `scripts/playwright-deps-deploy.sh` deploys the set on the Mac as on
  Linux and skips only the Linux-only steps.
- R2. Every Chromium and ffmpeg revision named by `browsers.json` of a Playwright release at 1.57 or later resolves to
  the set through an alias, whether that release's pin is older or newer than the set's build. WebKit has no alias: its
  one revision is the one the pinned library names. The list of revisions lives in the pin, and R4's job adds a new
  release's. Each alias directory carries the install markers.
- R3. `playwright install` naming browsers in the set, from any consumer at Playwright 1.57 or later, is a no-op and
  deletes nothing. A deploy replaces a real directory found at an alias name, which `--force` installs create, with the
  alias. `--check` fails with a stable reason on such a directory and on any browser directory the pin does not name and
  no deploy or job has recorded under `$PLAYWRIGHT_BROWSERS_PATH/.dotfiles/`, such as the `firefox-*` a bare
  `playwright install` downloads or what a consumer below the floor installs. The set survives a consumer's cleanup
  through one `.links` client per aliased revision and per recorded directory, numeric names on its real directories
  (cleanup parses revisions as integers), and `PLAYWRIGHT_SKIP_BROWSER_GC` as a second layer. Provisioning verifies each
  archive against its recorded sha256, downloads only from hosts fixed in the script (Google's bucket for CfT, and
  `https://cdn.playwright.dev/builds/<browser>/<revision>/` for WebKit and ffmpeg, which serves the archive itself where
  Playwright's `/dbazure/` path redirects to another host, measured 2026-11-05), follows no redirect, and keeps the
  `curl` plus `unzip` path, because node's extractor deadlocks on this kernel.
  - **Clients are never half-written.** Playwright's cleanup reads an empty or partial client as broken and deletes
    every directory no working client names, which while a deploy rewrites the wrapper directory's client is every
    alias's target. A deploy leaves a client alone when its content is already right, and otherwise writes the new file
    outside `.links` and renames it into place, `browsers.json` before the link.
  - **Every deploy registers the whole set again,** the previous build and every recorded directory included, so a
    `.links` emptied by another tool's `uninstall` is whole after the next deploy with the same pin.
  - **A deploy deletes only what it can show it made:** a `.links` entry only when it points at one of the client shapes
    the deploy writes, with no `..`; a symlink at a browser-directory name only when it points into the set; and a real
    directory only when it carries the deploy's provenance record (R26), or when it sits at a set or alias name, where
    the deploy replaces it with the set's directory or alias. Anything else stays for `--check` to name.
- R4. dotfiles moves the set forward on its own schedule with no repo involved, exempt from the seven-day gate. An
  hourly user timer on the Linux server reads CfT's Stable channel and the newest Playwright release's `browsers.json`,
  and exits after those two small fetches when neither names anything the pin lacks. On a higher CfT version it
  provisions the candidate pin's builds, the CfT full and headless builds with the ffmpeg revision the newest release
  names and the WebKit revision the pinned library names, as numeric directories under `$PLAYWRIGHT_BROWSERS_PATH`, the
  only paths the AppArmor profile covers, each with a `.links` client and recorded as the job's candidate, and removes
  them if the candidate fails. It holds R24's deploy lock while its candidate is on disk, so no host move removes the
  candidate mid-run. It runs both arms through lmgroktfy, meum-sites, agentnative-site, and gstack's browse tests, about
  11 minutes in all (measured per suite), launching through R20's wrapper from a scratch browsers path, so
  agentnative-site's WebKit projects gate a WebKit move as the Chromium projects gate a CfT move.
  - **Each arm** runs in a child with its environment cleared to R9's allowlist plus what the suite names, with no
    `GH_TOKEN`, `SSH_AUTH_SOCK`, or values from `~/.secrets`, and installs from the frozen lockfile. It runs under
    `timeout -s INT -k 30`, because a default `timeout` leaves a suite's `webServer` running (measured). A suite's port
    held before or after an arm fails that arm, because `reuseExistingServer` would otherwise test a leftover server.
  - **The gate:** the pin moves only when both arms produce a per-test report for every suite, with a test count at or
    above the current arm's, and the set of passing tests does not shrink. A test failing only on the candidate is rerun
    once. A test that passes on the current arm and fails twice on the candidate holds that version back, named with its
    suite, and the job then moves only to a newer release. An arm that ends without its reports (a held port, an install
    or fetch failure, the time limit) holds nothing: the next hourly run tries the same version again. The job also
    loads an extension on the candidate, so a dropped `--load-extension` stops the move.
  - **New revisions:** The ffmpeg revision and new alias revisions come from `browsers.json` of the newest Playwright
    release, read from its npm tarball with no install and no script run, and accepted only as integers. When that file
    names Chromium or ffmpeg revisions the pin lacks and CfT has not moved, the job opens the same pin-only PR adding
    those aliases alone, with no suite run, because an alias adds no bytes. The WebKit revision comes from the pinned
    library's `browsers.json` and moves only when the library version does.
  - **A rollback holds.** When a person lowers the pin on `dev` below a version the job merged, the job records each
    version above the new pin as held, as it records a gate failure, and moves only to a release newer than all of them.
  - **The job's alarm.** On the Linux server, a check fails when the pin trails CfT Stable by more than a day. A held
    version changes the stable reason to one naming the suite, or the rollback, and the version held; the check still
    fails, because a candidate failing a suite that passes on the current build is one of the Goal Capsule's stop
    conditions and has to reach Brett.
  - **The move** is a PR to `dev` that squash-merges itself once CI is green, from the parent process, pinned to the
    head commit, and only when the diff touches nothing but the pin file. A bats case in CI validates the pin's shape.
- R24. Each host runs an hourly timer (a LaunchAgent on the Mac) that reads the pin file from `dev` over HTTPS at
  raw.githubusercontent.com, parses it with R25's parser, and deploys what differs through R27's move.
  - **The version floor.** A host refuses a CfT version lower than the build its wrappers run, read from that build's
    provenance record (R26), leaving the set alone and naming a stable reason and both values; a person moves a host
    back with `--allow-downgrade`. Because the floor comes from the running build, a lost or damaged record of the
    deployed version neither lowers it nor stops the host, and a version relabelled onto an older build fetches from its
    own URL and fails before anything moves.
  - **One deploy at a time.** Deploys never overlap, through a lock the kernel releases when its holder exits, never a
    pid file, which two contenders can both take: `flock(1)` from util-linux on Linux. macOS ships no `flock(1)`, so
    phase 8 names the Mac's lock tool after checking it on the Mac (Open Question 11), and the deploy stops with a
    stable reason when the tool is missing. A cache the deploy cannot write fails with its own reason, not as a held
    lock, so a caller branching on the reason does not retry forever.
  - **Where it runs.** The units ship in shared packages that reach hosts with no browser set, so the timer and the
    LaunchAgent do nothing on a host whose set the deploy has not recorded, and the deploy enables them on its first
    successful run, which is what opts a host in.
  - **Bounded downloads.** Every download has a connect timeout and a stall limit, so an unattended run ends.
  - **The version ceiling.** A host also refuses a CfT version above CfT's current Stable version, read as R4's job
    reads it, with its own stable reason, so a Beta build copied into the pin neither deploys nor raises the floor.
  - **Which pin a host checks.** The pickup records the pin it deployed under `$PLAYWRIGHT_BROWSERS_PATH/.dotfiles/`.
    Once that record exists, `--check` and a run with no `--pin` compare against it, and a checkout pin older than it is
    a note naming `git -C ~/dotfiles pull`, not a failure, because nothing pulls the checkout when the pickup moves the
    set.
  - **The staleness check.** A check that changes nothing fails when a host's set differs from the pin for more than two
    cycles, names the fix command, and carries a stable reason and the values it compared.
- R20. Every alias's Chromium executable is a small wrapper, in two numeric directories the aliases point at,
  `chromium-999999` for the full build and `chromium_headless_shell-999999` for the headless shell, that drops only
  `--no-sandbox` and `--disable-setuid-sandbox`, keeps them when running as root, clears the environment as R9 does, and
  `exec`s the real build at its AppArmor-covered path. The same wrapper is reachable at one path that does not move with
  the pin, under `$PLAYWRIGHT_BROWSERS_PATH/.dotfiles/`, which the cleanup never counts as a browser directory, for
  consumers that take an explicit path. `--check` fails, naming which, when the AppArmor profile is not loaded or when
  `$PLAYWRIGHT_BROWSERS_PATH` lies outside the paths it covers (`/home/*/.cache/playwright/`), because every launch
  through the wrapper then fails with `No usable sandbox!`. It also fails when a wrapper differs from its template or
  names a build other than the pin's. ffmpeg aliases point at their real directory, WebKit is a real directory, and the
  docs say the wrapper covers Chromium only. On Linux with `kernel.apparmor_restrict_unprivileged_userns = 1`, the
  wrapper checks that a `playwright-chromium` profile is listed under `/sys/kernel/security/apparmor/policy/profiles/`,
  which any user can read (measured), before it `exec`s. Without one it exits with its own line naming
  `sudo ~/dotfiles/scripts/apparmor-deploy.sh`, because the browser's own failure text suggests `--no-sandbox`. The
  check is a glob in the shell, with no subprocess.
- R25. The pin is one file, `config/playwright/browsers.pin`, holding the CfT version, the WebKit and ffmpeg revisions,
  the Chromium and ffmpeg alias lists, the Playwright library version, whose `browsers.json` names the WebKit revision,
  with the sha256 of its npm tarball, the newest Playwright release, whose `browsers.json` names the ffmpeg revision and
  bounds the alias lists, with the sha256 of its tarball, and a sha256 for each archive on each platform. One parser
  reads it for every reader: the deploy, the deps script, the bump job, each host's pickup, and the library check. It
  never runs the file through `source` or `eval` and never picks a field with `sed`. It accepts only dotted-numeric
  versions, integer revisions, 64-hex hashes, and archive names the script knows, and stops with a stable reason on
  anything else, showing the offending value with every character outside letters, digits, `.`, `_`, `-`, and space
  masked, so a value cannot forge the reason or the next step on the line that reports it. Download hosts come from the
  script, never from the pin.
- R26. Each real directory the deploy provisions carries a record of the archive's sha256 and the URL it came from. A
  directory counts as provisioned only when its executable is present and its record matches the hash the pin names and
  the URL the pin's version gives. A changed version always fetches from its own URL, and a directory whose executable
  is gone is fetched again rather than reported healthy.
- R27. A move puts a new or rebuilt CfT build behind the wrappers only after it launches on the path production takes.
  - **The launch.** The deploy renders the candidate's wrappers in its stage and launches through them twice with
    Playwright at the pin's library version, sandbox on, within a time limit: once as Playwright's default headless
    launch through the headless-shell wrapper, loading a page, and once through the full build's wrapper, loading a page
    and a fixture extension committed in dotfiles, which the headless shell cannot load. The flip waits for both. That
    library comes from its npm tarball, held to the pin's sha256 and unpacked with no install script run. The launches'
    output goes to stderr.
  - **An owed launch is never forgotten.** The record that a launch is owed is written before the new bytes reach their
    directory and cleared only by a passing launch. A failed or killed run therefore leaves `--check` failing with a
    stable reason and the next run launching again, never reporting OK over a build that has not started.
  - **The flip.** A passing launch flips the set by renaming each wrapper over its predecessor.
  - **Retention.** The build the wrapper named before the flip stays on disk and registered until the next move, read
    from the wrapper itself, so a missing record never removes the running build. After a passing move the deploy
    removes each CfT build that carries its provenance record and is neither the current nor the previous build, such as
    a failed candidate.
- R28. On Linux, `scripts/playwright-deps-deploy.sh` deploys the AppArmor profile, then for `--chromium`, `--webkit`, or
  `--all` installs the system libraries through `install-deps` from the `playwright-core` tarball of the library version
  the pin names (R25), held to its sha256 and run as the invoking user, so only Playwright's own `sudo apt-get` step
  runs as root and no `bun x` runs at all. That is the release whose WebKit the set carries, so its library list matches
  the WebKit build. Only then does it deploy the set, so the move's launch on a new host has what it needs. It never
  downloads a browser.
- R29. Tests hold the set to real behavior.
  - (a) A case that fetches pinned bytes fails on an HTTP error or a hash mismatch, and skips only when the host cannot
    reach the registry at all, saying so. A wrong library version or hash in the pin fails CI.
  - (b) The cleanup cases run a real `playwright-core` at the pin's library version, fetched by its hash, on pre-push
    and in CI, with the bats setup action caching it. No case relies only on a re-implementation of Playwright's
    cleanup.
  - (c) The move's launch script runs under real node against a fake `playwright-core` that records the options it
    receives, so dropping the sandbox option or the extension check fails a test.
  - (d) A test that starts a real browser through the wrapper closes it itself, because the wrapper clears the
    environment markers the leak guards look for. It runs only where the AppArmor profile covers its browser's path and
    skips elsewhere with that reason, because a browser under a test's temporary directory cannot start sandboxed on the
    Linux server, and CI loads no profile.
- R30. Every script in the set writes diagnostics to stderr with a severity prefix and only its result to stdout. Every
  failure carries a stable reason from a closed set, the offending value masked as R25 states, and a `next:` command
  that runs verbatim from a headless shell: paths quoted with `printf %q`, and any condition in the message rather than
  the command. A next step never discards work: the error for a missing `--pin` path names that path, not a checkout of
  the committed pin. `--help` text is taken from the script's header by pattern, not by line numbers.
  - **Exit codes and side effects.** A usage error exits 2 before any work; every other failure exits 1. Each failure
    says what it changed, such as "nothing moved; the set stays on 157.0.8103.38", so a caller knows whether a rerun is
    safe.
  - **Where reasons are documented.** Each reason has a row in the runbook's reason table, which is its doc anchor.
  - **Unexpected failures.** When `curl`, `unzip`, or `node` fails in a way the script did not anticipate, the tool's
    own stderr passes through above the reason line, which names the rerun.
  - **Commands outside the repo.** A `next:` that a consumer reads from another repository, the wrapper's or the
    launcher's, names the script as `~/dotfiles/scripts/...`, the checkout's path on both machines (AGENTS.md). A step
    that needs `sudo` says to ask the operator to run it.

**Consumers**

- R5. Each e2e suite runs locally on the set with no change to its Playwright config. CI is unchanged: each repo's
  workflow runs `playwright install` for its own pinned build.
- R6. gstack, headless and headed, runs on CfT. Its install probes resolve through the alias. `GSTACK_CHROMIUM_PATH`
  points its launches at the launcher's CfT entry (R9), exported only when that entry and the set's stable path (R20)
  are executable and the user is not root, because gstack throws on a failed launch and the launcher refuses root. Its
  headless path gets CRLSet and Safe Browsing this way, and its headed sessions load the side panel. gstack keeps the
  Playwright version it ships.
- R7. crawl4ai runs on CfT and keeps the Playwright version it ships. Its Playwright mode resolves through the alias,
  and the deploy writes `~/.crawl4ai/chromium.path` to the stable path for its managed mode.
  `CRAWL4AI_CHROMIUM_SANDBOX=true` is exported wherever the sandbox can work. Covered callers set `ignore_https_errors`
  off. crawl4ai meets hardened conditions 1, 2, 5, and 6 and not 3 or 4: its Playwright mode adds
  `--disable-component-update` itself and takes no executable path, so only the wrapper runs for it, and a short crawl
  would outrun a CRLSet regardless.
- R8. No launch through the set passes `--no-sandbox` (R20), and no consumer dotfiles configures does, on either
  machine, outside a context where the sandbox cannot work (root, a container, CI). A launch with Playwright's
  `channel: 'chrome'` goes straight to `/opt/google/chrome/chrome`, past both the wrapper and the launcher, on any host
  where Chrome is installed, and Playwright has no setting that redirects it; R11's guidance routes such a script to the
  launcher's Chrome entry through `executablePath`.

**Agent browsing**

- R9. A dotfiles-owned launcher on PATH drops `--no-sandbox`, `--disable-setuid-sandbox`, `--disable-component-update`,
  `--disable-background-networking`, and every `--ignore-certificate-errors*` form. It also drops the sibling switches:
  `--disable-seccomp-filter-sandbox` (measured: it turns renderer seccomp off), `--disable-namespace-sandbox`,
  `--disable-gpu-sandbox`, `--no-zygote`, `--no-zygote-sandbox`, `--single-process`, `--in-process-gpu`,
  `--disable-web-security`, `--disable-site-isolation-trials`, `--allow-running-insecure-content`,
  `--allow-insecure-localhost`, and `--renderer-cmd-prefix`, `--gpu-launcher`, `--utility-cmd-prefix`, and
  `--browser-subprocess-path`. It matches on the normalized switch name, so `-no-sandbox` and `--no-sandbox=1` count. It
  adds `--component-updater=fast-update`, clears the environment down to what a browser needs (`HOME`, `PATH`, `TMPDIR`,
  `LANG`, `LC_*`, `TZ`, `DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, and proxy variables),
  then `exec`s its target, so the browser keeps the caller's pipes and AppArmor's path match. It refuses to run as root,
  naming why, because the browser's sandbox cannot start there. It has two entries, because a caller's path setting can
  name only an executable: the default targets Chrome, for agent-browser and the guidance, and a CfT entry targets the
  set's stable path (R20), for gstack. It reads each target's path from a variable that shell config exports only when
  the binary exists, and it holds no path of its own. When its target is absent it exits before opening a page with one
  self-contained line, last on stderr, that says what is missing, carries a stable reason, and names the deploy command
  (`~/dotfiles/scripts/chrome-deploy.sh` for Chrome, which it says to ask the operator to run with `sudo`, and
  `~/dotfiles/scripts/playwright-browsers-deploy.sh` for CfT, as R30 states), because some callers keep only the last
  line. The launcher's environment allowlist and the wrapper's (R20) are the same list, and the wrapper's two switches
  are on the launcher's list; one bats case fails when the two scripts disagree, because each file is edited without the
  other in view.
- R10. A stowed shim named `agent-browser` runs agent-browser at one exact version the seven-day gate allows (0.40.0 on
  2026-11-03), named once in dotfiles, with no skill. It unsets every inherited `AGENT_BROWSER_*` variable it does not
  set itself. It always sets `AGENT_BROWSER_EXECUTABLE_PATH` to the launcher, so the tool's auto-detect never runs and a
  host without Chrome gets the launcher's error, and `AGENT_BROWSER_CONFIG` to a dotfiles-owned file, which makes the
  tool skip a project's `agent-browser.json` (measured). In any argument position, and in `--flag=value` form, it
  refuses with one line saying why: `--ignore-https-errors`, `--executable-path`, `--config`, `--ca-cert`, `--cdp`,
  `--auto-connect`, `--engine`, `-p` or `--provider`, `--profile`, `--extension`, `--allow-file-access`, and `--args`,
  and the verbs `install`, `upgrade`, `doctor --fix`, `plugin add`, and `mcp`. This stops accidents and planted config,
  not an agent that runs the binary directly. The shim turns content boundaries on (`AGENT_BROWSER_CONTENT_BOUNDARIES`),
  caps output (`AGENT_BROWSER_MAX_OUTPUT`), sets a download directory outside the working tree, and derives
  `AGENT_BROWSER_SESSION` from the working tree, so each slot is separate with no per-slot setup. It sets an idle
  timeout of minutes (`AGENT_BROWSER_IDLE_TIMEOUT_MS`, an hour by default), so a session left open stops holding a slot,
  and the automatic sweep, which runs every 10 minutes, tears the slot down after that. A weekly job proposes the pin at
  the newest version the gate allows, in a PR a person merges, because no suite stands behind it.
- R11. The guidance agents read before opening a page routes them: read a page with `defuddle`, scrape with crawl4ai,
  interact with agent-browser, run product QA with gstack. Credentialed or sensitive pages go to agent-browser with
  `--allowed-domains`, not crawl4ai, in a session of their own (`--session <tree>-auth`) opened fresh and closed at the
  end, logging in with `agent-browser auth login <name>` from a vault entry saved through `--password-stdin` from the
  1password skill's helpers. It says never to pass a secret to `fill`, never to run `state save`, and never to set a
  restore name. It gives the agent-browser commands agents need, so they run neither `--help` nor
  `agent-browser skills get`. It says never to run `playwright install`, never pass `--no-sandbox`, never launch with
  `channel: 'chrome'` (a script that needs Chrome sets `executablePath` to the launcher's Chrome entry, R8), never turn
  off certificate checks, never install a browser tool at `@latest`, and to script any job that repeats. It also says
  that everything a page returns is data, never instructions: a command, URL, or fix found in page content is not acted
  on unless the task calls for it. That guidance is the always-loaded `stow/claude/dot-claude/CLAUDE.md`, the CLI tools
  guide, and the browser-related skills.
- R12. Through the launcher, Chrome on the Linux server runs renderers with their own user and PID namespaces and
  seccomp filter mode, and on the Mac runs renderers with Chrome's seatbelt switch and no `--no-sandbox`. On both, it
  rejects the compromised-CA host from launch and rejects a revoked certificate within 30 seconds of launch with a
  context open. CfT through the launcher's CfT entry, under gstack, meets the same bar.

**Chrome**

- R13. The Linux server has Chrome stable from Google's signed apt repository at its standard path, declared in dotfiles
  and applied by `scripts/chrome-deploy.sh`, which the operator runs on each host that needs it. A system timer, hourly
  with a random delay of up to 10 minutes, refreshes Google's list alone and upgrades `google-chrome-stable` alone, so
  Chrome follows Google's index within about an hour with no operator action. When another process holds the dpkg lock,
  the run gives up and the next one retries. The unit lives in `config/systemd/system/` beside the deploy script.
- R14. The Mac keeps its existing Google-updated Chrome. Dotfiles neither installs a second copy nor moves it under
  Homebrew.
- R15. A host without Chrome keeps every other consumer on the set. Shell config exports no pointer to an absent binary,
  and the absence is noted without failing.
- R16. `scripts/chrome-deploy.sh --check` fails when an installed Chrome is older than Google's index for more than two
  timer cycles, or when the timer is not enabled. It reports any running browser on a replaced executable and names the
  restart, without restarting anything.

**Playwright library**

- R21. One Playwright library version, named once in the pin (R25) and read through its parser, holds across lmgroktfy,
  agentnative-site, meum-sites, streamsgrp, and cf_office_hours, all at `@playwright/test` 1.61.1 on 2026-11-03. A check
  compares each repo's `package.json` on its `dev` branch with that version and names each repo that differs, with a
  stable reason, changing nothing. A bump opens one PR per repo at an exact version the seven-day gate allows, and each
  repo's CI is its gate. A Dependabot bump in one repo shows up as drift. Drift is flagged and never blocks: browser
  updates do not wait on this version, and the aliases carry any revision a repo's library asks for. gstack and crawl4ai
  keep the versions they ship. emdash is third-party and outside this.

**Control**

- R22. Every consumer is pointed explicitly, and every download is off, on each host that deploys the set. Shell config
  exports `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, `PLAYWRIGHT_SKIP_BROWSER_GC=1`,
  `PUPPETEER_SKIP_DOWNLOAD=1`, `PUPPETEER_EXECUTABLE_PATH`, `CHROME_PATH`, `GSTACK_CHROMIUM_PATH`, and
  `CRAWL4AI_CHROMIUM_SANDBOX=true`. The deploy writes `~/.crawl4ai/chromium.path`. The shim sets
  `AGENT_BROWSER_EXECUTABLE_PATH`. The pointers name the set's stable path (R20), except agent-browser's, which names
  the launcher, and gstack's, which names the launcher's CfT entry.
- R23. A check lists every browser binary on a host outside Chrome and the set, with its path, version, and size, under
  a stable reason, and exits non-zero when it finds one: `~/.cache/puppeteer`, `~/.cache/ms-playwright`, agent-browser's
  own download directory, distribution Chromium packages, and their Mac equivalents. Directories inside
  `$PLAYWRIGHT_BROWSERS_PATH` are `--check`'s (R3), so this check never reads the pin. It removes nothing (decision 14).
  A list in dotfiles exempts what is not a browser consumer, such as Electron apps and the GStack Browser app, each with
  a reason.

**Docs**

- R19. The always-loaded `CLAUDE.md`, the Playwright runbook, the CLI tools guide, the supply-chain guide, and the
  solutions docs on Playwright launch describe the set, the launcher, Chrome, the pointers, and the gate exemption as
  they are, and state the boot-time AppArmor behavior as measured. The CLI tools guide's rule that repos exact-pin one
  version stays, and names the dotfiles file and the check in R21.

### Acceptance Examples

- AE1. **Covers R2, R5.** **Given** the set is deployed at any CfT version, **when** lmgroktfy, meum-sites, and
  agentnative-site run their suites from a checkout with no local changes, **then** they pass as they do on the previous
  build and no file under `$PLAYWRIGHT_BROWSERS_PATH` changes.
- AE2. **Covers R1, R6.** **Given** the set is deployed on the Mac and `GSTACK_CHROMIUM_PATH` is exported, **when**
  gstack's headed session opens, **then** the side panel loads, and a suite passes there.
- AE3. **Covers R2, R21.** **Given** a repo moves `@playwright/test` to a release the hourly job has read, newer than
  the set's last deploy, **when** its Chromium projects run, **then** they run on the set, ffmpeg included, with no
  change by a person and no download, and the check in R21 names that repo. **When** its WebKit projects run on a
  Playwright whose `browsers.json` names a WebKit revision other than the pin's, **then** they fail with
  `Executable doesn't exist`, and not with a protocol error midway through a run.
- AE4. **Covers R3.** **Given** another tool at Playwright 1.57 or later runs `playwright install chromium`, **when** it
  finishes, **then** the set is intact and nothing downloaded, no `ffmpeg-*` included. **Given** a tool below that floor
  installs, **then** the set is intact and `--check` names the directory it downloaded. **Given** a `--force` install
  replaced an alias with a real directory, **when** the next deploy runs, **then** the alias is back, and until then
  `--check` fails naming the directory. **Given** an archive whose hash differs from the pin, **when** provisioning
  runs, **then** it stops, names both hashes, and leaves the existing set in place.
- AE5. **Covers R4.** **Given** a candidate CfT build that fails a test a current run passes, or a suite that produces
  no per-test report, **when** the job runs, **then** the pin does not move and the job names the suite. A version held
  by a failing test waits for a newer release; a run with a missing report tries the same version at the next hourly
  run. **Given** a candidate-only failure that passes on rerun, **then** the move proceeds. **Given** CfT Stable is not
  higher than the pin and the newest Playwright release names nothing the pin lacks, **when** the hourly timer fires,
  **then** it exits after two small fetches and runs no suite. **Given** a suite's port is held when an arm starts,
  **then** that arm fails naming the holder. **Given** an arm hits its time limit, **then** no `webServer` process
  survives it.
- AE6. **Covers R6.** **Given** the set is deployed, **when** `gstack-browser-ensure` runs, **then** it prints
  `BROWSER_OK` with the set's version and fetches nothing.
- AE7. **Covers R7, R8.** **Given** crawl4ai under the shell's defaults, **when** it crawls a page, **then** its
  browser's command line carries no `--no-sandbox` and a token planted in the caller's environment is absent from the
  browser's. **When** a covered caller crawls `https://expired.badssl.com/`, **then** the crawl fails with a certificate
  error. **When** it crawls `https://revoked.badssl.com/`, **then** the result is recorded as this path's known limit.
- AE8. **Covers R9, R12.** **Given** the launcher and Chrome are installed on either machine, **when** a Playwright
  launch sets its executable to the launcher, **then** renderers are sandboxed as R12 states, including when it passes
  `--disable-seccomp-filter-sandbox`, `dv-g3b-emudhra.we-have-a-problem.com` fails at once, `revoked.badssl.com` fails
  within 30 seconds, and a token planted in the caller's environment is absent from the browser's main process's
  `/proc/<pid>/environ` on Linux.
- AE9. **Covers R9, R10.** **Given** a host without Chrome, **when** an agent runs `agent-browser open <url>`, **then**
  it exits before opening any page, names the deploy command, and never suggests `agent-browser install`.
- AE10. **Covers R10, R11.** **Given** two agents on one host, **when** each opens a page through agent-browser,
  **then** neither sees the other's tabs, neither working tree gains a file, and page output carries boundary markers.
  **Given** a login through `auth login`, **then** no file in the working tree or `~/.agent-browser/sessions/` holds the
  token.
- AE11. **Covers R13, R16.** **Given** Google publishes a new stable build, **when** the host's next timer run
  completes, **then** the installed version matches it. **Given** the timer is disabled, **when** the check runs after a
  newer build has been in the index for two cycles, **then** it exits non-zero with a stable reason, the versions it
  compared, and the deploy command.
- AE12. **Covers R16.** **Given** an agent-browser daemon started before the timer replaced Chrome, **when** the check
  runs, **then** it names that process and the restart command.
- AE13. **Covers R10.** **Given** a slot's agent used agent-browser and left its session open, **when** the idle timeout
  has passed, **then** `agent-slot check` reports no `agent-state-unknown` blocker from the tool's daemon, and the next
  sweep tears the slot down.
- AE14. **Covers R20.** **Given** the set is deployed, **when** a script calls bare `chromium.launch()`, **then** the
  browser process carries no `--no-sandbox`, renderers are sandboxed, and a planted token is absent from its
  environment.
- AE15. **Covers R10.** **Given** the shim, **when** an agent runs `agent-browser install`, `agent-browser upgrade`,
  `agent-browser doctor --fix`, or passes `--ignore-https-errors` or `--executable-path`, **then** it refuses with one
  line and downloads nothing. **Given** a working tree holding `agent-browser.json` with `ignoreHttpsErrors: true`, or
  an inherited `AGENT_BROWSER_IGNORE_HTTPS_ERRORS=1`, **then** `https://expired.badssl.com/` still fails.
- AE16. **Covers R21.** **Given** one repo's `package.json` differs from the dotfiles version, **when** the check runs,
  **then** it exits non-zero naming that repo and both versions, and no browser update is held back.
- AE17. **Covers R22, R23.** **Given** a tool downloaded a browser into `~/.cache/puppeteer`, **when** the check runs,
  **then** it exits non-zero listing the path, version, and size, and removes nothing. **Given** a healthy set the day
  after a move, **then** the previous build fails neither `--check` nor this check.
- AE18. **Covers R24, R25.** **Given** the pin file on `dev` names a version lower than the build a host's wrappers run,
  or holds anything but the accepted shapes, **when** the host's timer runs, **then** the wrappers stay, nothing
  downloads, and the check names a stable reason and both values. **Given** `--allow-downgrade`, **then** the deploy
  moves the host back. **Given** the record of the deployed version is missing, **then** the floor is the same.
- AE19. **Covers R6, R9, R12.** **Given** `GSTACK_CHROMIUM_PATH` names the launcher's CfT entry, **when** gstack browse
  opens `revoked.badssl.com` with its session open for 30 seconds, on either machine, **then** the navigation fails with
  `ERR_CERT_REVOKED`, renderers are sandboxed as R12 states, and a token planted in gstack's environment is absent from
  the browser's main process on Linux. **Given** a headed session on the Mac, **then** the side panel loads.
- AE20. **Covers R26, R24.** **Given** a host deployed at CfT A and then B, **when** the pin names A's build and patch
  under a higher major with A's hashes, **then** the deploy fetches from that version's own URL, stops before anything
  moves, and the set stays on B. Under phase 8 the host's floor also stays at B.
- AE21. **Covers R27.** **Given** a rebuilt CfT build whose launch fails, or a run killed between the new bytes' arrival
  and the launch, **when** `--check` runs, **then** it fails with a stable reason, and a plain rerun launches again
  rather than printing OK.
- AE22. **Covers R29.** **Given** a pin naming a library version that does not exist or a wrong sha256, **when** the
  suite runs with the registry reachable, **then** the cases that fetch it fail. **Given** no route to the registry,
  **then** they skip and say why.
- AE23. **Covers R25, R28.** **Given** a pin whose library field holds anything but a dotted-numeric version and 64 hex
  characters, such as `npm:other@1`, **when** `scripts/playwright-deps-deploy.sh --chromium` runs, **then** it stops
  with the pin's stable reason before any `sudo` or `bun x` runs, and the value it shows is masked.
- AE24. **Covers R27.** **Given** a host whose record of deployed builds is missing, **when** a deploy moves the set,
  **then** the build the wrapper ran before the move stays on disk and registered as the previous build.
- AE25. **Covers R3.** **Given** a deploy that changes nothing, **when** a real `playwright uninstall` runs during it,
  **then** no set directory, alias, or wrapper is deleted, and every client file keeps its content and modification
  time.
- AE26. **Covers R3.** **Given** a `.links/dotfiles-*` entry naming a path with `..` or the deploy's own record files,
  or a symlink at a browser-directory name that points outside the set, **when** a deploy runs, **then** each target
  survives, and `--check` names the symlink.
- AE27. **Covers R26.** **Given** a set directory whose executable is gone and whose markers remain, **when** the deploy
  runs, **then** it fetches that directory again, and `--check` passes.
- AE28. **Covers R27.** **Given** a candidate whose launch failed, **when** a later move passes, **then** the failed
  candidate's directories are gone and `--check` passes. **Given** a browser directory without the deploy's record,
  **then** it stays for `--check` to name.
- AE29. **Covers R3.** **Given** `.links` emptied on a host that keeps a previous or retained build, **when** the deploy
  reruns with the same pin, **then** every set directory and kept build is registered again and `--check` passes.
- AE30. **Covers R24.** **Given** two deploys started together, **when** both run, **then** one deploys and the other
  exits with a stable reason saying a deploy is in progress. **Given** a cache directory the deploy cannot write,
  **then** it exits with a reason of its own, not that one.
- AE31. **Covers R28.** **Given** a Linux host missing Chromium's system libraries, **when**
  `scripts/playwright-deps-deploy.sh --chromium` runs, **then** the libraries are installed before the move's launch,
  and the run ends with the set deployed and no browser downloaded by Playwright.
- AE32. **Covers R1.** **Given** an Apple silicon Mac, **when** the deploy runs, **then** it fetches the WebKit archive
  the pinned library's registry selects for that macOS release (the macOS 15 build on macOS 15 and later), and **given**
  a release the pin's WebKit does not support, it stops naming the release required, before anything downloads.
- AE33. **Covers R4.** **Given** a candidate held by a test that passes on the current build, **when** a day passes with
  CfT Stable above the pin, **then** the job's check exits non-zero naming the suite and the held version.
- AE34. **Covers R4.** **Given** a person lowered the pin on `dev` below a version the job merged, **when** the next
  hourly run sees that version as Stable, **then** it opens no PR, and it moves only to a newer release.
- AE35. **Covers R24.** **Given** the pin on `dev` names a CfT version above CfT's current Stable, **when** a host's
  timer runs, **then** nothing downloads, the floor stays, and the check names the ceiling's reason and both versions.
- AE36. **Covers R4, R2.** **Given** a new Playwright release names a Chromium revision the pin lacks and CfT has not
  moved, **when** the hourly run reads it, **then** a pin-only PR adds that alias with no suite run, and a consumer at
  that release runs on the set once hosts pick it up.
- AE37. **Covers R24.** **Given** the pickup moved a host past the checkout's pin, **when** `--check` runs there,
  **then** it passes against the deployed pin and notes `git -C ~/dotfiles pull`.

### What Happens to the Pinned-Browser Machinery

| Item                                                                                                                | Today                                                   | Under this plan                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/playwright-browsers-deploy.sh`                                                                             | A revision map per Playwright version                   | One pin read by one parser (R25); no per-version map (phase 1)                                                                                                                                           |
| `CONSUMER_CHROMIUM_REVS`                                                                                            | Hand-kept list, 1223 and 1228                           | Replaced by the pin's alias lists, which the job extends (phases 1 and 9)                                                                                                                                |
| PR #431's `.links` registration and `--check`                                                                       | Registers the whole set                                 | Kept and extended to every alias and kept directory (phase 1); `--check` grows into R24's check (phase 8)                                                                                                |
| gstack's own `playwright install chromium`                                                                          | Fetches 1248 when its probe fails                       | Never fires: its probe passes on the alias (phase 1)                                                                                                                                                     |
| `chromium-1234`, `chromium-1248`, their headless shells, `webkit-2311`, `webkit-2336`, `ffmpeg-1011`, `ffmpeg-1013` | Real directories with no provenance record              | Replaced by the set's verified builds and aliases at the first deploy (R3, phase 1)                                                                                                                      |
| `~/.cache/puppeteer`                                                                                                | 929 MB; CfT 133 and 150; no consumer identified         | Removed, with `PUPPETEER_EXECUTABLE_PATH` and `PUPPETEER_SKIP_DOWNLOAD` set (R22, R23; phases 4 and 5)                                                                                                   |
| `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`                                                      | One shared cache; no auto-download on `bun install`     | Both stay; `PLAYWRIGHT_SKIP_BROWSER_GC` and the other pointers join them (R22, phase 4)                                                                                                                  |
| `config/apparmor.d/playwright`, `apparmor-playwright.service`                                                       | Grant `userns` to `chromium-*` and the headless shell   | Stay: the glob covers the set's directories and aliases, and every launch through the wrapper depends on them (phase 2)                                                                                  |
| `scripts/playwright-deps-deploy.sh`                                                                                 | Binaries, AppArmor, opt-in apt deps; a no-op on the Mac | Deploys the set on the Mac (phase 1). On Linux: AppArmor, then system libraries through `playwright install-deps` at the pin's library version, then the set, never downloading a browser (R28, phase 2) |
| `docs/solutions/tooling-decisions/browsing-agents-run-stable-chrome-not-a-playwright-pinned-build.md`               | Holds the launch-flag measurements                      | Stays, updated with what ships (phase 11)                                                                                                                                                                |

### Scope Boundaries

- Chrome stable is never the test suites' browser. It moves on Google's schedule, which is the drift the set exists to
  prevent, and it has no headless shell.
- CI does not join the set. Each repo's workflow keeps installing its own pinned build.
- Firefox is not in the set; no consumer launches it.
- Aliases for revisions no release has named are not built. A repo can ask only for a released revision.
- Dependabot configuration in the consumer repos is not changed. A Dependabot bump shows up as drift (R21).
- `agent-slot` gains no agent-browser handling. The idle timeout and the automatic sweep free a slot.
- Removing AppArmor grants per host is not built. `config/apparmor.d/playwright` stays while the set runs sandboxed
  anywhere, and a stale grant on an unused path costs little.
- The Playwright CLI, Playwright MCP, and the Chrome DevTools CLI are not adopted. A task that needs performance traces,
  Lighthouse, or heap snapshots runs Chrome DevTools at an exact gate-cleared pin with `--executablePath`.
- Browsers in containers or as root keep the sandbox off by necessity. None of the consumers found runs one in a
  container.
- Lifting `kernel.apparmor_restrict_unprivileged_userns` host-wide
  (`docs/plans/2026-09-15-1428-feat-unprivileged-userns-host-plan.md`) is independent of this plan.
- The GStack Browser app on the Mac, a custom Chromium build, and gstack's Aside path are out of scope.
- emdash (an upstream third-party clone) is out of scope. cf_office_hours has no Playwright config, so it joins only the
  library check in R21.
- Microsoft Edge is not proposed.
- Running each agent tool on Claude Code end to end was not done, so token cost rests on the benchmark plus the sizes
  measured here.
- No probe or helper script ships without a caller and a test. A gate's probes run from a scratch directory.
- No interim change to the current deploy script runs ahead of phase 1, and no build is swapped by hand (decision 11).

### Dependencies / Assumptions

- **The provisioning work builds on PR #431, on `dev` and deployed.** It holds the `.links` registration, the deploy
  script's `--check`, and `tests/playwright-browsers-deploy.bats`.
- **CI has node.** R29's real-Playwright cases run `playwright-core` under node on the bats runners, with the library
  tarball cached by `.github/actions/setup-bats-suite`.
- **The crawl4ai skill and the browser-related skills live in the agent-skills repository.** Their changes (R7's
  `ignore_https_errors`, R11's routing) are PRs there, outside this repo's phases.
- **gstack upstream.** A gstack issue draft (its probes ignore `GSTACK_CHROMIUM_PATH`; its install deletes other tools'
  browsers) is pending with Brett. The alias removes this plan's dependence on the first half, and `.links` with
  `PLAYWRIGHT_SKIP_BROWSER_GC` covers the second.
- **Aliasing depends on Playwright's layout.** A Playwright release that moves its executable path breaks the alias for
  consumers at that release. Nothing in this plan detects it ahead of them: the job's suites run each repo's own
  library, and `--check` checks the set's layout. It shows up as that consumer's `Executable doesn't exist`.
- **CfT keeps publishing a headless shell and Stable channel data.** Both come from Google's public JSON API.
- **WebKit evidence comes from one project set.** agentnative-site's flows are the only WebKit consumer, and the pinned
  library passes there on its own WebKit. The set holds that one real WebKit directory; a second library in use at once
  would add a second, the one place the set might grow.
- **Ubuntu keeps shipping its `chrome` AppArmor profile.** If a later release drops it, Google's deb installs its own.
- **Removing `--disable-background-networking` lets a browser reach Google's services in the background.** That is the
  price of Safe Browsing, and it applies only behind the launcher: Chrome for agent-browser, CfT for gstack.

### Settled Decisions

Brett answered these on 2026-11-03, relayed by the coordinating session `dotfiles-prime`. Quoted words are Brett's as
relayed; the rest is the relay's wording.

| #   | Question                                    | Answer                                                                                                                                                                                                                                                                                                   | Sets                        |
| --- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| 1   | What agents browse with                     | Regular Chrome stable from Google's apt repository, behind the hardened launcher. CfT serves tests, gstack with its headed sessions, crawl4ai, and scripts.                                                                                                                                              | R6, R7, R9, R13             |
| 2   | Which tool drives it                        | agent-browser without its skill. Brett asked "Why not vercel agent-browser?". Pinned under the seven-day gate, its path set to the Chrome install, with any download or auto-detect off.                                                                                                                 | R10, R11                    |
| 3   | The seven-day gate                          | Every browser build is exempt, and "also need to ensure that our two browsers chrome and cft are updated often." CfT follows each Chrome stable release once the suites pass. Chrome updates at least daily. The agent CLI stays under the gate.                                                         | R4, R13                     |
| 4   | Whether CI joins the set                    | CI is unchanged.                                                                                                                                                                                                                                                                                         | R5                          |
| 5   | Whether bare launches run sandboxed         | Yes: every alias executable becomes the wrapper that drops the sandbox-off flags and clears the environment.                                                                                                                                                                                             | R8, R20                     |
| 6   | How many browsers                           | Two, Chrome and CfT. WebKit stays only if a repo's suite uses it, and ffmpeg stays as it is. agentnative-site's `mobile-ios` and `tablet` projects and `web-audit-webkit`, which its release preflight runs locally, use WebKit; no other repo in scope does.                                            | R1                          |
| 7   | The Playwright library                      | One pinned version across our repos, set in one place in dotfiles, with a check that flags drift and bumps them together. gstack and crawl4ai keep what they ship. Brett: "I'm not sure how that affects a pin. it is ok if the pin becomes dirty or is otherwise ignored after an initial commit, etc." | R21                         |
| 8   | Control                                     | Brett wants "to limit the number of browsers we have and also highly control which browsers different tools use through direct config and ENV VARs". Every consumer is pointed explicitly, every download is off, and a check lists any browser outside the two.                                         | R22, R23                    |
| 9   | Where `GSTACK_CHROMIUM_PATH` points         | The hardened launcher with CfT as its target, adding CRLSet and Safe Browsing on gstack's headless path, with a gate check that the launcher under gstack rejects a revoked host.                                                                                                                        | R6, R9, R12, AE19           |
| 10  | WebKit's revision                           | The revision `library-version`'s `browsers.json` names: WebKit matches the Playwright library the repos pin, and has no alias. The exemption covers every browser build, WebKit included.                                                                                                                | R1, R2, R4, R25             |
| 11  | A fix for the stale builds ahead of phase 1 | None. The stale builds wait for phase 1, with no interim PR against the current script and no build swapped by hand.                                                                                                                                                                                     | Build Phases                |
| 12  | Where phase 1 ends                          | Phase 1 is the pinned set with aliases on Linux and the Mac. Phase 2 is the sandbox wrapper, the pre-flip launch, safe moves, and `playwright install-deps`. The version floor, the lock, and stall limits go to the hourly pickup.                                                                      | Build Phases, R24, R27, R28 |
| 13  | WebKit under decision 5                     | R20 stays Chromium-only, and the docs say so.                                                                                                                                                                                                                                                            | R20                         |
| 14  | Whether the inventory deletes               | It lists only. The check removes nothing, and the runbook names the one-time `trash ~/.cache/puppeteer` the operator runs on each host.                                                                                                                                                                  | R23                         |

Brett answered 11 to 14 on 2026-11-05, relayed by `dotfiles-prime` in the relay's wording.

On decision 7, the relay reads Brett's sentence as: browser updates never wait on the library pin, and the aliases carry
any revision a pinned library asks for. R21 follows that reading.

**Interval, set here:** hourly for both browsers, which meets "at least daily" for Chrome. The reasoning is in The
Split.

### Sources / Research

- Repo: `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-deps-deploy.sh`, `config/apparmor.d/playwright`,
  `config/systemd/system/apparmor-playwright.service`, `config/shell/caches.sh`, `config/shell/supply-chain.sh`,
  `docs/runbooks/playwright-browser-launch.md`, `stow/claude/dot-claude/guides/cli-tools.md`, PR #431.
- Solutions: `docs/solutions/tooling-decisions/browsing-agents-run-stable-chrome-not-a-playwright-pinned-build.md`,
  `docs/solutions/runtime-errors/playwright-chromium-sandbox-ubuntu-2404-2026-04-17.md`,
  `docs/solutions/runtime-errors/playwright-install-deletes-unregistered-browsers-from-shared-cache.md`,
  `docs/solutions/runtime-errors/playwright-browser-install-stall-manual-cache-install.md`,
  `docs/solutions/configuration-fixes/unattended-upgrades-install-from-day-old-lists-so-third-party-security-builds-lag.md`.
- Chromium: `docs/security/faq.md` (threat model for Chrome for Testing; certificate revocation),
  `docs/chrome_for_testing/README.md`, `docs/chrome_for_testing/chrome_for_testing_configuration.md`.
- Chrome for Testing: developer.chrome.com/blog/chrome-for-testing; `last-known-good-versions*.json`,
  `known-good-versions.json`, and the GitHub history of `data/last-known-good-versions.json` in
  GoogleChromeLabs/chrome-for-testing.
- Chrome Releases: stable-channel posts of 2026-08-06, 2026-09-03, 2026-09-08, 2026-10-01, 2026-10-27, 2026-10-29,
  2026-11-03; `chromiumdash.appspot.com/fetch_releases`.
- Playwright: playwright.dev/docs/browsers, `/docs/getting-started-cli`, `/docs/getting-started-mcp`; `coreBundle.js`
  and `browsers.json` of each version tested; GHSA-6fg3-hvw7-2fwq, GHSA-7mvr-c777-76hp.
- Agent tools: npm metadata and installed packages of `@playwright/cli` 0.1.22, `@playwright/mcp` 0.0.83,
  `chrome-devtools-mcp` 1.12.0, `agent-browser` 0.40.0; agent-browser's `cli/src/native/cdp/chrome.rs` at v0.40.0;
  GHSA-3pvj-jv98-qhjq, GHSA-8qf9-62x2-82pp.
- Benchmark: maximilianfabian.dev/blog/browser-tools-for-agents (published 2026-10-31; runs 19 to 22 October 2026).
- Comparisons read for other candidates: browser-use.com/posts/best-mcp-servers-to-control-a-browser (vendor-run) and
  test-lab.ai/blog/agent-browser-vs-playwright-cli; each carries a vendor's interest, and their token figures were not
  used.
- gstack at v1.94.33.0 (commit 18d557d3): `browse/src/browser-manager.ts`, `browse/src/stealth.ts`,
  `bin/gstack-browser-ensure`, `browse/SKILL.md`; issues garrytan/gstack#3338 and #3440.
- crawl4ai 0.9.5: `browser_manager.py`, `async_configs.py`.
- Chrome for Testing's `last-known-good-versions.json`, read 2026-11-05: Stable is 157.0.8103.38, and its archives
  answer 200 from Google's bucket and through `cdn.playwright.dev`'s redirect.
- Consumer repos at their `dev` tips on 2026-11-03: lmgroktfy 02ac676, agentnative-site 8777e6a, meum-sites 5d15fb1,
  streamsgrp 2fb7cf4.

---

## Build Phases

Every phase except phase 3, a measurement gate, is one pull request to `dev`, built by its own agent slot from `dev`. A
slot's brief copies its phase's `Touches:` and `Adds:` lines, so the slot's push guard holds the PR to them.

**Rules for every phase.**

- **Sized for two review rounds.** Each phase carries a size budget in lines of script and of tests, docs excluded
  [estimated]. The budgets scale from one build of phases 1 and 2's scope as a single PR, which came to +1,110/-394
  lines of script and +1,813/-153 of tests [measured: `git diff --stat` of that build] and left one P1, four P2s, and
  five P3s open after two review rounds. A diff more than 1.5 times its budget stops before review, and the slot reports
  what grew instead of growing further.
- **Nothing from a later phase.** Each phase lists what it leaves out. A reviewer treats a missing later-phase item as
  out of scope, and a slot that finds one needed stops and reports rather than building it.
- **Docs ride with behavior.** A phase updates the runbook, README, and guidance lines that describe what it changes, in
  its own PR, so `dev` never documents a set it does not have. Agent routing (R11) waits for phase 11, once the tools it
  names exist.
- **Every requirement a phase lists has a bats case, and every acceptance example it lists has a case or a live run
  named in its Verify line.**
- **Live runs on both machines.** The Linux server runs every live check; the Mac runs the deploy and the checks its
  phase names. Live checks run after the PR merges and the operator deploys, and their results go into Other Measured
  Findings by a docs-only commit to `dev`.

| Phase | Kind         | Delivers                                                                            | Requirements                                                               | After             | Budget, script / tests |
| ----- | ------------ | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ----------------- | ---------------------- |
| 1     | PR           | One pinned set on both machines, at current CfT Stable                              | R1, R2, R3, R5, R25, R26, R29 (a, b), R30                                  | none              | 700 / 1,000            |
| 2     | PR           | The sandbox wrapper, the move, system libraries                                     | R1's retention, R8 for launches through the set, R20, R27, R28, R29 (c, d) | 1                 | 350 / 900              |
| 3     | Gate         | Sandboxed launches at the real path on both machines                                | AE1, AE2, AE14                                                             | 2, deployed       | none                   |
| 4     | PR           | The launcher's CfT entry, every pointer, consumers moved, a second gate             | R6, R7, R8, R9's CfT entry, R12 for CfT, R15, R22                          | 3                 | 300 / 600              |
| 5     | PR           | Inventory of browsers outside the set                                               | R23                                                                        | 4                 | 150 / 250              |
| 6     | PR, operator | Chrome on the Linux server, kept current                                            | R13, R14, R16                                                              | none              | 200 / 350              |
| 7     | PR           | agent-browser through the launcher's Chrome entry                                   | R9's Chrome entry, R10, R12 for Chrome                                     | 4, 6              | 220 / 450              |
| 8     | PR           | Each host picks up the pin every hour                                               | R24                                                                        | 3                 | 300 / 500              |
| 9     | PR           | The hourly CfT bump job                                                             | R4                                                                         | 8                 | 400 / 600              |
| 10    | PR           | One Playwright library version, its drift check, and the agent-browser pin proposal | R21, R10's pin proposal                                                    | 1, 7              | 170 / 280              |
| 11    | PR           | Agent guidance                                                                      | R11, R19                                                                   | 4, 5, 7, 8, 9, 10 | docs only              |

Phases 1, 2, and 3 run in that order. After phase 3, phases 4 and 8 can run side by side; both change the deploy script,
so the later one rebases onto the earlier. Phase 6 depends on nothing here, and phase 10 on phases 1 and 7.
`config/shell/caches.sh` belongs to phase 4 alone.

### Phase 1. One pinned set

**Delivers.** Every host that deploys the set holds one CfT build at current Stable (157.0.8103.38 on 2026-11-05), one
WebKit, and one ffmpeg, with an alias for every Chromium and ffmpeg revision a released Playwright at 1.57 or later
names and WebKit at the pinned library's revision with no alias, on the Linux server and the Mac. The stale builds and
the per-version map end here.

**Includes.**

- `config/playwright/browsers.pin` (R25): the CfT version; the WebKit and ffmpeg revisions; the Chromium and ffmpeg
  alias lists; the Playwright library version with the sha256 of its npm tarball, which R21 names, whose `browsers.json`
  names the WebKit revision, and which this phase's tests use; and a sha256 for each archive on each platform.
- One parser for the pin (R25), which every later reader uses.
- `scripts/playwright-browsers-deploy.sh` rewritten around the pin, with its libraries under
  `scripts/playwright-browsers/`: archives from the two fixed hosts, each held to its sha256, through `curl` and `unzip`
  (R3); numeric real directories with their provenance record (R26); aliases pointing straight at the real directories;
  one `.links` client per alias and per real directory, left alone when correct and otherwise replaced by rename (R3);
  replacement of an unrecorded directory at a set or alias name; Linux x86_64 and Apple silicon, with the Mac's WebKit
  archive chosen as the pinned library's registry chooses it (R1); `--check` with stable reasons; `--help`;
  `--pin PATH`; output per R30.
- `scripts/playwright-deps-deploy.sh` deploys the set on the Mac instead of exiting (R1).
- Tests per R29 (a) and (b): the pin's shapes, each rule above, and a real `playwright-core` at the pin's library
  version running `install` and `uninstall` against a deployed set, on pre-push and in CI, with the bats setup action
  caching that library.
- The runbook's provisioning, pin, `--check`, and reason-table sections, including how a person moves the pin before
  phase 9 exists: each archive's URL, `sha256sum` of each download, the ffmpeg revision from the newest release's
  `browsers.json`, and the WebKit revision from `library-version`'s. The README's script and config lines; and the lines
  in `stow/claude/dot-claude/CLAUDE.md` and the CLI tools guide that tell agents never to bump a repo's Playwright on
  its own, which aliasing makes false.

**A move in this phase** is a person editing the pin and rerunning the deploy. Everything new is provisioned and
verified before any alias moves, and each alias moves by an atomic rename. The deploy removes no CfT build that carries
its record, and `--check` reports one outside the pin as retained, not stray; phase 2 bounds retention to one build. The
first deploy on a host runs with no browser session open there, because it replaces every unrecorded directory at a set
or alias name, gstack's own `chromium-1248` included, and phase 3 is the first to measure a sandboxed browser losing its
build.

**Regression contract.** The rewrite keeps what callers rely on today: a run with no arguments deploys the set;
`--check` exits 0 on a healthy set and non-zero otherwise; PR #431's `.links` registration survives a consumer's
cleanup; and `scripts/playwright-deps-deploy.sh` with no flag deploys AppArmor and the set on Linux. One change is
intended: the positional Playwright version goes, and a run that passes one stops with a usage reason naming the pin.

**Not in this phase.** The wrapper and its stable path, the pre-flip launch, flips by wrapper, retention of exactly one
previous build, removal of failed candidates, and `playwright install-deps` (phase 2). The version floor,
`--allow-downgrade`, the deploy lock, and download stall limits (phase 8). `PLAYWRIGHT_SKIP_BROWSER_GC` and every other
pointer (phase 4). Anything outside `$PLAYWRIGHT_BROWSERS_PATH` (phase 5). A probe or helper script with no caller.

Touches: `config/playwright/**`, `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-browsers/**`,
`scripts/playwright-deps-deploy.sh`, `scripts/lint-shell`, `tests/playwright-*.bats`, `tests/lib/browser-set.bash`,
`.github/actions/setup-bats-suite/**`, `docs/runbooks/playwright-browser-launch.md`, `README.md`,
`stow/claude/dot-claude/CLAUDE.md`, `stow/claude/dot-claude/guides/cli-tools.md`

Adds: `config/playwright/browsers.pin`; the deploy's `--pin PATH` and `--help`; `--check` reasons for the pin,
provenance, aliases, clients, and stray directories.

Verify: bats for AE3's WebKit half, AE4's bats half, AE20's provenance half, AE22, AE25, AE26, AE27, AE29, and AE32.
Live on both machines: the first deploy timed with `gtime -f '%e s %M KB'`, recorded in Other Measured Findings,
`--check` exiting 0, AE1, AE4, and AE6. On the Linux server, AE4's live run is the at-or-above-floor
`playwright install chromium` no-op; its below-floor and `--force` cases download through node's extractor, which the
plan avoids on that kernel, so they run live on the Mac.

### Phase 2. The sandbox wrapper and the move

**Delivers.** Every Chromium launch through the set runs with its sandbox on and a cleared environment, and a move
launches the new build on that same path before anything points at it.

**Includes.**

- The wrapper (R20) in `chromium-999999` and `chromium_headless_shell-999999`, every Chromium alias pointing there, and
  the stable path `$PLAYWRIGHT_BROWSERS_PATH/.dotfiles/chrome`.
- `--check` failing when the AppArmor profile is not loaded or the set's path lies outside it, and when a wrapper
  differs from its template or names a build other than the pin's (R20).
- The move (R27): the pre-flip launch through the candidate's own wrapper, Playwright from its hashed tarball, the
  fixture extension, the record of an owed launch, the flip by wrapper rename, the previous build read from the wrapper
  and kept, and removal of recorded builds that are neither current nor previous.
- `scripts/playwright-deps-deploy.sh` in R28's order, with `--help` selected by pattern (R30).
- Tests per R29 (c) and (d): the wrapper's flag and environment rules, its AppArmor check against a sandbox profile
  directory, each move rule, `preflight.mjs` under real node against a fake `playwright-core`, and the deps script's
  order and its refusal of a bad library value.
- The runbook's wrapper, move, deps, and reason sections, and the README line.

**Not in this phase.** The launcher, and any flag beyond the two sandbox switches (phase 4). The version floor,
`--allow-downgrade`, the lock, and stall limits (phase 8). A wrapper for WebKit (decision 13). The gate's probe (phase
3).

Touches: `config/playwright/**`, `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-browsers/**`,
`scripts/playwright-deps-deploy.sh`, `tests/playwright-*.bats`, `tests/lib/browser-set.bash`,
`docs/runbooks/playwright-browser-launch.md`, `README.md`

Adds: the two wrapper directories and the stable path at run time, the wrapper template under
`scripts/playwright-browsers/`, and the fixture extension under `config/playwright/`; `--check` reasons for the wrapper,
the AppArmor profile, and an owed launch.

Verify: bats for AE21, AE23, AE24, AE28, and AE31's order. Live on both machines: the deploy installs the wrappers
through a passing launch, `--check` exits 0, and AE14.

### Phase 3. First execution gate

Measures, on both machines after phase 2's deploy, what only scratch copies of the wrapper have shown:

- A bare `chromium.launch()` runs renderers in their own user and PID namespaces with seccomp filter mode on the Linux
  server, and with Chrome's seatbelt switch on the Mac (AE14).
- lmgroktfy, meum-sites, and agentnative-site pass through the wrapper as they do on their controls (AE1).
- gstack's headed side panel loads on the Mac with `GSTACK_CHROMIUM_PATH` set by hand to the stable path (AE2).
- A sandboxed browser keeps working when its build's directory is removed mid-session. A failure adds a running-process
  check to phase 8's moves before they run unattended.
- The suites through a wrapper that also drops R9's sandbox siblings, which settles Open Question 6.
- Whether `apparmor.service` loads the profile on every boot of the Linux server.

Any probe runs from a scratch directory; the gate commits only its results. A failure takes the Goal Capsule's stop
condition.

### Phase 4. The launcher and the pointers

**Delivers.** gstack browses through the launcher's CfT entry with CRLSet and Safe Browsing, every consumer is pointed
at the set by config, and no consumer downloads a browser.

**Includes.**

- The launcher (R9) with its CfT entry, under the working name `browser-launch-cft`, reading its target from a variable
  that shell config exports only when the target exists. The script holds the flag list and the allowlist both entries
  use; phase 7 adds the Chrome entry, `browser-launch`, with its consumer.
- Open Question 6's outcome from phase 3, applied to the wrapper template.
- Shell config (R22): every pointer and download switch, `GSTACK_CHROMIUM_PATH` as R6 states, and the Chrome target's
  variable, exported only where Chrome is installed (R15).
- The deploy writes `~/.crawl4ai/chromium.path` (R7).
- Tests: the launcher's list matched on normalized switch names, the environment allowlist, the root refusal, the last
  stderr line, and `exec` keeping descriptors 3 and 4; one case holding the wrapper template's allowlist and switches to
  the launcher's (R9); the shell block with each target present and absent.
- The runbook's launcher and pointer sections, and the README lines.
- A live gate at its end, on both machines (AE19, and AE8 for the CfT entry): gstack through the CfT entry rejects
  `revoked.badssl.com` within 30 seconds of a context opening, with renderers sandboxed and a planted token absent, and
  the side panel loads on the Mac. A failure takes the stop condition.

**Not in this phase.** The launcher's Chrome entry and `AGENT_BROWSER_EXECUTABLE_PATH` (phase 7), Chrome's install
(phase 6), agent-browser (phase 7), the inventory and the Puppeteer cache's removal (phase 5), and agent routing (phase
11). The crawl4ai skill lives in the agent-skills repository, so turning `ignore_https_errors` off in its callers (R7)
is a separate PR there.

Touches: `stow/local/dot-local/bin/browser-launch*`, `config/shell/caches.sh`, `tests/shell-config.bats`,
`tests/browser-launch.bats`, `scripts/core-env-allowlist.tsv`, `scripts/playwright-browsers-deploy.sh`,
`scripts/playwright-browsers/**`, `tests/playwright-*.bats`, `docs/runbooks/playwright-browser-launch.md`, `README.md`

Adds: the launcher's CfT entry; the shell-config variables R22 names.

Verify: bats for R9's missing-target line on the CfT entry (stable reason, deploy command, last stderr line). Live: the
gate above, AE6, AE7, and AE14.

### Phase 5. Inventory

**Delivers.** A check lists every browser on a host outside Chrome and the set.

**Includes.** R23's check, its exemption list, and the Mac's paths; the runbook section, which names the one-time
`trash ~/.cache/puppeteer` the operator runs on each host once phase 4's pointers are live.

**Not in this phase.** Any removal by the check (decision 14); anything inside the set, which `--check` owns.

Touches: `scripts/browser-inventory.sh`, `config/browser-inventory/**`, `tests/browser-inventory.bats`,
`docs/runbooks/playwright-browser-launch.md`, `README.md`

Adds: `scripts/browser-inventory.sh`; its exemption list.

Verify: bats for AE17.

### Phase 6. Chrome on the Linux server

**Delivers.** Chrome stable from Google's signed apt repository on each host that opts in, within about an hour of
Google's index.

**Includes.** `scripts/chrome-deploy.sh` (R13), using the source and keyring paths the deb's own cron job maintains; the
hourly system timer in `config/systemd/system/`; the check in R16, which reports and restarts nothing; the Mac keeping
Google's updater (R14). The operator runs `sudo scripts/chrome-deploy.sh` on each host that needs Chrome.

**Not in this phase.** The launcher's Chrome entry under agent-browser (phase 7).

Touches: `scripts/chrome-deploy.sh`, `config/systemd/system/chrome-*`, `scripts/upgrade/lib/stale-procs.sh`,
`tests/chrome-deploy.bats`, `docs/runbooks/**`, `README.md`, `AGENTS.md`

Adds: `scripts/chrome-deploy.sh` and its `--check`; the timer.

Verify: bats for AE11's check half and AE12. Live after the operator's deploy: AE11.

### Phase 7. Agent browsing

**Delivers.** Agents open pages nobody vetted through agent-browser, driving Chrome through the launcher.

**Includes.** The launcher's Chrome entry (R9), `browser-launch`, on the script phase 4 built; the shim (R10) with its
config file, refused flags and verbs, a session derived from the working tree, and the idle timeout, after the three
agent-browser facts in Open Question 8 are measured; R12 for Chrome, live on both machines.

**Not in this phase.** The weekly pin proposal (phase 10); agent routing (phase 11).

Touches: `stow/local/dot-local/bin/agent-browser`, `stow/local/dot-local/bin/browser-launch*`,
`config/agent-browser/**`, `tests/agent-browser-shim.bats`, `tests/browser-launch.bats`, `docs/runbooks/**`, `README.md`

Adds: the `agent-browser` command; the launcher's Chrome entry; the shim's config file.

Verify: bats for AE9 and AE15. Live: AE8, AE10, and AE13.

### Phase 8. Host pickup

**Delivers.** Every host that deploys the set takes up a pin change on `dev` within the hour, with no person involved.

**Includes.** R24: the hourly user timer on the Linux server and LaunchAgent on the Mac, the fetch over HTTPS, the
version floor read from the running build's record, the version ceiling, `--allow-downgrade`, the record of the pin a
host deployed and the checks that compare against it, the lock, the connect and stall limits, and the staleness check.
The units do nothing on a host whose set the deploy has not recorded, and the deploy enables them on its first
successful run (R24).

**Not in this phase.** Moving the pin (phase 9).

Touches: `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-browsers/**`,
`stow/local/dot-config/systemd/user/browser-set-pickup.*`,
`stow/launchagent/Library/LaunchAgents/com.user.browser-set-pickup.plist`, `tests/playwright-*.bats`,
`tests/launchagents.bats`, `docs/runbooks/playwright-browser-launch.md`, `README.md`

Adds: `--allow-downgrade`; the timer and the LaunchAgent; reasons for a lower pin, a pin above Stable, a held lock, and
an unwritable cache.

Verify: bats for AE18, AE20's floor half, AE30, AE35, and AE37. Live: a pin change on `dev` reaches both machines within
an hour.

### Phase 9. The CfT bump job

**Delivers.** Each new Chrome stable release's CfT build moves the pin once the real suites pass on it.

**Includes.** R4 in full: the two fetches, the whole-pin candidate under the deploy lock, the gate with its retry and
holds, the alias-only PRs, a person's rollback as a hold, and the job's alarm. The job's units carry `ConditionHost=`
for the Linux server and are enabled by `scripts/host-jobs-enable.sh`, the pattern the repo's other server jobs follow.

Touches: `scripts/browser-set-bump.sh`, `scripts/browser-set-bump/**`, `scripts/host-jobs-enable.sh`,
`stow/local/dot-config/systemd/user/browser-set-bump.*`, `tests/browser-set-bump.bats`, `docs/runbooks/**`, `README.md`

Adds: the job and its timer.

Verify: bats for AE5, AE33, AE34, and AE36. Live: one Chrome stable release taken through the job to a merged pin, and
AE3's Chromium half.

### Phase 10. Library

**Delivers.** One Playwright library version across the repos, with drift reported, and the agent-browser pin kept near
the newest version the gate allows.

**Includes.** R21's check and bump, reading the version from the pin through R25's parser; R10's weekly agent-browser
pin proposal on the same lookup of gate-allowed versions and the same PR step, unless Open Question 5 makes it a report
in this check; the CLI tools guide naming the pin and the check.

Touches: `scripts/playwright-library-check.sh`, `tests/playwright-library-check.bats`, `config/agent-browser/**`,
`stow/local/dot-local/bin/agent-browser`, `stow/local/dot-config/systemd/user/browser-pin-proposal.*`,
`scripts/host-jobs-enable.sh`, `stow/claude/dot-claude/guides/cli-tools.md`, `docs/runbooks/**`, `README.md`

Adds: the check and its bump mode; the weekly proposal and its timer.

Verify: bats for AE16. Live: AE3's check half.

### Phase 11. Agent guidance

**Delivers.** Agents read where to send each kind of page, and the docs describe what phases 1 to 10 shipped.

**Includes.** R11 in the always-loaded `CLAUDE.md` and the CLI tools guide; R19's remaining docs, including the
supply-chain guide's gate exemption. The solutions docs on Playwright launch are published through `sd-commit-doc`, and
the browser-related skills change in a separate PR to the agent-skills repository.

Touches: `stow/claude/dot-claude/CLAUDE.md`, `stow/claude/dot-claude/guides/**`, `docs/runbooks/**`, `README.md`

Adds: none.

Verify: `markdownlint-cli2`; a read-through against what phases 1 to 10 shipped.

## Failure Modes

What can go wrong, which requirement closes it, and the phase that builds the close.

| Failure                                                      | How it happens                                                              | Closed by                                                                                                            | Phase |
| ------------------------------------------------------------ | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ----- |
| A corrupt or swapped archive                                 | Google's bucket or `cdn.playwright.dev` serves other bytes                  | sha256 per archive (R3, AE4)                                                                                         | 1     |
| An alias no longer resolves                                  | A Playwright release moves its executable path                              | `--check`, and the bump job's suite run (R3, R4)                                                                     | 1, 9  |
| Another tool's cleanup deletes the set                       | A tool with a scrubbed environment runs `playwright install`                | One client per alias and real directory (R3)                                                                         | 1     |
| A cleanup during a no-op deploy deletes every alias's target | The cleanup reads a client the deploy is rewriting as broken                | Clients left alone when correct and replaced by rename (R3, AE25)                                                    | 1     |
| A deploy deletes outside the cache                           | A `.links` entry names `..` or the deploy's own records                     | The deploy follows only the client shapes it writes (R3, AE26)                                                       | 1     |
| A deploy reports OK over a build that cannot start           | The executable is gone while its markers remain                             | A directory counts as provisioned only with its executable and record (R26, AE27)                                    | 1     |
| An older build passes for a newer version                    | Directory numbers ignore the Chrome major and minor                         | The record binds the archive's URL (R26, AE20); the floor (R24)                                                      | 1, 8  |
| The previous build loses its client                          | `.links` is emptied while a previous build is kept                          | Every deploy registers the set and every recorded build (R3, AE29)                                                   | 1     |
| A wrong library hash or version reaches hosts                | Tests skip on any fetch failure                                             | They fail on an HTTP error or a mismatch (R29, AE22)                                                                 | 1     |
| A pin value runs as a command                                | A reader picks a field with `sed` and hands it to `bun x`                   | One parser for every reader (R25, AE23)                                                                              | 1, 2  |
| A move breaks a build the gate passed                        | The gate launched the raw build with the deploy's environment               | The gate launches through the candidate's own wrapper (R27)                                                          | 2     |
| The gate runs unverified code                                | Its Playwright installs from the registry with no hash                      | The tarball's sha256 is in the pin (R27)                                                                             | 2     |
| A failed launch is forgotten                                 | The owed launch lived in a shell variable                                   | A record written before the bytes arrive (R27, AE21)                                                                 | 2     |
| Recovery deletes the running build                           | The record of deployed builds is missing                                    | The previous build is read from the wrapper (R27, AE24)                                                              | 2     |
| A failed candidate stays on disk                             | Nothing removes a build the record never named                              | Recorded builds outside current and previous go after a passing move (R27, AE28)                                     | 2     |
| A new host fails its first launch                            | Its system libraries install after the launch that needs them               | AppArmor, then libraries, then the set (R28, AE31)                                                                   | 2     |
| Every launch fails `No usable sandbox!`                      | The AppArmor profile is not loaded, or the cache lies outside it            | `--check` names which, and the wrapper names the missing profile before the browser starts (R20)                     | 2     |
| Two deploys delete each other's builds                       | A pid-file lock admits both                                                 | A lock the kernel releases (R24, AE30)                                                                               | 8     |
| A retry loops on the wrong reason                            | An unwritable cache reads as a held lock                                    | Its own reason (R24, AE30)                                                                                           | 8     |
| An unattended deploy never ends                              | A download stalls                                                           | Connect and stall limits (R24)                                                                                       | 8     |
| An agent runs the fix an error suggests                      | A launcher's error is lost in a tool's framing                              | One self-contained last line (R9 in phase 4, AE9 in phase 7)                                                         | 4, 7  |
| Chrome stops updating                                        | Google's origin leaves the upgrade path                                     | The check in R16 (AE11)                                                                                              | 6     |
| A revoked certificate loads                                  | The first page of any session predates CRLSet                               | Accepted limit; `--component-updater=fast-update` shortens the window to about 14 s (R9)                             | 4     |
| A CfT release is skipped with no alarm                       | A gate failure holds the version, or a non-build arm failure looks like one | A missing report retries hourly, and the job's alarm fails while the pin trails Stable by more than a day (R4, AE33) | 9     |
| A rollback is undone within the hour                         | The job sees Stable above a pin a person lowered                            | A lowered pin holds the versions above it (R4, AE34)                                                                 | 9     |
| New Playwright revisions wait for a CfT move                 | The job read releases only on a CfT bump                                    | Alias-only PRs every hour (R4, AE36)                                                                                 | 9     |
| A WebKit move reaches hosts untested                         | The candidate arm ran only the CfT build                                    | The candidate arm runs the whole candidate pin (R4)                                                                  | 9     |
| A pickup deletes the job's candidate                         | Retention removes recorded builds outside current and previous              | The job holds the deploy lock while its candidate is on disk (R4)                                                    | 9     |
| A pre-release build freezes updates                          | A Beta version copied into the pin raises every floor                       | The version ceiling (R24, AE35)                                                                                      | 8     |
| A host's check fails after every unattended move             | The checkout's pin trails the one the pickup deployed                       | Checks compare against the deployed pin (R24, AE37)                                                                  | 8     |
| The headless-shell wrapper flips untested                    | The gate's extension launch needs the full binary                           | Two launches, one per wrapper (R27)                                                                                  | 2     |
| A script launches Chrome unsandboxed with the caller's keys  | `channel: 'chrome'` goes straight to Chrome                                 | Guidance routes it to the launcher's Chrome entry (R8, R11)                                                          | 11    |
| Root runs unverified npm code                                | `install-deps` came from the registry under `sudo`                          | It runs from the hash-checked tarball as the invoking user (R28)                                                     | 2     |
| A flagged page loads                                         | The session is younger than about 4 minutes                                 | Accepted limit of both builds                                                                                        | none  |

The last two are silent. They are limits of both browsers, stated where the hardened conditions are listed.

## Open Questions

Each is settled in the phase named, from measurement or the code then on `dev`.

1. **Who runs each check and where a failure shows** (phases 4, 6, 8, 10). The repo surfaces host checks at session
   start (`failed-user-units.sh`), silent when they pass.
2. **The launcher and the owner's signed-in Chrome on the Mac** (phase 4). A direct run with no `--user-data-dir` opens
   the everyday profile; Playwright and the shim always pass a temporary one. Candidate: the launcher refuses to start
   without `--user-data-dir` outside the default profile directory. Inferred from Chrome's default behavior, not
   measured.
3. **The replaced-executable report in R16** (phase 6). It needs a report-only split of
   `scripts/upgrade/lib/stale-procs.sh`, which `scripts/upgrade/brew.sh` also uses. R10's idle timeout already bounds
   agent-browser's daemon, and a running CfT survived its directory's removal (measured unsandboxed). Candidate: drop
   the report and AE12 if the first Chrome upgrade under a live daemon shows no breakage.
4. **Chrome's signing key** (phase 6). An HTTPS fetch of the key with no fingerprint check makes the signed index only
   as strong as that fetch. Candidate: `scripts/chrome-deploy.sh` compares the key's fingerprint with one committed in
   dotfiles and stops on a mismatch, naming both.
5. **The weekly agent-browser proposal** (phase 10). A person merges each one, and the tool released 6 times in 9 days.
   Candidate: drop the job and have R21's check report a pin that trails the newest gate-cleared version.
6. **The wrapper's list against the launcher's** (phase 3). A bare launch that passes a sibling such as
   `--disable-seccomp-filter-sandbox` keeps it through R20's two-switch wrapper. Candidate: R20 drops R9's sandbox
   siblings too, if the suites pass through it at phase 3.
7. **crawl4ai** (phase 4). Which callers dotfiles configures: the crawl4ai skill's scripts and browser template, `crwl`
   through `-b` or `-B`, and each importing repo such as scrawl2, each at a listed version. The Mac's crawl4ai moves
   from 0.7.7 to a release at or above 0.9.5. Whether managed-browser mode with `~/.crawl4ai/chromium.path` at the
   launcher closes R7's limit for long sessions is unmeasured. crawl4ai's CLI on an expired certificate ended in the
   same `NoneType` error under both settings, so AE7 measures it.
8. **agent-browser** (phase 7). Its output cap and idle timeout values; whether its daemon keeps the slot as its working
   directory, as the Playwright CLI's does (AE13); whether `batch --json` on stdin can run a refused verb past the
   shim's argument check; whether `auth login` works under `--allowed-domains`; and where the vault keeps its key.
9. **Puppeteer's download switches** (phase 4). The names the Puppeteer version in use reads for skipping each browser's
   download, and whether R22 needs more than `PUPPETEER_SKIP_DOWNLOAD`.
10. **The launcher's command names** (phase 4). `browser-launch` and `browser-launch-cft` are working names; phase 4's
    brief fixes them.
11. **The Mac's lock tool** (phase 8). macOS ships no `flock(1)`. Candidates are Homebrew's `flock` and the system
    perl's `flock`; phase 8 checks which the Mac has before choosing, and the deploy names the missing tool with a
    stable reason.

## Appendix: Engineering Review (plan-eng-review, 2026-11-05)

Target: this plan at `addd17d`. The review ran in an unattended agent slot, where the question tool is denied, so each
choice below is decided from the code on `dev`, the plan's measurements, and repo precedent, and recorded with its
evidence. Brett's decisions are in Settled Decisions; none was reopened. Evidence kinds: static reads of `dev` and of
`--help` output; no proposed code ran.

### Scope Challenge

- **What already exists.** #431's `.links` registration and `--check` (`scripts/playwright-browsers-deploy.sh:191-270`);
  the alias mechanism (`link_consumer_alias`, same file); the copy-deploy shape with `--check`
  (`scripts/sysctl-deploy.sh`); the stale-executable scan, which reports transient units as `left-running`
  (`scripts/upgrade/lib/stale-procs.sh:69`); per-host user timers gated by `ConditionHost=` and enabled by
  `scripts/host-jobs-enable.sh`; the AppArmor glob (`config/apparmor.d/playwright`); Playwright's own `install-deps`
  (`playwright install-deps --help`, 1.61.1).
- **Minimum change.** Phase 1 alone ends the stale builds and the per-version map. Every later phase is separable and
  listed with what it leaves out.
- **Complexity.** About 45 repo paths across the eleven phases' `Touches:` lists, 3 to 13 per phase [estimated], and six
  new modules: the deploy's libraries, the wrapper, the launcher, the shim, the pickup, and the bump job. The gate
  trips; E-D1 settles the structure.
- **Search.** The new patterns are standard: `rename(2)` for atomic replacement, `flock(1)` for a lock the kernel
  releases, and one template rendered for both the live wrapper and the move's stage copy [Layer 1]. No web search ran;
  in-distribution knowledge only.
- **TODOS.** The repo tracks no TODOS file; local TODO files are gitignored by policy.
- **Distribution.** Nothing is published. Archives come from Google's bucket and `cdn.playwright.dev` for linux64 and
  mac-arm64, both measured to answer.
- **Prior learning applied:** `dotfiles-same-version-all-hosts` (10/10, 2026-09-22). The version floor guards a branch
  any commit can change, not skew between hosts.
- **Retrospective.** `git log` of the named paths shows #431, #450 (`stale-procs.sh` reports what it cannot restart),
  and #422; no reverts.

```text
REALITY: premise-table pass 70+ factual claims carry measured or file receipts; unverified=4 (sandboxed browser surviving its directory's removal, the wrapper at the real alias path, the launcher over Chrome, the Mac's lock tool) docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:946
REALITY: already-done pass origin/dev since 2026-11-03 touches the named paths only through #450 (stale-procs.sh), which narrows Open Question 3 and builds nothing this plan schedules scripts/upgrade/lib/stale-procs.sh:69
REALITY: surface-check pass playwright install-deps exists with --dry-run (Playwright 1.61.1 --help); flock(1) is util-linux on Linux and absent from stock macOS, now a finding (A4) docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:530
REALITY: binding-decisions pass decisions 1 to 13 hold; the 2026-11-04 eng decision D9 (shared report-only scan) stays open as Open Question 3, as the doc review left it docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:881
REALITY: numbers finding the size budgets were tagged with the measured diffstat as an estimate; corrected to [measured: git diff --stat] for +1,110/-394 and +1,813/-153 and [estimated] for the budgets docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:953
REALITY: deferred-asks pass no linked issue; the brief's five lessons each map to a requirement, an acceptance example, or a phase list docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:946
REALITY: pr-count pass no ship policy on file; nine PRs and two gates, each sized for two review rounds by decision 12 docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:971
```

Scope result: scope accepted as-is. MODE: FULL_REVIEW.

### Decision ledger

Each choice was decided on its recommendation from the evidence named, because no person answers in the slot.

| ID | Finding | Options | Chosen | Evidence | Accepted scope |
| -- | ------- | ------- | ------ | -------- | -------------- |
| E-D1 | Complexity gate | Original arrangement; smaller arrangement | Original | Each phase already holds one script family; merging the deploy's libraries back into one file passes the 200-line refactor trigger | No change |
| E-D2 | A1 | Gate the pickup units on the set's record and let the deploy enable them, with the bump job on `ConditionHost=` through `scripts/host-jobs-enable.sh`; a new stow package for browser hosts | Gate and enable | `stow/local` is in `SHARED_PACKAGES` (`scripts/stow-deploy:28`); server jobs follow `ConditionHost=` plus `host-jobs-enable.sh` (`scripts/host-jobs-enable.sh:7`) | R24's "Where it runs"; phase 8 and 9 text and Touches |
| E-D3 | A2 | One bats case holds the two lists equal; a shared file both read; leave two copies | Bats case | The launcher is stowed and runs outside the repo, so it cannot source a repo file; a failing build is the red flag's fix | R9's last sentence; phase 4's tests |
| E-D4 | A4 | Name `flock(1)` on Linux and check the Mac's tool in phase 8; name a Mac tool now | Check in phase 8 | Stock macOS has no `flock(1)`, and this review cannot read the Mac | R24's lock sentence; Open Question 11 |
| E-D5 | Q1 | State a regression contract with the positional version refused; leave the argument unspecified | Contract | The positional `VERSION` (`scripts/playwright-browsers-deploy.sh:74`) has no caller that passes one (`scripts/playwright-deps-deploy.sh:85`) | Phase 1's Regression contract |

Factual corrections, no question needed: F1, R16's check is `scripts/chrome-deploy.sh --check`, which phase 6 builds,
not R24's, which phase 8 builds. F2, the budget line's measured and estimated figures are tagged apart.

Approval readiness: PASS (E-D1 to E-D5, decided from evidence in an unattended slot; F1 and F2 change no behavior).

### 1. Architecture

```text
 config/playwright/browsers.pin ◀── phase 9 bump job (Linux server, hourly): CfT Stable, real suites, pin-only PR
          │ one parser (R25)
          ▼
 phase 8 pickup (hourly, every host with the set) ──▶ scripts/playwright-browsers-deploy.sh (one deploy at a time)
          │ curl, sha256, unzip, provenance record (R26)
          ▼
 $PLAYWRIGHT_BROWSERS_PATH
   chromium-<build*1000+patch>/   real build, record = sha256 + URL
   chromium-999999/ chrome  ───────▶ wrapper: drop 2 switches, clear env, exec real build (R20)
   chromium-<rev> ─▶ chromium-999999 (every released revision, one client each)
   webkit-<rev> real; ffmpeg-<rev>  real directory and aliases
   .dotfiles/chrome ─▶ wrapper      stable path for tools that take one
          │
 move (R27): stage wrapper ─▶ sandboxed launch + fixture extension ─▶ rename wrappers ─▶ keep previous, drop failed
          │
 launcher (R9): CfT entry for gstack, Chrome entry for agent-browser; flags stripped, env cleared, exec
```

- A1. [INFORMATIONAL] (confidence: 8/10) `scripts/stow-deploy:28` reads
  `SHARED_PACKAGES=(secrets shell zsh bash git ssh gh github local ...)`, and R24 placed the pickup timer in
  `stow/local`, so it would reach every server, browser set or not, with no named path to enable it.
  `scripts/host-jobs-enable.sh:7` shows the repo's pattern: "The units ship in the shared `obsidian` and `local`
  packages and carry ConditionHost=bigdaddy". Disposition: accepted (E-D2).
- A2. [INFORMATIONAL] (confidence: 8/10) R9 lists the environment allowlist (`HOME`, `PATH`, `TMPDIR`, ...), and R20
  says the wrapper "clears the environment as R9 does": two copies in two files, red flag 8. Disposition: accepted
  (E-D3).
- A3. [INFORMATIONAL] (confidence: 9/10) R16 read "The check in R24 also fails when an installed Chrome is older", while
  phase 6 builds R16 and lists "`scripts/chrome-deploy.sh` and its `--check`" under Adds, and phase 8 builds R24.
  Disposition: corrected (F1).
- A4. [INFORMATIONAL] (confidence: 6/10) Medium confidence, verify on the Mac: R24 asks for a lock the kernel releases,
  and stock macOS ships no `flock(1)`. Disposition: accepted (E-D4).

Design twice. Shape A (chosen) is aliases plus wrappers: consumers change nothing, and one executable at the path every
tool launches holds the policy. Shape B is per-consumer `executablePath` and tool settings, which leaks the path into
four repos and three tools and cannot reach a bare `chromium.launch()` (Key Decisions). A hides more behind less. Red
flags: 8 is A2, closed by a test. 6 (two ways to deploy the set): `scripts/playwright-deps-deploy.sh` calls the deploy
script, so there is one path. 5 (split ownership): the floor and retention both read the wrapper, one owner. No others
apply.

Each new path's realistic failure and its handling is in Failure Modes; critical gaps: 0, because the two silent rows
are limits of both browsers, stated where the hardened conditions are.

### 2. Code quality

- Q1. [INFORMATIONAL] (confidence: 7/10) `scripts/playwright-browsers-deploy.sh:74` reads
  `VERSION="${1:-$DEFAULT_VERSION}"`; the pin replaces it, and the plan did not say what a run passing a version gets.
  Disposition: accepted (E-D5).

Shared code: the environment allowlist is A2. R16's report reuses `scripts/upgrade/lib/stale-procs.sh`, where #450 added
a `left-running` report for units it does not restart (line 69), so the report-only half exists; whether R16 keeps the
report at all stays Open Question 3 for phase 6. No other extraction is proposed. Scripts follow AGENTS.md:
`#!/usr/bin/env bash`, severity prefixes on stderr (R30), the bash 4.4 guard wherever a bash 4 construct appears.

### 3. Tests

Framework: bats through `scripts/run-tests` (AGENTS.md, Local gates mirror CI).

```text
CODE PATHS (all proposed)                               USER FLOWS
[+] pin parser (ph 1)                                   [+] Repo runs its suite
  ├── [GAP] each accepted shape; each refusal, masked     ├── [GAP] [→E2E] set deployed, suites pass (AE1, live)
  └── [GAP] wrong library hash or version fails (AE22)    └── [GAP] [→E2E] newer Playwright, no change (AE3, live)
[+] provisioning (ph 1)                                 [+] Another tool installs
  ├── [GAP] sha256 mismatch stops, set intact (AE4)       └── [GAP] [→E2E] real install and uninstall (AE4, CI)
  ├── [GAP] relabelled version fetches its URL (AE20)   [+] A bare script
  ├── [GAP] executable gone, fetched again (AE27)         └── [GAP] [→E2E] sandboxed through the alias (AE14, ph 3)
  ├── [GAP] Mac WebKit archive, release refused (AE32)  [+] gstack
  └── [GAP] positional version refused (contract)         ├── [GAP] [→E2E] probe prints BROWSER_OK (AE6, live)
[+] clients and deletion (ph 1)                           └── [GAP] [→E2E] launcher rejects revoked host (AE19, ph 4)
  ├── [GAP] correct client left alone, rename (AE25)    [+] Agent on an untrusted page
  ├── [GAP] foreign .links target survives (AE26)         ├── [GAP] [→E2E] sandboxed, CA refused (AE8, ph 7)
  └── [GAP] emptied .links whole again (AE29)             └── [GAP] [→E2E] two agents kept apart (AE10, ph 7)
[+] wrapper and move (ph 2)                             [+] Host pickup
  ├── [GAP] drops two switches, keeps them as root        ├── [GAP] lower pin refused, record lost (AE18)
  ├── [GAP] owed launch survives failure (AE21)           └── [GAP] two deploys, unwritable cache (AE30)
  ├── [GAP] running build kept, record lost (AE24)      [+] Chrome upgrade
  ├── [GAP] failed candidate removed (AE28)               └── [GAP] [→E2E] timer installs, check fails (AE11)
  └── [GAP] preflight.mjs under real node (R29 c)
[+] deps script (ph 2)
  └── [GAP] libraries before launch; bad value (AE23, AE31)
[+] launcher (ph 4)
  └── [GAP] list, allowlist parity, root, last line, fds
[+] shim (ph 7), bump job (ph 9), library check (ph 10)
  └── [GAP] AE15, AE5, AE16

COVERAGE: 0/38 paths tested (all proposed)  |  Code paths: 24/38  |  User flows: 14/38
QUALITY: none yet  |  GAPS: 38 (14 E2E or live, 0 eval)
```

Regression contract: E-D5. Tests made obsolete: the cases in `tests/playwright-browsers-deploy.bats` that pass a
Playwright version (`--check "$VERSION"`, and the next-step text at line 152). Test Plan:
`~/.gstack/projects/brettdavies-dotfiles/brett-dev-eng-review-test-plan-20261105-142039.md`.

### 4. Performance

No issues found. The pickup costs one small HTTPS fetch per host per hour. A deploy that changes nothing reads about
thirty client files and writes none (R3). R29 (b)'s library download is cached by the bats setup action. The move's
launch adds seconds per move, and moves come about every 4.4 days (The Split).

### Outside voice

Disabled (`codex_reviews` is `disabled`, and the brief turns cross-model review off); recorded as skipped.

### NOT in scope

- Anything Brett settled in decisions 1 to 13, including the interim fix (decision 11).
- Changes to the crawl4ai skill and the browser-related skills, which live in the agent-skills repository.
- Restarting a running browser on a replaced build: the checks report.

### What already exists

Reused, not rebuilt: #431's registration and `--check`, the AppArmor profile and its boot unit,
`scripts/host-jobs-enable.sh`'s enable pattern, `scripts/upgrade/lib/stale-procs.sh`, `playwright install-deps`, and
`scripts/sysctl-deploy.sh`'s `--check` shape. Rebuilt: the deploy script around the pin, because its per-version map is
what goes.

### Parallelization

Lane A: phases 1, 2, 3 in order. Then lane B: phase 4, then 5; lane C: phase 8, then 9; both B and C change the deploy
script, so the later rebases onto the earlier. Lane D: phase 6 any time, then 7 after phases 4 and 6. Lane E: phase 10
after phase 1. Phase 11 closes.

### Implementation Tasks

The phases in Build Phases are the build list. These tasks come from this review's findings and land inside the phase
named.

- [ ] **ET1 (P1, human: ~1h / CC: ~10min)** — pickup — gate the pickup units on the set's record and enable them from
  the deploy; put the bump job on `ConditionHost=` through `scripts/host-jobs-enable.sh`
  - Surfaced by: Architecture — A1
  - Files: phase 8 and 9 Touches
  - Verify: a bats case that a host with no recorded set runs nothing; `systemctl --user list-timers` after a first
    deploy
- [ ] **ET2 (P1, human: ~30min / CC: ~5min)** — launcher — one bats case holding the wrapper template's allowlist and
  switches to the launcher's
  - Surfaced by: Architecture — A2
  - Files: `tests/browser-launch.bats`
  - Verify: the case fails when either list changes alone
- [ ] **ET3 (P2, human: ~30min / CC: ~10min)** — pickup — check the Mac's lock tool on the Mac and name it in R24
  - Surfaced by: Architecture — A4
  - Files: `scripts/playwright-browsers/**`
  - Verify: AE30 on both machines
- [ ] **ET4 (P1, human: ~30min / CC: ~5min)** — deploy — keep the regression contract and retire the version-argument
  cases
  - Surfaced by: Code quality — Q1
  - Files: `tests/playwright-browsers-deploy.bats`
  - Verify: a run with a positional version exits with the usage reason naming the pin

_No new tasks from Performance._

### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 applicable rows emitted, 4 unverified premises
- Architecture Review: 4 issues found
- Code Quality Review: 1 issue found
- Test Review: diagram produced, 38 gaps identified
- Performance Review: 0 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed (no tracked TODOS file)
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 0 in this review
- Outside voice: codex, disabled (`codex_reviews`)
- Parallelization: 5 lanes, 3 parallel / 2 sequential
- Lake Score: N/A (no answers scored for Completeness)

## Appendix: DX Review (plan-devex-review, 2026-11-05)

Target: this plan at `751eacf`. Run in the same unattended slot under the same rule: each choice is decided from
evidence and recorded here. Product type: Platform (host provisioning) with a CLI surface (the deploy and its `--check`,
the deps script, the wrapper's and the launcher's error lines, the shim) and a guidance surface agents read. Mode: DX
POLISH, because this enhances provisioning that exists. No design doc exists; the `/office-hours` offer was skipped as
unattended.

### Developer Persona Card

```text
TARGET DEVELOPER PERSONA
========================
Who:       an AI coding agent in an agent slot on the Linux server or the Mac, unattended
Context:   running a repo's e2e suite, gstack, crawl4ai, or a script that launches a browser
Tolerance: one launch attempt; it follows the first fix line an error prints, literally
Expects:   browsers already on the host, and an error that names the command that fixes it
Secondary: the operator at a terminal, deploying a host, moving the pin, reading --check
```

### Developer Empathy Narrative

I am an agent in a slot running lmgroktfy's suite. `bun x playwright test` passes in about 22 seconds. Nothing tells me
the browser under it is CfT 151.0.7922.34, which loads a host whose CA key was compromised with status 200 (measured),
or that it runs with `--no-sandbox`. `~/.claude/CLAUDE.md:293` tells me Playwright browsers are system-provided and
never to run `playwright install`, so I don't. Its next lines tell me repos exact-pin one version and bumping is a
dotfiles job, so I leave a Dependabot bump of `@playwright/test` alone. If I run
`scripts/playwright-browsers-deploy.sh --check` in the dotfiles repo, it prints OK lines, because it checks that the
directories exist, not which version they hold (`scripts/playwright-browsers-deploy.sh:232-270`). After phase 2, if the
AppArmor profile is not loaded at boot, my next launch dies with Chromium's own `No usable sandbox!` text, which closes
by suggesting `--no-sandbox`. Predicted, not observed: I would pass it, the wrapper would strip it, and I would be stuck
with no dotfiles line telling me what to ask for.

### Competitive DX Benchmark

The clock runs from a consumer's first command to a loaded page, on the covered CfT path with the browser on disk, one
run each [measured: GNU time, 2026-11-03].

| Tool                        | Start → result                                                         | Time + evidence type                                                                                               | DX choice                                       | Source                 |
| --------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- | ---------------------- |
| Playwright library, default | `chromium.launch()` → page                                             | about 1 s [observed: probes]                                                                                       | pinned build, sandbox off                       | `chromiumSandbox` docs |
| agent-browser               | `open <url>` → page                                                    | 0.32 s, then under 0.01 s per command [measured]                                                                   | native daemon; hunts for a browser              | Agent Browsers table   |
| Playwright CLI              | `open <url>` → page                                                    | 0.68 s, then 0.24 s per command [measured]                                                                         | snapshot to a file                              | Agent Browsers table   |
| This plan, consumer         | the same `chromium.launch()` → page, sandboxed, cleared env            | about 1 s plus one `exec` [estimated]; suites matched their controls' wall time through a trial wrapper [measured] | no step for the agent; the set is already there | Real suites table      |
| This plan, operator         | `scripts/playwright-browsers-deploy.sh` → `--check` OK on a fresh host | unknown; bounded by about 1.2 GB of unpacked builds [estimated], timed at phase 1 (DX-D4)                          | one command, then one check                     | Phase 1                |

Target, decided: Champion for the consumer, whose clock gains no step. The operator's first deploy is bounded by the
download and measured, not targeted.

### Magical Moment Specification

For the agent: a repo's Dependabot bump of `@playwright/test` runs its Chromium projects the same day, sandboxed, with
no dotfiles change and no download (AE3). For the operator: `--check` prints the set's version and that every alias
resolves, and any failure names one command. Both use capabilities in this plan; the vehicle is `--check` and the
aliases.

### Developer Journey Map

```text
STAGE           | DEVELOPER DOES                                   | FRICTION POINTS                                       | STATUS
----------------|--------------------------------------------------|-------------------------------------------------------|--------
1. Discover     | reads CLAUDE.md:293 and the runbook              | "repos exact-pin, bumping is a dotfiles job" goes false at phase 1 | fixed (phase 1 docs)
2. Install      | operator runs playwright-deps-deploy.sh           | none new; one entrypoint stays                        | ok
3. Hello World  | a suite or a bare launch                         | none; aliases carry every released revision           | ok
4. Real Usage   | suites, gstack, crawl4ai                         | none new                                              | ok
5. Debug        | reads an error, runs --check                     | fix commands not runnable from another repo; unloaded profile shows Chromium's text | fixed (DX-D2, DX-D3)
6. Upgrade      | operator moves the pin by hand until phase 9      | no written steps for the hashes and revisions          | fixed (phase 1 runbook)
```

### First-Time Developer Confusion Report

```text
FIRST-TIME DEVELOPER REPORT
============================
Persona: agent in a slot, task "run this repo's e2e suite", after phase 2 deploys
T+0:00  Runs the suite. Passes; renderers sandboxed, environment cleared. Nothing to read.
T+0:30  Runs a stray `bunx playwright install chromium` by habit. No-op: aliases carry the markers. (AE4)
T+1:00  (host where AppArmor did not load at boot) The launch fails.
        Before: Chromium's "No usable sandbox!" text, ending in a --no-sandbox suggestion.  → addressed by DX-D3
        After: one line naming the missing profile and `sudo ~/dotfiles/scripts/apparmor-deploy.sh` to ask for.
T+1:30  (build directory removed by hand) The wrapper's line names a deploy command.
        Before: "run scripts/playwright-browsers-deploy.sh from the dotfiles repo", not runnable from here.  → addressed by DX-D2
        After: "~/dotfiles/scripts/playwright-browsers-deploy.sh".
```

### Passes

- Pass 1, Getting Started: 8 → 8. The consumer's path gains no step, and the operator's is one command and one check.
  Residual: the first deploy's wall time is unmeasured until phase 1 (DX-D4).
- Pass 2, API/CLI: 8 → 8. `--check`, `--pin PATH`, and `--allow-downgrade` follow `scripts/sysctl-deploy.sh`'s shape;
  the shim keeps upstream's command name. The launcher's names are working names (Open Question 10).
- Pass 3, Error Messages: 4 → 8. The unloaded-profile path was a CAP4; DX-D1 to DX-D3 close the gaps below. Residual:
  Playwright's own `Executable doesn't exist` text for a consumer below the alias floor prints `npx playwright install`,
  which this plan cannot rewrite; R11 forbids it and the Mac's crawl4ai upgrade is Open Question 7.
- Pass 4, Documentation: 7 → 8. Docs ride with each phase, the reason table anchors every reason, and phase 1's runbook
  gives the by-hand pin move.
- Pass 5, Upgrade: 8 → 8. Consumers move their Playwright with no dotfiles change; the set moves with the previous build
  kept; the floor stops a move back.
- Pass 6, Dev Environment: 8 → 8. Linux and Mac share the pin; Mac branches are tested through `uname` stubs, as
  AGENTS.md requires; CI runs the real-Playwright cleanup cases (R29).
- Pass 7, Community: 3 → 3. Personal dotfiles; no community surface is in scope.
- Pass 8, DX Measurement: 6 → 7. `--check` is the standing measure; each phase's live checks are recorded in this plan;
  phase 1 times the first deploy (DX-D4).

```text
ERROR PATH MATRIX (agent-ready-v1)
Path                                   | Class      | what | fix  | recovery | code | context | trace | redaction | channel | Cap
wrapper, AppArmor profile not loaded   | dependency | fail | fail | fail     | fail | fail    | N/A   | pass      | pass    | CAP4:wrapper-apparmor:fix (Chromium suggests --no-sandbox) → DX-D3
wrapper, build missing                 | dependency | pass | fail | pass     | pass | pass    | N/A   | pass      | pass    | CAP6:wrapper:fix (not runnable outside the repo) → DX-D2
deploy, sha256 mismatch                | dependency | pass | pass | gap      | pass | pass    | N/A   | pass      | gap     | CAP6:deploy:recovery (side effects unstated) → DX-D1
unexpected: curl or unzip fails        | dependency | gap  | pass | gap      | gap  | gap     | gap   | pass      | gap     | CAP6:deploy:trace → DX-D1
pickup, lower pin on dev (phase 8)     | usage      | pass | pass | N/A      | pass | pass    | N/A   | pass      | pass    | none
```

Corrected lines, as R30 and R20 now require:

```text
ERROR: no playwright-chromium AppArmor profile is loaded, so every sandboxed launch fails; reason: apparmor-profile-not-loaded; nothing changed; next: ask the operator to run sudo ~/dotfiles/scripts/apparmor-deploy.sh
ERROR: no browser build at <path>; reason: browser-build-missing; nothing changed; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh; never run playwright install
```

Permission and safety model: the deploy refuses root and touches only `$PLAYWRIGHT_BROWSERS_PATH`; `sudo` steps are
named for the operator, never run by the user-space scripts. The wrapper and the launcher strip flags rather than ask.
No verbose mode is proposed; the browser's own `--enable-logging` still passes through.

### Decision ledger

| ID | Finding | Options | Chosen | Evidence | Accepted scope |
| -- | ------- | ------- | ------ | -------- | -------------- |
| DX-D1 | Pass 3: R30 stops short of the error contract | Add exit codes, side effects, a reason table, and pass-through stderr; leave R30 as written | Add | The user's global error contract asks for a stable reason, exit code, offending value, and next step; `sd-commit-doc` states its `state:` the same way | R30's four sub-bullets; phase 1's reason table |
| DX-D2 | Pass 3: fix commands not runnable from another repo | Name `~/dotfiles/scripts/...`; keep repo-relative paths | `~/dotfiles/` | AGENTS.md: "the dotfiles repo lives at ~/dotfiles on both" machines | R30's last sub-bullet |
| DX-D3 | Pass 3: CAP4 on an unloaded profile | The wrapper checks the profile list before `exec`; leave it to `--check` | Wrapper check | `/sys/kernel/security/apparmor/policy/profiles/` lists `playwright-chromium.47` to a plain user (measured 2026-11-05); a glob costs no subprocess | R20's last sentences; phase 2's test |
| DX-D4 | Pass 8: the operator's clock is unmeasured | Time the first deploy at phase 1's live run; no measurement | Time it | The `gtime` rule in the user's CLI tools guidance | Phase 1's Verify line |

Routine review work, no decision: phase 1's runbook gives the by-hand pin move (docs for a declared phase 1 behavior).
Outside voice: disabled (`codex_reviews`), recorded as skipped.

### NOT in scope

- A `--json` form of `--check`: no consumer reads one; the session-start host check reads unit states.
- A helper that writes a pin for a given CfT version: phase 9's job does that, and the runbook covers the by-hand move
  until then.
- Rewriting Playwright's or Chromium's own error text.
- Telemetry on agent launches, and a community surface.

### What already exists

`sd-commit-doc`'s `reason:`/`state:`/`next:` lines, `scripts/sysctl-deploy.sh --check`, the stowed scripts in
`stow/local/dot-local/bin/`, the runbook `docs/runbooks/playwright-browser-launch.md`, gstack's launch error, and
Playwright's `Executable doesn't exist` text.

### DX Implementation Checklist

```text
DX IMPLEMENTATION CHECKLIST
============================
[ ] A consumer's suite gains no step (Champion, AE1)
[ ] One command deploys a host; --check confirms it
[ ] Magical moment: a Playwright bump runs with no dotfiles change (AE3)
[ ] Every error meets R30: reason, exit code, side effects, next command runnable from anywhere
[ ] The wrapper names the missing AppArmor profile before the browser starts
[ ] The runbook's reason table lists every reason
[ ] The runbook gives the by-hand pin move
[ ] The first deploy's wall time is recorded on both machines
```

### Implementation Tasks

Carried from the earlier DX run, all still needed: DX-T1 (the shim, phase 7), DX-T2 (the launcher's last line, phase 4),
DX-T3 (the exact-pin rule in phase 1 and routing in phase 11), DX-T4 (the weekly pin proposal, phase 9, unless Open
Question 5 makes it a report).

- [ ] **DX-T5 (P1, human: ~1h / CC: ~10min)** — deploy — exit codes, side-effect wording, the runbook's reason table,
  and pass-through stderr per R30
  - Surfaced by: Pass 3 — DX-D1
  - Files: `scripts/playwright-browsers/**`, `docs/runbooks/playwright-browser-launch.md`
  - Verify: bats asserts exit 2 on usage, exit 1 with "nothing moved" on a hash mismatch, and a reason-table row per
    reason
- [ ] **DX-T6 (P1, human: ~15min / CC: ~5min)** — wrapper and launcher — `~/dotfiles/scripts/...` in every next step a
  consumer reads
  - Surfaced by: Pass 3 — DX-D2
  - Files: `scripts/playwright-browsers/**`, `stow/local/dot-local/bin/browser-launch*`
  - Verify: bats asserts the path in each line
- [ ] **DX-T7 (P1, human: ~1h / CC: ~10min)** — wrapper — the AppArmor profile check before `exec`
  - Surfaced by: Pass 3 — DX-D3
  - Files: `scripts/playwright-browsers/**`, `tests/playwright-browsers-*.bats`
  - Verify: bats against a sandbox profile directory, with and without the profile
- [ ] **DX-T8 (P2, human: ~15min / CC: ~5min)** — live — time the first deploy on both machines
  - Surfaced by: Pass 8 — DX-D4
  - Files: this plan's Other Measured Findings
  - Verify: the recorded `gtime` line

## DX Review Scorecard

```text
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      | 8/10   | 8/10   | =      |
| API/CLI/SDK          | 8/10   | 8/10   | =      |
| Error Messages       | 8/10   | 4/10   | ↑      |
| Documentation        | 8/10   | 7/10   | ↑      |
| Upgrade Path         | 8/10   | 8/10   | =      |
| Dev Environment      | 8/10   | 8/10   | =      |
| Community            | 3/10   | 3/10   | =      |
| DX Measurement       | 7/10   | 6/10   | ↑      |
+--------------------------------------------------------------------+
| TTHW                 | consumer: no added step; operator: timed at phase 1 |
| Competitive Rank     | Champion (consumer)                          |
| Magical Moment       | designed via the aliases and --check         |
| Product Type         | Platform with a CLI and guidance surface     |
| Mode                 | POLISH                                       |
| Overall DX           | 7/10   | 6/10   | ↑      |
+====================================================================+
| DX PRINCIPLE COVERAGE                                               |
| Zero Friction      | covered                                        |
| Learn by Doing     | covered                                        |
| Fight Uncertainty  | covered (R30, DX-D1 to DX-D3)                  |
| Opinionated + Escape Hatches | covered (--pin, --allow-downgrade)   |
| Code in Context    | covered                                        |
| Magical Moments    | covered                                        |
| Agents Are Users   | covered (no interactive step; fix lines run anywhere) |
+====================================================================+
```

Prior column: this review's scores for the plan as it stood at `751eacf`. Error Messages started capped at 4 by the
unloaded-profile path. Community stays at 3: no community surface is in scope. Overall stays at 7 because Playwright's
own error text for consumers below the alias floor is not this plan's to change.

Unresolved decisions from this DX review: none.

## GSTACK REVIEW REPORT

| Review         | Trigger                                                    | Why                             | Runs | Status             | Findings                                                                   |
| -------------- | ---------------------------------------------------------- | ------------------------------- | ---- | ------------------ | -------------------------------------------------------------------------- |
| CEO Review     | `/plan-ceo-review`                                         | Scope & strategy                | 0    | —                  | —                                                                          |
| Outside Review | codex, plan-eng-review and plan-devex-review outside voice | Independent 2nd opinion         | 21   | disabled           | —                                                                          |
| Eng Review     | `/plan-eng-review`                                         | Architecture & tests (required) | 13   | ISSUES OPEN (PLAN) | 43 issues, 0 critical gaps                                                 |
| Design Review  | `/plan-design-review`                                      | UI/UX gaps                      | 0    | —                  | —                                                                          |
| DX Review      | `/plan-devex-review`                                       | Developer experience gaps       | 13   | ISSUES OPEN        | score: 6/10 → 7/10, TTHW: consumer adds no step; operator timed at phase 1 |

- **OUTSIDE COVERAGE:** codex, plan-review phase, disabled by `codex_reviews` for both reviews; no findings.
- **VERDICT:** no review CLEAR yet; eng review required. Both reviews' findings are accepted into the plan as mapped
  work. A document review (`ce-doc-review`, 2026-11-05) followed them; its corrections are in the plan body, and Brett
  settled its one open item as decision 14.

NO UNRESOLVED DECISIONS
