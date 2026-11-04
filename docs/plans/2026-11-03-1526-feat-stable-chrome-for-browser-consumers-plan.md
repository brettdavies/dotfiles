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
- **Means:** One CfT build (full and headless shell), one ffmpeg, and the one WebKit build agentnative-site's suite
  uses, aliased for the Playwright revisions consumers ask for, behind a wrapper at the alias path that drops the
  sandbox-off flags and clears the environment. A hardened launcher over Chrome, driven by a pinned agent-browser
  without its skill. One Playwright library version across our repos, a check for drift from it, and a check for
  browsers outside the set.
- **Brett's direction (verbatim):** "let's harden a single system playwright and tests. We update it separately from any
  repo. repo's use what's available on the system, not their own preferences. gstack, etc incl"; "also need to ensure
  that our two browsers chrome and cft are updated often."; "to limit the number of browsers we have and also highly
  control which browsers different tools use through direct config and ENV VARs". His answers are in Settled Decisions.
- **Product authority:** Requirements govern behavior and Key Decisions record why. The measurements in this plan are
  the evidence. Where a solutions doc or runbook disagrees with a measurement here, the doc is what gets rewritten.
- **Open blockers:** None. PR #431 is merged and deployed, and `--check` exits 0, so phase 1 can start. One question for
  Brett remains, and no phase waits on it (Settled Decisions).
- **Execution profile:** User-space provisioning, shell config, a launcher, an alias wrapper, a stowed shim, doc
  updates, and hourly update jobs. Chrome adds a system package and an apt timer that the operator applies, because the
  agent's settings deny `sudo`. Proof is runtime measurement on both machines. bats covers the script seams.
- **Stop conditions:** Stop and bring the finding to Brett if a real suite fails on a candidate CfT build where it
  passes on the set's current build, if the launcher or wrapper breaks a consumer's pipe connection, or if any browser
  behind them runs a renderer without its own user and PID namespaces on the Linux server, or without Chrome's seatbelt
  switch on the Mac.
- **Who finishes:** `ce-plan` enriches this file in place. The operator runs every `/etc` step. Brett files the gstack
  issue, which is drafted and pending with him.

---

## Product Contract

### Summary

Two browsers, one owner. CfT serves tests, gstack with its headed sessions, crawl4ai, and scripts. Google Chrome stable,
behind a hardened launcher and driven by a pinned agent-browser, serves agents on pages nobody vetted. WebKit stays
beside them because agentnative-site's `mobile-ios`, `tablet`, and `web-audit-webkit` projects use it, and no other repo
in scope does. dotfiles names every version once, points every consumer at them, turns every download off, and reports
anything else it finds on a host.

The per-Playwright-version browser map goes. One CfT build, one WebKit build, and one ffmpeg are aliased for what a
consumer at Playwright 1.57 or later can ask for. Chromium and ffmpeg alias in both directions. WebKit aliases only at
or below the set's build, because a newer Playwright fails on an older WebKit (measured). Consumers at 1.56 or earlier
need `executablePath` or an upgrade. Every alias's executable is a wrapper that drops the sandbox-off flags and clears
the environment, so a bare `chromium.launch()` runs sandboxed with no secrets in the browser.

Both browsers stay current without a person. An hourly job takes each new Chrome stable release's CfT build through the
real suites and moves the pin, and hosts pick it up within the hour. Chrome updates from Google's apt repository on an
hourly timer. Browser builds are exempt from the seven-day gate; agent-browser and the Playwright library stay under it.
Our repos share one Playwright library version named in dotfiles, while gstack and crawl4ai keep the versions they ship
and run the system browsers. Browser updates never wait on the library pin. CI is unchanged.

### Problem Frame

The Linux server runs its browser consumers on CfT builds that Playwright pins. The canonical set carries CfT
151.0.7922.34 for Playwright 1.61.1 and 1.62.1; gstack and crawl4ai add their own 156.0.8078.4. Three things follow.

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
  with `Protocol error (Page.overrideSetting): Unknown setting: PushAPIEnabled` and hit the run's 280 s limit. So the
  set's WebKit must be at least as new as the newest Playwright that uses it.
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

| Consumer                               | Browser                        | How it is pointed                                                            | Who updates the browser                                |
| -------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------ |
| e2e suites, locally                    | System CfT through the wrapper | `PLAYWRIGHT_BROWSERS_PATH`                                                   | Hourly job, gated on the suites (R4)                   |
| e2e suites, CI                         | Each repo's own pinned build   | The repo's workflow                                                          | Unchanged                                              |
| gstack, headless and headed            | System CfT through the wrapper | `GSTACK_CHROMIUM_PATH`; `PLAYWRIGHT_BROWSERS_PATH` for its probes            | Same hourly job                                        |
| crawl4ai                               | System CfT through the wrapper | `PLAYWRIGHT_BROWSERS_PATH`; `~/.crawl4ai/chromium.path` for its managed mode | Same hourly job                                        |
| Bare Playwright scripts                | System CfT through the wrapper | `PLAYWRIGHT_BROWSERS_PATH`                                                   | Same hourly job                                        |
| Puppeteer, Lighthouse, chrome-launcher | System CfT through the wrapper | `PUPPETEER_EXECUTABLE_PATH`, `CHROME_PATH`                                   | Same hourly job                                        |
| agent-browser, on pages nobody vetted  | Chrome through the launcher    | The shim sets `AGENT_BROWSER_EXECUTABLE_PATH`                                | Hourly apt timer on Linux; Google's updater on the Mac |

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
- **`--ignore-https-errors`, which the launcher cannot strip:** the shim refuses it.
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

| Consumer                                                            | Machine                         | Pages it opens                                                      | Browser today                            | Sandbox today                               | Under this plan                                                                                                                                                         |
| ------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gstack browse (`/browse`, `/qa`, `/scrape`, handoff, cookie import) | Linux, 1.94.33.0                | Arbitrary URLs, credentialed sessions too                           | CfT 156.0.8078.4                         | On, through the dotfiles AppArmor profile   | System CfT through the wrapper, sandbox on, clean environment (R6, R20); no CRLSet or Safe Browsing on its headless path unless Brett's open question moves its pointer |
| gstack browse, headed                                               | Mac, 1.93.42.0                  | Same; its skill prefers Aside there                                 | CfT 151.0.7922.34                        | On                                          | System CfT through the wrapper, side panel works (R6), moving within hours of a stable release (R4)                                                                     |
| crawl4ai CLI and skill scripts                                      | Linux, 0.9.5                    | Arbitrary sites                                                     | CfT 156.0.8078.4                         | Off unless `CRAWL4AI_CHROMIUM_SANDBOX=true` | System CfT through the wrapper, sandbox on, clean environment, certificate checks on for covered callers; no CRLSet or Safe Browsing (R7)                               |
| crawl4ai CLI                                                        | Mac, 0.7.7 on Playwright 1.56.0 | Arbitrary sites                                                     | None found in the cache for 1.56.0       | Off                                         | Moves to a release at or above 0.9.5, then as Linux, with the same limit (R7)                                                                                           |
| Agent CLI, new                                                      | Both                            | Arbitrary sites                                                     | Not installed                            | n/a                                         | agent-browser at a pinned version, through the launcher over Chrome (R9, R10)                                                                                           |
| Ad hoc agent scripts                                                | Both                            | Arbitrary sites                                                     | Default pinned build with `--no-sandbox` | Off                                         | System CfT through the wrapper, sandboxed with a clean environment (R20); the guidance routes untrusted pages to agent-browser (R11)                                    |
| Puppeteer downloads in `~/.cache/puppeteer`                         | Linux                           | No consumer identified; agent-browser's auto-detect would find them | CfT 133.0.6943.141, 150.0.7871.24        | Unknown                                     | Removed; `PUPPETEER_EXECUTABLE_PATH` names the set and downloads are off (R22, R23)                                                                                     |
| Codex browser plugin, Cursor `browser-tools-mcp@1.2.0`              | Mac                             | Arbitrary sites                                                     | Mac's Chrome                             | On                                          | Unchanged                                                                                                                                                               |
| e2e suites: lmgroktfy, agentnative-site, meum-sites, streamsgrp     | Linux                           | Own builds and own staging                                          | CfT 151 locally; CfT 149 in CI           | Off                                         | System CfT through the wrapper (R5, R20); CI unchanged                                                                                                                  |
| Lighthouse CI (agentnative-site, meum-sites)                        | Linux                           | Own site                                                            | Cannot launch locally                    | Off by config                               | `CHROME_PATH` names the set (R22)                                                                                                                                       |

### Key Decisions

- **One physical build, aliased per revision.** The set holds one CfT build, its headless shell, one WebKit, and one
  ffmpeg. Revisions a consumer asks for resolve to them. Real suites at 1.61.1 and 1.64.1 passed as they do on their
  pins, and the alias mechanism is already live for 1228. Governs R1, R2, R5, R6, R7.
- **Chromium and ffmpeg aliases run ahead; WebKit's do not.** A forward range of symlinks serves a revision that does
  not exist yet, so a repo that moves its library still runs on Chromium the day it moves. A forward WebKit alias would
  fail on every `newPage` (measured), so WebKit's pin follows the newest Playwright release, and older libraries run on
  it (measured). Governs R2, R4.
- **The version is pinned in the repo, and a job moves it.** Machines run the same dotfiles version, so the pin belongs
  in dotfiles. The job follows the bump pattern in `docs/plans/2026-11-02-2155-feat-yazi-plugin-auto-bump-plan.md`,
  including its squash-merge without a person, because the suites are the gate. Hosts read the pin from `origin/dev`
  rather than their checkout, so a pin reaches a host within the hour on any branch. Governs R4.
- **The bump records a hash.** CfT publishes none, so the bump writes the sha256 of each archive it verified into the
  pin, and hosts check against it. Governs R3, R4.
- **Every browser build is exempt from the seven-day gate.** The gate's threat, a malicious upload to an open registry,
  does not match a vendor-signed repository or Google's own bucket, and the regressions a week of bake time would
  surface are what the suite run catches. Google's apt index serves only the newest build, so holding Chrome back would
  mean mirroring old debs. agent-browser and the Playwright library are npm packages and stay under the gate. Governs
  R4, R10, R13, R21.
- **Tests and untrusted browsing get separate browsers.** Reproducibility and security pull a browser's update cadence
  in opposite directions. Governs R4, R9, R13.
- **gstack runs on CfT in every session.** The side panel needs `--load-extension`, which CfT honors and Chrome blocks
  (measured), and one browser for gstack keeps one pointer. gstack browse also opens arbitrary URLs and credentialed
  sessions, so it inherits Google's statement about CfT, and on its headless path it gets no CRLSet or Safe Browsing
  unless the open question below moves its pointer. Governs R6.
- **Two layers of hardening.** The alias wrapper (R20) gives every launch through the set the sandbox and a clean
  environment. The launcher (R9) adds what only untrusted pages want: CRLSet, Safe Browsing, and certificate checks that
  no flag can turn off. Condition 2 stays with the AppArmor deploy. Governs R9, R20.
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

### Requirements

**System browser set**

- R1. Each host that deploys it, the Linux server and the Mac alike, holds exactly one CfT build (full and headless
  shell), one WebKit build, and ffmpeg in `$PLAYWRIGHT_BROWSERS_PATH`, at versions named once in dotfiles. WebKit is
  there for agentnative-site's `mobile-ios`, `tablet`, and `web-audit-webkit` projects, and leaves the pin when no
  repo's suite uses it.
- R2. Every Chromium and ffmpeg revision a consumer at Playwright 1.57 or later asks for resolves to the set through an
  alias, including revisions newer than the set. WebKit revisions alias only at or below the set's WebKit. Each alias
  directory carries the install markers.
- R3. `playwright install` naming browsers in the set, from any consumer, is a no-op and deletes nothing. A deploy
  replaces a real directory found at an alias name, which `--force` installs create, with the alias. `--check` fails
  with a stable reason on such a directory and on any browser directory the pin does not name, such as the `firefox-*` a
  bare `playwright install` downloads. The set survives a consumer's cleanup through one `.links` client per aliased
  revision, numeric names on its real directories (cleanup parses revisions as integers), and
  `PLAYWRIGHT_SKIP_BROWSER_GC` as a second layer. Provisioning verifies each archive against its recorded sha256 and
  keeps the `curl` plus `unzip` path, because node's extractor deadlocks on this kernel.
- R4. dotfiles moves the set on its own schedule with no repo involved, exempt from the seven-day gate. An hourly user
  timer on the Linux server reads CfT's Stable channel and exits when it matches the pin. On a new version it runs the
  candidate and the current build through lmgroktfy, meum-sites, agentnative-site, and gstack's browse tests, about 11
  minutes in all (measured per suite). It moves the pin only when both arms produce a per-test report for every suite,
  with a test count at or above the current arm's, and the set of passing tests does not shrink. A missing report counts
  as failure, and a test failing only on the candidate is rerun once before it counts. A failure leaves the pin alone
  and names the suite, and the next run retries only on a newer version. It also loads an extension on the candidate, so
  a dropped `--load-extension` stops the move. WebKit and ffmpeg revisions come from `browsers.json` of the newest
  Playwright release. A move is a PR to `dev` that squash-merges itself once CI is green. Each host runs an hourly timer
  (a LaunchAgent on the Mac) that reads the pin from `origin/dev`, provisions what differs, launches the new build
  through Playwright with its sandbox on and loads a page, and on the Mac also loads gstack's side panel extension. A
  failure leaves the aliases alone and fails the check. A deploy flips aliases atomically and keeps the previous build
  until the next deploy. A check that changes nothing fails when a host's set differs from the pin for more than two
  cycles, or when the pin trails CfT Stable by more than a day with no recorded suite failure, names the fix command,
  and carries a stable reason and the values it compared.
- R20. Every alias's Chromium executable is a small wrapper, in one numeric directory the aliases point at, that drops
  only `--no-sandbox` and `--disable-setuid-sandbox`, keeps them when running as root, clears the environment as R9
  does, and `exec`s the real build at its AppArmor-covered path. The same wrapper is reachable at one path that does not
  move with the pin, under `$PLAYWRIGHT_BROWSERS_PATH/.dotfiles/`, which the cleanup never counts as a browser
  directory, for consumers that take an explicit path. `--check` fails when the AppArmor profile is not loaded, because
  every Playwright launch then fails.

**Consumers**

- R5. Each e2e suite runs locally on the set with no change to its Playwright config. CI is unchanged: each repo's
  workflow runs `playwright install` for its own pinned build.
- R6. gstack, headless and headed, runs on CfT. Its install probes resolve through the alias. `GSTACK_CHROMIUM_PATH`
  points its launches at the set's stable path (R20), exported only when that path is executable, because gstack throws
  on a failed launch. Its headed sessions load the side panel. gstack keeps the Playwright version it ships.
- R7. crawl4ai runs on CfT and keeps the Playwright version it ships. Its Playwright mode resolves through the alias,
  and the deploy writes `~/.crawl4ai/chromium.path` to the stable path for its managed mode.
  `CRAWL4AI_CHROMIUM_SANDBOX=true` is exported wherever the sandbox can work. Covered callers set `ignore_https_errors`
  off. crawl4ai meets hardened conditions 1, 2, 5, and 6 and not 3 or 4: its Playwright mode adds
  `--disable-component-update` itself and takes no executable path, so only the wrapper runs for it, and a short crawl
  would outrun a CRLSet regardless.
- R8. No launch through the set passes `--no-sandbox` (R20), and no consumer dotfiles configures does, on either
  machine, outside a context where the sandbox cannot work (root, a container, CI).

**Agent browsing**

- R9. A dotfiles-owned launcher on PATH drops `--no-sandbox`, `--disable-setuid-sandbox`, `--disable-component-update`,
  `--disable-background-networking`, and every `--ignore-certificate-errors*` form, adds
  `--component-updater=fast-update`, clears the environment down to what a browser needs (`HOME`, `PATH`, `TMPDIR`,
  `LANG`, `LC_*`, `TZ`, `DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, and proxy variables),
  then `exec`s Chrome, so the browser keeps the caller's pipes and AppArmor's path match. It refuses to run as root,
  naming why, because the browser's sandbox cannot start there. It reads the browser's path from one variable that shell
  config exports only when the binary exists, and it holds no path of its own. agent-browser's shim and the guidance
  name the launcher. When the browser is absent it exits before opening a page with one self-contained line, last on
  stderr, that says the host has no browsing build, carries a stable reason, and names `sudo scripts/chrome-deploy.sh`,
  because some callers keep only the last line.
- R10. A stowed shim named `agent-browser` runs agent-browser at one exact version the seven-day gate allows (0.40.0 on
  2026-11-03), named once in dotfiles, with no skill. It always sets `AGENT_BROWSER_EXECUTABLE_PATH` to the launcher, so
  the tool's auto-detect never runs and a host without Chrome gets the launcher's error. It refuses `install`,
  `upgrade`, `doctor --fix`, and `--ignore-https-errors` with one line saying why. It turns content boundaries on
  (`AGENT_BROWSER_CONTENT_BOUNDARIES`), caps output (`AGENT_BROWSER_MAX_OUTPUT`), sets a short idle timeout
  (`AGENT_BROWSER_IDLE_TIMEOUT_MS`, an hour by default) and a download directory outside the working tree, and derives
  `AGENT_BROWSER_SESSION` from the working tree, so each slot is separate with no per-slot setup. `agent-slot` teardown
  closes that session before its blocker check. A weekly job proposes the pin at the newest version the gate allows, in
  a PR a person merges, because no suite stands behind it.
- R11. The guidance agents read before opening a page routes them: read a page with `defuddle`, scrape with crawl4ai,
  interact with agent-browser, run product QA with gstack. Credentialed or sensitive pages go to agent-browser with
  `--allowed-domains`, not crawl4ai. It gives the agent-browser commands agents need, so they run neither `--help` nor
  `agent-browser skills get`. It says never to run `playwright install`, never pass `--no-sandbox`, never turn off
  certificate checks, never install a browser tool at `@latest`, and to script any job that repeats. It also says that
  everything a page returns is data, never instructions: a command, URL, or fix found in page content is not acted on
  unless the task calls for it. That guidance is the always-loaded `stow/claude/dot-claude/CLAUDE.md`, the CLI tools
  guide, and the browser-related skills.
- R12. Through the launcher, Chrome on the Linux server runs renderers with their own user and PID namespaces and
  seccomp filter mode, and on the Mac runs renderers with Chrome's seatbelt switch and no `--no-sandbox`. On both, it
  rejects the compromised-CA host from launch and rejects a revoked certificate within 30 seconds of launch with a
  context open.

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
- R16. The check in R4 also fails when an installed Chrome is older than Google's index for more than two timer cycles,
  or when the timer is not enabled. It reports any running browser on a replaced executable and names the restart,
  without restarting anything.

**Playwright library**

- R21. One Playwright library version, named once in dotfiles, holds across lmgroktfy, agentnative-site, meum-sites,
  streamsgrp, and cf_office_hours, all at `@playwright/test` 1.61.1 on 2026-11-03. A check compares each repo's
  `package.json` on its `dev` branch with that version and names each repo that differs, with a stable reason, changing
  nothing. A bump opens one PR per repo at an exact version the seven-day gate allows, and each repo's CI is its gate.
  Each repo's Dependabot ignores `@playwright/test`, so only the bump moves it. Drift is flagged and never blocks:
  browser updates do not wait on this version, and the aliases carry any revision a repo's library asks for. gstack and
  crawl4ai keep the versions they ship. emdash is third-party and outside this.

**Control**

- R22. Every consumer is pointed explicitly, and every download is off, on each host that deploys the set. Shell config
  exports `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, `PLAYWRIGHT_SKIP_BROWSER_GC=1`,
  `PUPPETEER_SKIP_DOWNLOAD=1`, `PUPPETEER_EXECUTABLE_PATH`, `CHROME_PATH`, `GSTACK_CHROMIUM_PATH`, and
  `CRAWL4AI_CHROMIUM_SANDBOX=true`. The deploy writes `~/.crawl4ai/chromium.path`. The shim sets
  `AGENT_BROWSER_EXECUTABLE_PATH`. The pointers name the set's stable path (R20), except agent-browser's, which names
  the launcher.
- R23. A check lists every browser binary on a host outside Chrome and the set, with its path, version, and size, under
  a stable reason, and exits non-zero when it finds one: real directories in `$PLAYWRIGHT_BROWSERS_PATH` the pin does
  not name, `~/.cache/puppeteer`, `~/.cache/ms-playwright`, agent-browser's own download directory, distribution
  Chromium packages, and their Mac equivalents. It removes nothing unless asked with `--remove`. A list in dotfiles
  exempts what is not a browser consumer, such as Electron apps and the GStack Browser app, each with a reason.

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
- AE3. **Covers R2, R21.** **Given** a repo moves `@playwright/test` to a release newer than the set's last deploy,
  **when** its Chromium projects run, **then** they run on the set, ffmpeg included, with no dotfiles change and no
  download, and the check in R21 names that repo. **When** its WebKit projects run before the set's WebKit has moved,
  **then** they fail with `Executable doesn't exist`, and not with a protocol error midway through a run.
- AE4. **Covers R3.** **Given** another tool at any Playwright version runs `playwright install chromium`, **when** it
  finishes, **then** the set is intact and nothing downloaded, no `ffmpeg-*` included. **Given** a `--force` install
  replaced an alias with a real directory, **when** the next deploy runs, **then** the alias is back, and until then
  `--check` fails naming the directory. **Given** an archive whose hash differs from the pin, **when** provisioning
  runs, **then** it stops, names both hashes, and leaves the existing set in place.
- AE5. **Covers R4.** **Given** a candidate CfT build that fails a test a current run passes, or a suite that produces
  no per-test report, **when** the job runs, **then** the pin does not move and the job names the suite. **Given** a
  candidate-only failure that passes on rerun, **then** the move proceeds. **Given** CfT Stable matches the pin,
  **when** the hourly timer fires, **then** it exits after one fetch and runs no suite.
- AE6. **Covers R6.** **Given** the set is deployed, **when** `gstack-browser-ensure` runs, **then** it prints
  `BROWSER_OK` with the set's version and fetches nothing.
- AE7. **Covers R7, R8.** **Given** crawl4ai under the shell's defaults, **when** it crawls a page, **then** its
  browser's command line carries no `--no-sandbox` and a token planted in the caller's environment is absent from the
  browser's. **When** a covered caller crawls `https://expired.badssl.com/`, **then** the crawl fails with a certificate
  error. **When** it crawls `https://revoked.badssl.com/`, **then** the result is recorded as this path's known limit.
- AE8. **Covers R9, R12.** **Given** the launcher and Chrome are installed on either machine, **when** a Playwright
  launch sets its executable to the launcher, **then** renderers are sandboxed as R12 states,
  `dv-g3b-emudhra.we-have-a-problem.com` fails at once, `revoked.badssl.com` fails within 30 seconds, and a token
  planted in the caller's environment is absent from the browser's main process's `/proc/<pid>/environ` on Linux.
- AE9. **Covers R9, R10.** **Given** a host without Chrome, **when** an agent runs `agent-browser open <url>`, **then**
  it exits before opening any page, names the deploy command, and never suggests `agent-browser install`.
- AE10. **Covers R10.** **Given** two agents on one host, **when** each opens a page through agent-browser, **then**
  neither sees the other's tabs, neither working tree gains a file, and page output carries boundary markers.
- AE11. **Covers R13, R16.** **Given** Google publishes a new stable build, **when** the host's next timer run
  completes, **then** the installed version matches it. **Given** the timer is disabled, **when** the check runs after a
  newer build has been in the index for two cycles, **then** it exits non-zero with a stable reason, the versions it
  compared, and the deploy command.
- AE12. **Covers R16.** **Given** an agent-browser daemon started before the timer replaced Chrome, **when** the check
  runs, **then** it names that process and the restart command.
- AE13. **Covers R10.** **Given** a slot's agent used agent-browser and left its session open, **when** the slot tears
  down, **then** `agent-slot check` reports no `agent-state-unknown` blocker from the tool's daemon.
- AE14. **Covers R20.** **Given** the set is deployed, **when** a script calls bare `chromium.launch()`, **then** the
  browser process carries no `--no-sandbox`, renderers are sandboxed, and a planted token is absent from its
  environment.
- AE15. **Covers R10.** **Given** the shim, **when** an agent runs `agent-browser install`, `agent-browser upgrade`,
  `agent-browser doctor --fix`, or passes `--ignore-https-errors`, **then** it refuses with one line and downloads
  nothing.
- AE16. **Covers R21.** **Given** one repo's `package.json` differs from the dotfiles version, **when** the check runs,
  **then** it exits non-zero naming that repo and both versions, and no browser update is held back.
- AE17. **Covers R22, R23.** **Given** a tool downloaded a browser into `~/.cache/puppeteer`, **when** the check runs,
  **then** it exits non-zero listing the path, version, and size, and removes nothing. **Given** `--remove`, **then** it
  deletes what it listed and nothing exempted.

### What Happens to the Pinned-Browser Machinery

| Item                                                                                                  | Today                                                 | Under this plan                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/playwright-browsers-deploy.sh`                                                               | A revision map per Playwright version                 | One pin (CfT version, WebKit revision, ffmpeg revision, hashes) and an alias range; no per-version map                                                              |
| `CONSUMER_CHROMIUM_REVS`                                                                              | Hand-kept list, 1223 and 1228                         | Replaced by the range                                                                                                                                               |
| PR #431's `.links` registration and `--check`                                                         | Registers the whole set                               | Kept and extended to the alias range; `--check` grows into R4's check                                                                                               |
| gstack's own `playwright install chromium`                                                            | Fetches 1248 when its probe fails                     | Never fires: its probe passes on the alias                                                                                                                          |
| `chromium-1248`, its headless shell, `webkit-2311`, `ffmpeg-1013`                                     | Real directories from other installs                  | Replaced by aliases, or removed once nothing asks for them (R3, R23)                                                                                                |
| `~/.cache/puppeteer`                                                                                  | 929 MB; CfT 133 and 150; no consumer identified       | Removed, with `PUPPETEER_EXECUTABLE_PATH` and `PUPPETEER_SKIP_DOWNLOAD` set (R22, R23)                                                                              |
| `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`                                        | One shared cache; no auto-download on `bun install`   | Both stay; `PLAYWRIGHT_SKIP_BROWSER_GC` and the other pointers join them (R22)                                                                                      |
| `config/apparmor.d/playwright`, `apparmor-playwright.service`                                         | Grant `userns` to `chromium-*` and the headless shell | Stay: the glob covers the set's directories and aliases, and every launch now depends on them                                                                       |
| `scripts/playwright-deps-deploy.sh`                                                                   | Binaries, AppArmor, opt-in apt deps                   | Keeps its role. Its `--chromium` flag, which runs `bun x playwright install --with-deps chromium` and downloads a browser, is replaced by installing the deps alone |
| `docs/solutions/tooling-decisions/browsing-agents-run-stable-chrome-not-a-playwright-pinned-build.md` | Holds the launch-flag measurements                    | Stays, updated with what ships                                                                                                                                      |

### Scope Boundaries

- Chrome stable is never the test suites' browser. It moves on Google's schedule, which is the drift the set exists to
  prevent, and it has no headless shell.
- CI does not join the set. Each repo's workflow keeps installing its own pinned build.
- Firefox is not in the set; no consumer launches it.
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

### Dependencies / Assumptions

- **The provisioning work builds on PR #431, merged to `dev` and deployed.** It holds the `.links` registration, the
  deploy script's `--check`, and `tests/playwright-browsers-deploy.bats`.
- **gstack upstream.** A gstack issue draft (its probes ignore `GSTACK_CHROMIUM_PATH`; its install deletes other tools'
  browsers) is pending with Brett. The alias removes this plan's dependence on the first half, and `.links` with
  `PLAYWRIGHT_SKIP_BROWSER_GC` covers the second.
- **Aliasing depends on Playwright's layout.** A Playwright that moves its executable path breaks the alias for that
  release. `--check` and the job's suite run catch it before machines pull it.
- **CfT keeps publishing a headless shell and Stable channel data.** Both come from Google's public JSON API.
- **WebKit evidence comes from one project set.** agentnative-site's flows are the only WebKit consumer, and older
  Playwright on the pinned WebKit passed there. A failure drops back to one real WebKit directory per revision for that
  release, the one place the set might grow.
- **Ubuntu keeps shipping its `chrome` AppArmor profile.** If a later release drops it, Google's deb installs its own.
- **Removing `--disable-background-networking` lets Chrome reach Google's services in the background.** That is the
  price of Safe Browsing, and it applies only behind the launcher.

### Settled Decisions

Brett answered these on 2026-11-03, relayed by the coordinating session `dotfiles-prime`. Quoted words are Brett's as
relayed; the rest is the relay's wording.

| # | Question                            | Answer                                                                                                                                                                                                                                                                                                   | Sets            |
| - | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| 1 | What agents browse with             | Regular Chrome stable from Google's apt repository, behind the hardened launcher. CfT serves tests, gstack with its headed sessions, crawl4ai, and scripts.                                                                                                                                              | R6, R7, R9, R13 |
| 2 | Which tool drives it                | agent-browser without its skill. Brett asked "Why not vercel agent-browser?". Pinned under the seven-day gate, its path set to the Chrome install, with any download or auto-detect off.                                                                                                                 | R10, R11        |
| 3 | The seven-day gate                  | Every browser build is exempt, and "also need to ensure that our two browsers chrome and cft are updated often." CfT follows each Chrome stable release once the suites pass. Chrome updates at least daily. The agent CLI stays under the gate.                                                         | R4, R13         |
| 4 | Whether CI joins the set            | CI is unchanged.                                                                                                                                                                                                                                                                                         | R5              |
| 5 | Whether bare launches run sandboxed | Yes: every alias executable becomes the wrapper that drops the sandbox-off flags and clears the environment.                                                                                                                                                                                             | R8, R20         |
| 6 | How many browsers                   | Two, Chrome and CfT. WebKit stays only if a repo's suite uses it, and ffmpeg stays as it is. agentnative-site's `mobile-ios` and `tablet` projects and `web-audit-webkit`, which its release preflight runs locally, use WebKit; no other repo in scope does.                                            | R1              |
| 7 | The Playwright library              | One pinned version across our repos, set in one place in dotfiles, with a check that flags drift and bumps them together. gstack and crawl4ai keep what they ship. Brett: "I'm not sure how that affects a pin. it is ok if the pin becomes dirty or is otherwise ignored after an initial commit, etc." | R21             |
| 8 | Control                             | Brett wants "to limit the number of browsers we have and also highly control which browsers different tools use through direct config and ENV VARs". Every consumer is pointed explicitly, every download is off, and a check lists any browser outside the two.                                         | R22, R23        |

On decision 7, the relay reads Brett's sentence as: browser updates never wait on the library pin, and the aliases carry
any revision a pinned library asks for. R21 follows that reading.

**Interval, set here:** hourly for both browsers, which meets "at least daily" for Chrome. The reasoning is in The
Split.

**Open for Brett, blocking nothing:**

- **Where does `GSTACK_CHROMIUM_PATH` point?** (a) The alias wrapper, which gives gstack the sandbox and a clean
  environment. (b) The launcher, with CfT as its target, which adds CRLSet and Safe Browsing on gstack's headless path.
  Recommendation: (b). gstack browse opens arbitrary URLs and credentialed sessions, the launcher over CfT was measured
  rejecting a revoked host (not yet under gstack), and it costs a second launcher target. R6 specifies (a) until he
  answers, because it follows decisions 1 and 5 as given.

### Build Phases

Each phase ends in a merged PR to `dev`, except phase 2, which is measurement, and the operator's `sudo` step in
phase 4.

1. **System set.** One pin, the alias range, per-alias `.links` clients, numeric real directories, macOS archives,
   sha256, atomic flip, and `--check` (R1, R2, R3). CfT moves to current stable here, which ends the stale builds.
2. **First execution gate.** After the first deploy, on both machines: does CfT at its real path start with its sandbox
   on, and through the wrapper? Does gstack's side panel load through the wrapper on the Mac? Does a sandboxed browser
   keep working with its directory removed, which A2 measured only unsandboxed? A failure takes the Goal Capsule's stop
   condition.
3. **Wrapper and control.** The alias wrapper and stable path (R20), every pointer and download switch (R22), the
   consumer moves (R5, R6, R7, R8), and the inventory check (R23), then removal of what it lists.
4. **Chrome and agent browsing.** `scripts/chrome-deploy.sh` and its timer (R13, R14, R15, R16), the launcher (R9, R12),
   the agent-browser shim (R10), and session close at slot teardown. The operator runs the deploy.
5. **Keeping current.** The hourly CfT job and each host's pickup (R4), with the weekly agent-browser pin proposal
   (R10).
6. **Library.** The dotfiles version, its check, the bump, and each repo's Dependabot ignore (R21). Start at 1.61.1,
   which all five repos hold, then take the first bump through it.
7. **Docs.** Guidance and runbooks (R11, R19), once the behavior they describe exists.

Phases 1, 2, 3, and 5 run in that order. Phase 4 can run alongside phase 3 once phase 2 passes. Phase 6 needs only phase

1. `config/shell/` is shared, so phase 3's shell change merges first.

### Deferred to Planning

- Who runs the library check and where a failure shows: the repo already surfaces host checks at session start
  (`failed-user-units.sh`), silent when they pass. The same question covers R4's, R16's, and R23's checks.
- Whether crawl4ai's managed-browser mode, with `~/.crawl4ai/chromium.path` at the launcher, closes its limit in R7 for
  long-lived sessions. It is unmeasured, and it costs a setting per caller.
- The Chrome deploy uses the paths the deb's cron job maintains, `/etc/apt/sources.list.d/google-chrome.sources` and
  `/usr/share/keyrings/google-chrome.gpg`, so apt never sees the repository configured twice.
- The alias range's bounds. A forward range for Chromium and ffmpeg, plus WebKit up to the pin, is several hundred
  symlinks and as many `.links` clients.
- Which crawl4ai callers dotfiles configures: the crawl4ai skill's scripts and browser template, `crwl` through `-b` or
  `-B`, and each importing repo such as scrawl2. crawl4ai's CLI result on an expired certificate was inconclusive here:
  both settings ended in the same `NoneType` error, so AE7 measures it properly.
- The names Puppeteer reads for skipping each browser's download, checked against the version in use, and whether R22
  needs more than `PUPPETEER_SKIP_DOWNLOAD`.
- agent-browser's values for output cap and idle timeout, and whether its daemon keeps the slot as its working directory
  as the Playwright CLI's does (AE13 measures it).
- The Mac's crawl4ai moves from 0.7.7 to a release at or above 0.9.5, and planning lists each importing repo's version.
- Whether `apparmor.service` runs on every boot of this host or only some, which decides how much the setuid fallback
  matters.

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
- Consumer repos at their `dev` tips on 2026-11-03: lmgroktfy 02ac676, agentnative-site 8777e6a, meum-sites 5d15fb1,
  streamsgrp 2fb7cf4.

---

## Appendix

These reviews are the record of what each one examined. Where one names Option A or B, a numbered question, the
Playwright CLI as the agent tool, or a weekly browser bump, Settled Decisions and the Requirements govern.

### Engineering Review (plan-eng-review, 2026-11-03)

The review ran unattended in an agent slot, with no question tool. Each choice below was auto-decided on its
recommendation, under the slot's standing instruction to settle review questions from code, docs, and precedent and
record them here. Brett's decisions are recorded separately in Settled Decisions. Evidence kinds: `coreBundle.js`,
`scripts/`, and #431 are static reads; the Measured sections of the plan are live runs in scratch directories. Proposed
files are proposals, and no product code ran.

#### Scope Challenge

- **What already exists:** the alias mechanism (`link_consumer_alias`,
  `scripts/playwright-browsers-deploy.sh:365`); #431's per-alias `.links` clients and `--check`; the copy-deploy shape
  with `--check` and `--dest` (`scripts/sysctl-deploy.sh`, `tests/sysctl-deploy.bats`); the deleted-executable scan in
  `scripts/upgrade/lib/stale-procs.sh`; the browser environment in `config/shell/caches.sh`; the dotfiles AppArmor glob;
  Google's deb and Ubuntu's `chrome` profile; unattended-upgrade's `Origins-Pattern`; Playwright's `PLAYWRIGHT_MCP_*`
  environment and `PLAYWRIGHT_SKIP_BROWSER_GC`; gstack's `GSTACK_CHROMIUM_PATH`; crawl4ai's `CRAWL4AI_CHROMIUM_SANDBOX`;
  session-start host checks (`failed-user-units.sh`); the auto-bump plan's PR pattern.
- **Minimum change:** rewrite the deploy script around one pin, add one launcher and one shell block, export three
  variables. Everything else is optional or conditional on Brett's answers.
- **Complexity:** about 20 dotfiles files [estimated]: deploy script, deps script, pin file, `config/shell/caches.sh`,
  launcher, launcher bats, deploy bats, shell-config bats, bump script, user timer and service, LaunchAgent,
  `CLAUDE.md`, `cli-tools.md`, runbook, supply-chain guide, crawl4ai skill. Option A adds a Chrome deploy script, two
  apt drop-ins, and a bats suite. No classes or services in the code sense. The 8-file gate trips.
- **Search:** primary sources were fetched directly (Chromium docs, Chrome Releases, chromiumdash, npm, GitHub
  advisories, Playwright docs, the benchmark). Aside is not available on this Linux host. A vendor apt repository is the
  standard path [Layer 1]. Aliasing every revision to one build is a departure from Playwright's own stance ("use at
  your own risk") [Layer 3], justified by the drift table and gated by the real-suite bump.
- **TODOS:** the repo has no tracked TODOS file; local TODO files are gitignored by policy.
- **Distribution:** nothing is published. The bump job opens PRs; hosts pull the pin. Target OS and architecture:
  linux64 and mac-arm64, both published by CfT (measured URLs).
- **Complexity selectors (auto-decided):** no feature cuts, because Option-specific work is already conditional.
  Structure: the smaller arrangement (D1).
- **Scope result:** scope accepted as-is.

Scope findings:

- S1. [INFORMATIONAL] (confidence: 9/10) `scripts/playwright-browsers-deploy.sh:143` reads
  `if [ "$(uname -s)" != "Linux" ]; then` and exits 0 with "these are linux64 builds", so the script provisions nothing
  on the Mac, yet R1 and AE2 name the Mac. Disposition: accepted (D2): R1 now requires macOS provisioning from the same
  pin, and the Mac's archive names enter the deploy.
- S2. [INFORMATIONAL] (confidence: 9/10) `--check` in `scripts/playwright-browsers-deploy.sh` and
  `tests/playwright-browsers-deploy.bats` come from #431, merged to `dev`. Disposition: no change.

Reality rows:

```text
REALITY: premise-table finding about 70 premises [estimated], unverified=5 (CfT 157 sandbox at the covered path, launcher over Chrome, launcher on the Mac, Chrome sandbox at /opt, crawl4ai sandbox from /proc) docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1
REALITY: already-done pass the only commit on origin/dev since 2026-11-03 touching the named Playwright, AppArmor, or shell-cache files is #431, which this plan builds on scripts/playwright-browsers-deploy.sh:1
REALITY: surface-check pass every named variable and flag was exercised or read: PLAYWRIGHT_MCP_EXECUTABLE_PATH, _SANDBOX, _CONFIG, _OUTPUT_DIR, PLAYWRIGHT_CLI_SESSION, NO_UPDATE_NOTIFIER, AGENT_BROWSER_EXECUTABLE_PATH, _SESSION, --chrome-for-testing-config, PLAYWRIGHT_SKIP_BROWSER_GC (playwright-core 1.61.1 lib/coreBundle.js line 29090) scripts/playwright-browsers-deploy.sh:113
REALITY: binding-decisions pass recorded eng decisions for this plan's earlier shape (conditional pointer, per-host install, report-not-restart, one path owner) are carried into R15, R16, and the launcher; Brett's direction outranks the pin-in-CI default and CI is asked as a question docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1
REALITY: numbers pass suite counts and times from JSON reporter and GNU time; lag table from chromiumdash and chrome-for-testing git history; sizes from du and wc [measured]; about 20 files and about 400 symlinks [estimated] docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1
REALITY: deferred-asks finding the brief asked for real-suite runs per consumer; streamsgrp opens no browser, crawl4ai ran through its CLI with no upstream suite, gstack ran 10 of its test files, the Mac ran nothing because this research is read-only there docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1
REALITY: pr-count finding no ship policy on file, so the default is one PR per wave; this plan needs three dotfiles PRs (set, agent path, Chrome deploy) for review size and to keep the set independent of Brett's first two answers docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1
```

#### 1. Architecture

```text
 dotfiles pin: CfT version, WebKit and ffmpeg revisions, sha256 of each archive
      ▲ update job (Linux server, hourly): new CfT Stable, real suites, PR to dev
      │
 host timer ──▶ scripts/playwright-browsers-deploy.sh ──curl, unzip, sha256──▶ $PLAYWRIGHT_BROWSERS_PATH
                                                          chromium-<N>/  chromium_headless_shell-<N>/  webkit-<N>/
                                                          chromium-<rev> ─▶ chromium-<N>  (range; each with a .links client)
      ┌───────────────┬───────────────────┬───────────────────┐
      ▼               ▼                   ▼                   ▼
  e2e suites     gstack probes,      crawl4ai default    any other default
  (raw alias)    gstack headed       channel             chromium.launch()

 shell config: [ -x <browsing build> ] ─▶ DOTFILES_BROWSING_BIN and the tool pointers (unset when absent)
      ┌──────────────────┬────────────────────┐
      ▼                  ▼                    ▼
  agent CLI        gstack headless       agent scripts
      └──────────────────┴────────────────────┘
                         ▼
        launcher: refuses root, strips flags, exec ─▶ Chrome
```

- A1. [CRITICAL] (confidence: 9/10) `coreBundle.js` `isBrowserDirectory` treats any `chromium-*` name as a browser
  directory, and `_traverseBrowserInstallations` keeps only what a client names:
  `const browserVersion = parseInt(descriptor.revision, 10);`. #431's script says "Each alias needs a client of its own:
  a browsers.json holds one revision per browser". So a forward alias range with one client deletes every other alias on
  the next `playwright install` run outside the shell's environment, which is the outage that motivated #431, at larger
  scale. A real directory with a non-numeric name such as `chromium-cft-157` cannot be claimed at all. Disposition:
  accepted (D3): R3 requires one client per aliased revision and numeric names for real directories.
  `PLAYWRIGHT_SKIP_BROWSER_GC` stays as the second layer, because `uninstall` deletes it and a scrubbed environment
  drops it.
- A2. [INFORMATIONAL] (confidence: 9/10) R4 moves the set on a schedule while a long-lived gstack daemon or a running
  suite may hold the old build. Measured on CfT 157, full binary and headless shell: with the browser's directory
  removed mid-session, reload, new page, new context, cross-site navigation, screenshot, and PDF all still worked. That
  run was an unwrapped launch with Playwright's default `--no-sandbox`, and it was not repeated with the sandbox on. So
  a flip does not break a running browser in what was measured, and no `/proc` gate is needed before removal. A browser
  starting at the moment of a flip could still read files from the old path. Disposition: accepted (D4): R4 flips
  aliases atomically and keeps the previous build until the next deploy, with no process scan.
- A3. [INFORMATIONAL] (confidence: 8/10) The plan's "reads the browser's path from one place" left the owner unnamed. A
  path table inside a stowed launcher and a second `[ -x ]` in shell config would be a hand-synced list (red flag 8).
  Stowed scripts cannot source repo-relative files. Disposition: accepted (D5): shell config owns the path and exports
  `DOTFILES_BROWSING_BIN` only when the binary exists; the launcher reads that variable and has no path table. A
  scrubbed environment fails closed with the deploy command.
- A4. [INFORMATIONAL] (confidence: 8/10) A launcher that strips `--no-sandbox` kills any browser started as root with
  `FATAL ... Running as root without --no-sandbox is not supported`, an error that points the caller at the flag it just
  lost. Disposition: accepted (D6): the launcher refuses root before `exec`, with its own message. CI and containers
  never reach it, because they do not deploy the stow package.
- A5. [INFORMATIONAL] (confidence: 7/10) Bump-job placement: a GitHub runner lacks the local state agentnative-site's
  Worker expects, and the suites need scratch clones. `docs/plans/2026-11-02-2155-feat-yazi-plugin-auto-bump-plan.md`
  sets the PR pattern. Disposition: accepted (D7): a weekly user timer on the Linux server runs the candidate and the
  current build through the suites, and it opens a PR only when the failing set does not grow. The measured runs did
  exactly this by hand. A failing-set comparison is needed because agentnative-site and gstack have failures that are
  not browser-related.

Design twice. Shape A (chosen) is aliases plus a launcher: consumers change nothing, the set hides revision tracking
behind Playwright's own directory lookup, and the launcher hides five flags and the per-OS path behind one executable.
Shape B is per-consumer configuration: `executablePath` in each repo's Playwright config, each tool's own setting, no
aliases. It needs no symlink range, but it leaks the browser path into four repos and three tools, cannot reach bare
`chromium.launch()` calls or gstack's probes, and contradicts Brett's "repo's use what's available on the system". A
hides more behind less.

Red flags: flag 8 (hand-synced list) is A3, and the alias range and its clients are generated from one loop. Flag 6 (two
ways to do one task): gstack on the Linux server has the alias for its probes and a pointer for browsing under Option A.
Accepted, because the two serve different trust levels, and R15 keeps the pointer from applying where headed sessions
run. No others apply.

Failure modes:

| Path            | Realistic failure                                                             | Handling                                                                                         | What the user sees                                     |
| --------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------ |
| Deploy download | Google's bucket serves a corrupt or swapped archive                           | sha256 against the pin (AE4), test                                                               | Stops, both hashes named, old set intact               |
| Alias lookup    | A Playwright release moves its executable path                                | `--check` and the bump's suite run                                                               | `Executable doesn't exist`; `--check` names the alias  |
| Cleanup         | A tool with a scrubbed environment runs `playwright install`                  | One client per alias (A1), test                                                                  | Nothing deleted                                        |
| Bump flip       | A daemon runs from the old build                                              | Measured safe; D4 keeps the previous build one cycle, test                                       | Session keeps working on the old build until restarted |
| Launcher        | Variable unset in a scrubbed environment                                      | Exit with the deploy command (AE9), test                                                         | A named error before any page opens                    |
| Launcher        | Browser refuses `exec` under an unloaded AppArmor profile at boot             | `FATAL ... No usable sandbox!` on CfT; setuid fallback on Chrome                                 | Named failure, never an unsandboxed page               |
| Chrome apt      | Google's origin dropped from unattended upgrades                              | R16 check (AE11), test                                                                           | Session-start failure with the fix                     |
| CRLSet          | The first 14 s or so of every session, which is the first page of any session | `--component-updater=fast-update` shortens it from 63 s (R9); compiled-in distrust still applies | Silent: a revoked-only certificate loads               |
| Safe Browsing   | A session younger than about 4 minutes                                        | None; confirmed at 230 s and not at 150 s                                                        | Silent: a flagged page loads                           |

The last two rows are silent with no test. They are accepted limits of both builds rather than gaps this plan can close,
and the plan states them where the conditions are listed. Critical gaps: 0.

#### 2. Code quality

- Q1. [INFORMATIONAL] (confidence: 7/10) The launcher's exact-match list misses `--ignore-certificate-errors-spki-list`,
  the form that pins chosen keys. Disposition: accepted (D8): R9 strips every `--ignore-certificate-errors*` form.
- Q2. [INFORMATIONAL] (confidence: 7/10) The replaced-executable report in R16 needs the `/proc` scan in
  `scripts/upgrade/lib/stale-procs.sh` (`stale_procs_restart /proc "$prefix"` at `scripts/upgrade/brew.sh:29`), which
  restarts rather than reports. Callers: `brew.sh` and R16's check (plan assumption). Disposition: accepted (D9): split
  out a report-only scan in the same file so both share it. Implementation lines saved are unknown until written; no
  behavior of the brew caller changes.

The launcher follows the repo's script conventions: `#!/usr/bin/env bash`, `ERROR:` on stderr, the fix command named. It
uses arrays and no bash 4 construct, so the bash-version guard does not apply. The check follows
`scripts/sysctl-deploy.sh --check`.

#### 3. Tests

Framework: bats through `scripts/run-tests` (AGENTS.md, Local gates mirror CI).

```text
CODE PATHS                                              USER FLOWS
[+] scripts/playwright-browsers-deploy.sh               [+] A repo runs its suite
  ├── [GAP] missing or malformed pin → usage error        ├── [GAP] [→E2E] set deployed, suites pass (AE1, live)
  ├── [GAP] sha256 mismatch → stop, keep the set          └── [GAP] [→E2E] newer Playwright, no dotfiles change (AE3, live)
  ├── [GAP] Linux and macOS archive names               [+] Another tool installs
  ├── [GAP] range aliases; real dir at an alias replaced  └── [GAP] [→E2E] playwright install, set intact (AE4, live)
  ├── [GAP] WebKit aliases stop at the pin              [+] gstack
  ├── [GAP] one client per alias, numeric names           ├── [GAP] [→E2E] probe prints BROWSER_OK (AE6, live)
  ├── [GAP] deploy keeps the previous build               └── [GAP] [→E2E] headed side panel on the Mac (AE2, live)
  ├── [GAP] pre-flip launch fails → aliases stay        [+] Agent on an untrusted page
  └── --check                                             ├── [GAP] [→E2E] sandboxed, compromised CA refused (AE8, live)
      ├── [GAP] pin differs, pin too old                  ├── [GAP] [→E2E] two agents kept apart (AE10, live)
      └── [GAP] alias or client missing, stray browser    ├── [GAP] [→E2E] slot tears down after use (AE13, live)
[+] launcher (new)                                        └── [GAP] [→E2E] crawl4ai sandbox and cert (AE7, live)
  ├── [GAP] strips each flag, keeps the rest whole      [+] A bare script
  ├── [GAP] pipes survive exec (fds 3 and 4)              └── [GAP] [→E2E] sandboxed through the alias (AE14, live)
  ├── [GAP] environment cleared to the allowlist        [+] Host without a browsing build
  ├── [GAP] adds the fast-update flag                     └── [GAP] [→E2E] stops before any page (AE9, live)
  ├── [GAP] variable unset → ERROR plus deploy command  [+] Chrome upgrade
  └── [GAP] root → refuses                                └── [GAP] [→E2E] timer run installs (AE11, live)
[+] alias wrapper (new)
  └── [GAP] drops sandbox flags, keeps them for root
[+] shell-config block (new)
  ├── [GAP] binary present → exports set
  ├── [GAP] binary absent → nothing exported (REGRESSION, CRITICAL)
  └── [GAP] Mac path with spaces stays whole
[+] bump script (new)
  ├── [GAP] passing set shrinks → no PR, names the suite (AE5)
  ├── [GAP] suite produces no report → no PR (AE5)
  ├── [GAP] candidate-only failure passes on rerun (AE5)
  └── [GAP] CLI release younger than the gate → no change
[+] Chrome check (new)
  └── [GAP] stale, timer disabled, replaced executable, absent → note

COVERAGE: 0/37 paths tested (all new)  |  Code paths: 25/37  |  User flows: 12/37
QUALITY: none yet  |  GAPS: 37 (12 live E2E, 0 eval)
```

Proposed tests, with value cards in the Test Plan artifact: extend `tests/playwright-browsers-deploy.bats` (from #431)
for the pin, hash, range, clients, numeric names, and `--check`; a new `tests/browsing-launcher.bats` over a stub
browser for the flags, pipes, unset variable, and root; pointer cases in `tests/shell-config.bats`; a new
`tests/browser-set-bump.bats` over fixture suite results; `tests/chrome-deploy.bats` over fixture Packages files and a
fixture `/proc`. The live checks have no CI equivalent.

Regression contract (carried from the eng decisions recorded for this plan): a host without a browsing build keeps
today's gstack behavior, with `GSTACK_CHROMIUM_PATH` unset and browse launching through the alias. Tests made obsolete:
the fixed-revision alias cases of #431's suite. Test Plan:
`~/.gstack/projects/brettdavies-dotfiles/brett-dev-eng-review-test-plan-20261103-220000.md`.

#### 4. Performance

- P1. [INFORMATIONAL] (confidence: 8/10) Full CfT against the headless shell: about 6% more peak RSS (220 MB against 207
  MB) and the same wall time on lmgroktfy; meum-sites 118.9 s against 105.4 s; agentnative-site 146.6 s against 114.1 s
  [measured, one run each, load average under 8]. The default launch stays on the shell. Disposition: no action.
- P2. [INFORMATIONAL] (confidence: 7/10) The shell block adds one file test to every shell start, inside the pre-push
  startup budget. Disposition: a single `[ -x ]` with no subprocess.
- P3. [INFORMATIONAL] (confidence: 7/10) About 400 clients and symlinks: Playwright reads `.links` only at `install` and
  `uninstall`, never at launch (`coreBundle.js:29090`), so the range costs nothing per test. Scale unknown beyond that
  count. Disposition: no action.

Disk: one set is CfT 409 MB, shell 278 MB, plus WebKit and ffmpeg. It replaces the 1234 and 1248 sets, and removes 929
MB of Puppeteer downloads if that cache goes.

#### Outside voice

Disabled (`codex_reviews` is `disabled`, and the brief says cross-model off); recorded as skipped. No outside or
replacement review ran.

#### Decision ledger

Each entry was auto-decided on its recommendation (unattended slot, standing authorization).

| ID  | Finding         | Options                                                                           | Chosen       | Accepted scope                                                                                           |
| --- | --------------- | --------------------------------------------------------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------- |
| D1  | complexity gate | original arrangement; smaller arrangement                                         | smaller      | one deploy script owning pin, aliases, clients, and check; one launcher file; one shell block; three PRs |
| D2  | S1              | provision the Mac from the pin; leave the Mac to `playwright install`             | pin          | R1 wording, macOS archive names                                                                          |
| D3  | A1              | one client per alias plus env; env alone                                          | both         | R3 wording, numeric names                                                                                |
| D4  | A2              | keep the previous build one cycle; gate removal on a process scan; delete at once | one cycle    | R4 wording                                                                                               |
| D5  | A3              | shell config owns the path; launcher owns it                                      | shell config | R9 wording, `DOTFILES_BROWSING_BIN`                                                                      |
| D6  | A4              | refuse root; let Chrome fail                                                      | refuse       | R9 wording                                                                                               |
| D7  | A5              | Linux-server timer with PR; GitHub workflow                                       | timer        | R4 wording, Deferred item settled                                                                        |
| D8  | Q1              | strip every form; exact match                                                     | every form   | R9 wording                                                                                               |
| D9  | Q2              | shared report-only scan; second scan                                              | shared       | R16 implementation constraint                                                                            |

Approval readiness: PASS (D1 to D9, auto-decided under the slot's standing authorization).

#### NOT in scope

- CI joining the set: Brett's decision 4 keeps CI as it is.
- Firefox, Edge, Playwright MCP, the GStack Browser app, Aside: see Scope Boundaries.
- Restarting a user's browser automatically: the checks report, because a daemon may hold a live session.
- Patching gstack or crawl4ai: the alias and launcher make it unnecessary, and the gstack issue is Brett's to file.
- End-to-end agent runs on Claude Code: the benchmark covers token cost, and a repeat would spend model budget nobody
  asked for.

#### Parallelization

| Phase                  | Modules touched                                                                                       | Depends on         |
| ---------------------- | ----------------------------------------------------------------------------------------------------- | ------------------ |
| 1 System set           | `scripts/`, `config/playwright/`, `tests/`                                                            | #431, merged       |
| 2 First execution gate | none                                                                                                  | phase 1            |
| 3 Wrapper and control  | `scripts/`, `config/shell/`, `tests/`                                                                 | phase 2            |
| 4 Chrome and agents    | `scripts/`, `config/systemd/system/`, `stow/local/`, `config/shell/`, `scripts/agent-slot/`, `tests/` | phase 2            |
| 5 Keeping current      | `scripts/`, `stow/local/`, `stow/launchagent/`, `tests/`                                              | phases 2 and 3     |
| 6 Library              | `scripts/`, `config/playwright/`, each repo's Dependabot config                                       | phase 1            |
| 7 Docs                 | `stow/claude/dot-claude/`, `docs/runbooks/`                                                           | phases 3, 4, and 5 |

Lane A: phases 1, 2, 3, and 5, in order. Lane B: phase 4, alongside phase 3 once phase 2 passes; `config/shell/` is
shared, so merge phase 3's shell change first, and `scripts/upgrade/lib/stale-procs.sh` belongs to this lane alone. Lane
C: phase 6, any time after phase 1. Phase 7 closes.

#### Implementation Tasks

- [ ] **T1 (P1, human: ~1d / CC: ~45min)** — phase 1, provisioning — one pin, Chromium and ffmpeg alias range, WebKit
  aliases up to the pin, per-alias clients, numeric real directories, macOS archives, sha256, real directory at an alias
  replaced
  - Surfaced by: Architecture — A1; Scope — S1
  - Files: `scripts/playwright-browsers-deploy.sh`, `config/playwright/`, `tests/playwright-browsers-deploy.bats`
  - Verify: `scripts/run-tests tests/playwright-browsers-deploy.bats`; AE1, AE3, AE4 live, after T5
- [ ] **T2 (P1, human: ~1h / CC: ~10min)** — phase 1, provisioning — flip aliases atomically and keep the previous build
  one cycle
  - Surfaced by: Architecture — A2
  - Files: the deploy script, its bats
  - Verify: bats case; a live daemon survives a flip
- [ ] **T5 (P1, human: ~30min / CC: ~10min)** — phase 2, live — sandbox measurement at the real paths after the first
  deploy, through the wrapper, on both machines; side panel through the wrapper on the Mac; a sandboxed browser with its
  directory removed
  - Surfaced by: premise table, unverified rows
  - Files: none
  - Verify: AE2, AE14
- [ ] **T6 (P1, human: ~2h / CC: ~15min)** — phase 3, alias wrapper — sandbox-only wrapper at the alias, its stable path
  - Surfaced by: document review, bare launches
  - Files: the deploy script, its bats
  - Verify: AE14; the suites through the wrapper on both machines
- [ ] **T7 (P1, human: ~3h / CC: ~20min)** — phase 3, control — every pointer and download switch,
  `~/.crawl4ai/chromium.path`, the inventory check, and removal of what it lists
  - Surfaced by: decision 8
  - Files: `config/shell/caches.sh`, the deploy script, a new check, `tests/shell-config.bats`
  - Verify: AE6, AE7, AE17
- [ ] **T8 (P1, human: ~3h / CC: ~20min)** — phase 4, Chrome — `scripts/chrome-deploy.sh`, its hourly timer, and the
  Chrome check
  - Surfaced by: decisions 1 and 3
  - Files: `scripts/`, `config/systemd/system/`, `tests/chrome-deploy.bats`
  - Verify: AE11, AE12 live, after the operator's deploy
- [ ] **T3 (P1, human: ~3h / CC: ~20min)** — phase 4, launcher — strip flags in every form, add the fast-update flag,
  clear the environment, refuse root, read the shell's variable, `exec`
  - Surfaced by: Architecture — A3, A4; Code quality — Q1
  - Files: `stow/local/dot-local/bin/`, `config/shell/`, `tests/browsing-launcher.bats`, `tests/shell-config.bats`
  - Verify: `scripts/run-tests tests/browsing-launcher.bats`; AE8, AE9
- [ ] **T9 (P1, human: ~3h / CC: ~20min)** — phase 4, agent-browser — the stowed shim, refused verbs, session from the
  working tree, close at slot teardown
  - Surfaced by: decision 2
  - Files: `stow/local/dot-local/bin/`, `scripts/agent-slot/`, its bats
  - Verify: AE9, AE10, AE13, AE15
- [ ] **T4 (P2, human: ~1d / CC: ~30min)** — phase 5, update job — hourly check of CfT Stable, per-test comparison with
  reports required and one rerun, WebKit and ffmpeg revisions from the newest Playwright, self-merging PR, and each
  host's hourly pickup with its pre-flip launch
  - Surfaced by: Architecture — A5; decision 3
  - Files: `scripts/`, `stow/local/`, `stow/launchagent/`, `tests/browser-set-bump.bats`
  - Verify: AE5
- [ ] **T10 (P2, human: ~3h / CC: ~20min)** — phase 6, library — the dotfiles version, the drift check, the bump across
  repos, each repo's Dependabot ignore
  - Surfaced by: decision 7
  - Files: `config/playwright/`, `scripts/`, a bats suite, each repo's `.github/dependabot.yml`
  - Verify: AE3, AE16

The task store also carries eight tasks from the 2026-11-03 eng review of
`docs/plans/2026-11-02-2324-feat-agent-slots-on-the-mac-plan.md`, unchanged; they are that plan's work, not this one's.

#### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 applicable rows emitted, 5 unverified premises
- Architecture Review: 5 issues found
- Code Quality Review: 2 issues found
- Test Review: diagram produced, 37 gaps identified
- Performance Review: 3 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed (no tracked TODOS file)
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: Brett's are in Settled Decisions, with one open question that blocks nothing; none of this
  review's own choices is open
- Outside voice: codex, disabled (`codex_reviews`)
- Parallelization: 3 lanes, 2 parallel / 1 sequential
- Lake Score: N/A (no answers scored for Completeness)

### DX Review (plan-devex-review, 2026-11-03)

Run unattended under the same rule as the engineering review. Product type: Platform (host provisioning), with a CLI
surface (the deploy script, its `--check`, the launcher, the agent CLI's shim) and a guidance surface agents read. Mode:
DX POLISH, because this enhances existing provisioning. No design doc exists; the `/office-hours` offer was skipped as
unattended. The prior DX row belongs to this plan's earlier shape, so its scores are shown as the Prior column with a
note.

#### Developer Persona Card

```text
TARGET DEVELOPER PERSONA
========================
Who:       an AI coding agent in an agent slot on the Linux server or the Mac, unattended
Context:   asked to read a JavaScript-heavy page, click through a vendor site, or run a repo's e2e suite
Tolerance: one launch attempt; it follows the first fix line an error prints, literally
Expects:   the always-loaded CLAUDE.md and the CLI tools guide to say which browser tool to use
Secondary: the operator at a terminal, deploying a host and reading --check
```

#### Developer Empathy Narrative

I am an agent asked to pull a table from a vendor's status page that needs JavaScript. The always-loaded instructions
(`stow/claude/dot-claude/CLAUDE.md:291`) tell me Playwright browsers are system-provided and never to run
`playwright install`, so I write a script around `chromium.launch()`. It works in about a second. Nothing tells me I
just ran a pinned build with `--no-sandbox` (measured). If I reach for `npx playwright-cli`, I get a version the gate
did not vet, and on a host without Chrome it prints `Run "npx playwright install chrome"` (captured), which I would run.
In a repo, the CLI tools guide (`guides/cli-tools.md:83`) tells me never to bump Playwright independently, so a
Dependabot PR sits until someone coordinates a dotfiles change. With this plan as drafted, I still have no named command
to run: R10 says the CLI "installs", but not what I type.

#### Competitive DX Benchmark

The clock runs from the first command to a loaded page, on the covered CfT 156 path with the browser already on disk,
one run each [measured: GNU time]. Each tool's first-run reading cost is in the Agent Browsers tables.

| Tool                        | Start → result                                                                    | Time, evidence                                                                                                         | DX choice                                                | Source                        |
| --------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------- |
| Playwright library, default | `chromium.launch()` → page                                                        | about 1 s [observed: probes]                                                                                           | pinned build, sandbox off                                | `chromiumSandbox` docs; probe |
| Playwright CLI              | `open <url>` → page                                                               | 0.68 s, then 0.24 s per command [measured]                                                                             | snapshot to a file; sandbox on only for branded channels | trial                         |
| agent-browser               | `open <url>` → page                                                               | 0.32 s, then under 0.01 s per command [measured]                                                                       | native daemon; hunts for a browser                       | trial                         |
| Chrome DevTools             | `new_page <url>` → page, after `start`                                            | 0.39 s, then 0.08 s per command [measured]                                                                             | daemon; shared browser unless separated                  | trial                         |
| This plan                   | read one guidance line, `playwright-cli open <url>` → page in a sandboxed browser | under 2 min including the read [estimated]; the shim adds about 0.1 s through `bunx` [measured: 0.33 s against 0.22 s] | one command, hardening invisible                         | R9, R10                       |

Target (auto-decided): Champion, under 2 minutes from reading the guidance to a page loaded in a sandboxed browser. Tool
speed does not separate the candidates; the benchmark shows model time dominates.

#### Magical Moment Specification

For the agent: `playwright-cli open https://dv-g3b-emudhra.we-have-a-problem.com/` returns `net::ERR_CERT_REVOKED`, from
a tool it learned in one line, with no flags and a sandboxed renderer. For a repo: a Dependabot bump of
`@playwright/test` runs its Chromium projects the same day, with no dotfiles change and no download (AE3). For the
operator: `--check` prints one line naming the set's version and that every alias resolves. All use capabilities in this
plan.

#### Developer Journey Map

```text
STAGE           | DEVELOPER DOES                                 | FRICTION POINTS                                  | STATUS
----------------|------------------------------------------------|--------------------------------------------------|--------
1. Discover     | reads CLAUDE.md:291 and cli-tools.md:73-86     | both say "exact-pin, never bump independently"    | fixed (R19, DX4)
2. Install      | nothing for the agent; operator deploys a host | the agent CLI had no named command                | fixed (R10, DX5)
3. Hello World  | playwright-cli open <url>                      | absent browser printed an unsafe fix              | fixed (R10, R15, DX1)
4. Real Usage   | snapshot, fill, click; per-agent session       | agents shared one browser by default              | fixed (R10, DX5)
5. Debug        | reads the launcher's error, runs --check       | agent-browser surfaces only the last stderr line  | fixed (R9, DX2)
6. Upgrade      | nothing; the weekly job moves pins             | the CLI's pin had no owner                        | fixed (R10, DX6)
```

#### First-Time Developer Confusion Report

```text
FIRST-TIME DEVELOPER REPORT
============================
Persona: agent in a slot, task "click through this vendor page"
T+0:00  Reads CLAUDE.md: browsers are system-provided; interact with playwright-cli.     → addressed by R11
T+0:15  Runs playwright-cli open <url>. Page opens; a 265-character reply, snapshot in a file outside the tree.
T+0:30  Reads the snapshot, runs fill and click by ref. Another agent's tabs never appear.  → addressed by R10
T+1:00  (host without a browsing build) sees one line: no browsing build, the operator's deploy command. Stops and reports.
                                                                                            → addressed by R9, DX1, DX2
T+1:30  A page fails with ERR_CERT_REVOKED. The agent reports it; the launcher blocks the flag, the shim turns the tool's setting off.  → addressed by R9
```

#### Passes

- Pass 1, Getting Started: 5 → 8. The agent path is one named command; the operator path is one deploy and `--check`.
  Residual: the Chrome deploy needs root on each host, under Option A.
- Pass 2, API/CLI/SDK: 6 → 8. The agent uses the upstream command name, so upstream's `--help` and skill match. Every
  setting has a default in the shim; `-s=` remains the escape hatch. Residual: Option B or a different tool changes the
  shim's contents, not its shape.
- Pass 3, Error Messages: 4 → 7. DX1 was a CAP4. The launcher's failure becomes one self-contained line. Residual:
  Playwright's own `Executable doesn't exist` text for a consumer below the alias floor prints `npx playwright install`,
  which this plan cannot rewrite (DX3).
- Pass 4, Documentation: 5 → 8. DX4 corrects the guide. Routing fits in one line of the always-loaded file.
- Pass 5, Upgrade: 6 → 8. Pins move by PR with a suite run behind them; `--check` reports drift. Residual: a Chrome
  upgrade leaves running browsers on the old build until restarted, reported and not fixed (R16).
- Pass 6, Dev Environment: 7 → 8. Linux and Mac share the pin, shim, and launcher; CfT publishes both platforms.
  `~/.local/bin` is ahead of Homebrew in every supported shell shape (AGENTS.md). Residual: nothing has run on the Mac
  yet (AE2).
- Pass 7, Community: 3 → 3. Personal dotfiles; no community surface, and none proposed. The upstream gstack issue is
  pending with Brett.
- Pass 8, DX Measurement: 5 → 7. `--check` is the standing measure, and the live checks measure the clock once deployed.
  No telemetry proposed.

```text
ERROR PATH MATRIX (agent-ready-v1)
Path                                    | Class      | what | fix  | recovery | code | context | trace | redaction | channel | Cap
agent CLI, no browsing build             | dependency | pass | fail | fail     | fail | pass    | N/A   | pass      | pass    | CAP4:agent-cli:fix  → R10, R15
launcher, variable unset                | dependency | gap  | gap  | gap      | gap  | pass    | N/A   | pass      | gap     | CAP6:launcher:fix   → R9
launcher, run as root                   | usage      | gap  | gap  | N/A      | gap  | N/A     | N/A   | pass      | pass    | none (usage; R9 specifies it)
consumer below the alias floor          | dependency | pass | fail | fail     | fail | pass    | N/A   | pass      | pass    | CAP6:alias-floor:fix (Playwright's text; DX3)
--check, set differs from the pin       | dependency | pass | pass | gap      | gap  | gap     | N/A   | pass      | pass    | CAP6:check:context  → R4
unexpected: curl or unzip fails         | dependency | gap  | gap  | gap      | gap  | gap     | gap   | pass      | gap     | CAP6:deploy:trace (planning: pass the tool's stderr through, name the rerun)
```

Permission and safety model: the shim and launcher hold no credentials, and nothing here signs in to a browser. The
launcher strips the flag forms rather than asking, the shim turns the tool's ignore-HTTPS setting off, and the guidance
forbids changing either; a job that truly needs an insecure browser uses Playwright directly and is outside this
guidance. No verbose mode is proposed; the browser's own `--enable-logging` still passes through.

- DX1. [CRITICAL] `CAP4:agent-cli:fix unsafe fix on a host without a browsing build`. R15 as written exports no pointer
  when the browser is absent, so the Playwright CLI falls back to its default channel and prints
  `Run "npx playwright install chrome"` (captured), which runs an `apt-get install` as root or wedges on this kernel's
  extractor. Corrected: the shim always points the CLI at the launcher, which is always on PATH and fails closed. Only
  gstack's pointer stays conditional, because gstack throws on a failed launch and would lose its working fallback (the
  set). Disposition: accepted (DX-D1): R10, R15.
- DX2. [HIGH] `CAP6:launcher:fix error must survive every caller's framing`. Captured from the trial and agent-browser's
  source: agent-browser prints only stderr lines holding a keyword such as `error` or `sandbox`, or the last five when
  none does; Playwright CLI prints the line beneath a stack trace and repeats it in a call log; gstack prints the launch
  error and then its own "Fix: point GSTACK_CHROMIUM_PATH at a working Chromium". A fix on a line of its own without a
  keyword disappears under agent-browser whenever another line matches. Corrected line, Option A's form: `ERROR: no
  browsing build on this host (DOTFILES_BROWSING_BIN unset); reason: no-browsing-build; next: ask the operator to run
  sudo scripts/chrome-deploy.sh; never run playwright install`. Disposition: accepted (DX-D2): R9 requires one
  self-contained line, last on stderr, with a stable reason.
- DX3. [HIGH] `CAP6:alias-floor:fix Playwright's message for a missing executable`. `coreBundle.js:28665` throws
  `Executable doesn't exist at ...` and prints `npx playwright install`, which hangs on this kernel. This plan narrows
  when it fires (the forward range) but cannot rewrite it. The remaining reach is a consumer at Playwright 1.56 or
  earlier, which today means the Mac's crawl4ai before its upgrade. Disposition: no new requirement. R11 already forbids
  the command, and the Mac's crawl4ai upgrade is on the Deferred list.
- DX4. [INFORMATIONAL] `guides/cli-tools.md:83-85` and `CLAUDE.md:293` say repos exact-pin the one canonical version and
  to "never bump a repo's Playwright independently". Aliasing makes that false, and leaving it would have agents hold
  back Dependabot PRs. Disposition: accepted (DX-D3): R19 names the rewrite.
- DX5. [INFORMATIONAL] R10 said the CLI "installs" and agents get a session "through an environment variable", with no
  command or session source. Disposition: accepted (DX-D4): a stowed shim named as upstream's command holds the pin, the
  launcher pointer, the notifier setting, and the output directory, and derives the session from the working tree, so
  each slot is separate with no per-slot setup. `bunx` at an exact version adds about 0.1 s and passes the age gate
  (measured).
- DX6. [INFORMATIONAL] The agent CLI's pin had no owner. Disposition: accepted (DX-D5): the weekly bump job proposes it
  too, at the newest version the gate allows.
- DX7. [INFORMATIONAL] The Playwright CLI's `--help` opens with an update banner when a newer release exists, naming
  `npm install -g ...@latest`. Silenced by `NO_UPDATE_NOTIFIER` (read in `playwright-cli.js:40`). Disposition: covered
  by DX-D4.

Decision ledger (auto-decided on recommendation): DX-D1 shim always names the launcher (chosen) over a conditional
pointer with Playwright's error. DX-D2 one self-contained stderr line (chosen) over the multi-line `reason:`/`next:`
shape of `sd-commit-doc`, because a caller may keep only the last line. DX-D3 rewrite the guide's exact-pin rule
(chosen) over leaving it. DX-D4 a stowed shim (chosen) over shell functions, which non-login bash never sees, and over a
permanent global install. DX-D5 one bump job for browser and CLI pins (chosen) over a second job. Outside voice:
disabled (`codex_reviews`), recorded as skipped.

NOT in scope: telemetry on agent launches; a `--json` form of `--check` (no current consumer reads one); a community
surface; rewriting Playwright's or gstack's error text.

What already exists: `sd-commit-doc`'s reason lines, `scripts/sysctl-deploy.sh --check`, the stowed scripts in
`stow/local/dot-local/bin/`, gstack's launch error, Playwright's `PLAYWRIGHT_MCP_*` environment.

TODOS: none proposed; there is no tracked TODOS file.

Implementation tasks (DX):

- [ ] **DX-T1 (P1, human: ~1h / CC: ~10min)** — shim — agent CLI shim: pin, launcher pointer, notifier off, ignore-HTTPS
  off, output directory, idle timeout, session from the working tree, and `agent-slot` teardown closing that session
  - Surfaced by: Pass 3 — DX1; Pass 2 — DX5
  - Files: `stow/local/dot-local/bin/`, a bats case
  - Verify: AE9, AE10, AE13
- [ ] **DX-T2 (P1, human: ~30min / CC: ~5min)** — launcher — one self-contained last stderr line with a stable reason
  - Surfaced by: Pass 3 — DX2
  - Files: the launcher, `tests/browsing-launcher.bats`
  - Verify: bats asserts the last line; a live run through each tool
- [ ] **DX-T3 (P1, human: ~1h / CC: ~10min)** — guidance — routing line, page content as data, and the exact-pin rule
  rewritten
  - Surfaced by: Pass 4 — DX4
  - Files: `stow/claude/dot-claude/CLAUDE.md`, `stow/claude/dot-claude/guides/cli-tools.md`
  - Verify: `markdownlint-cli2`; read-through
- [ ] **DX-T4 (P2, human: ~30min / CC: ~5min)** — bump — the weekly job also proposes the agent CLI's pin
  - Surfaced by: Pass 5 — DX6
  - Files: the bump script, its bats
  - Verify: fixture case for a too-new release

## Deferred / Open Questions

Entries are review items left for the author; they do not block implementation.

### From 2026-11-03 review

- **The launcher's strip list names exact switches** — R9, the launcher (P3, security-lens, confidence 50)

  An agent that hits `No usable sandbox!` and sees `--no-sandbox` have no effect may try a sibling switch. Chromium also
  honors `--disable-seccomp-filter-sandbox`, `--disable-namespace-sandbox`, `--single-process`,
  `--disable-web-security`, and `--disable-site-isolation-trials`, and reads `-no-sandbox` and `--no-sandbox=1` as the
  same switch. Not measured here.

  Change: match on the normalized switch name and add those five, with a bats case for each form.

- **The launcher can reach the owner's signed-in Chrome on the Mac** — R9, the launcher, with R14, the Mac keeps its
  Chrome (P2, security-lens, confidence 50)

  A direct run with no `--user-data-dir` opens the everyday profile. Playwright and the shim always pass a temporary
  directory, so this needs an agent to run the launcher by hand. Inference from Chrome's default behavior; nothing was
  measured on the Mac.

  Change: the launcher refuses to start unless `--user-data-dir` is present and outside the default profile directory.

- **Stale builds stay in use until phase 1 lands** — Dependencies, the provisioning work (P3, product-lens,
  confidence 50)

  gstack keeps browsing on a build that trusts the compromised CA until the rewrite ships. Moving the existing script's
  `CFT_VERSION` to a current build and aliasing revision 1248 is a few lines ahead of it.

  Change: make that phase 1's first commit, if the rewrite will take more than a few days.

- **The replaced-executable report asks for a shared-library split** — R16, the Chrome check (P2, scope-guardian,
  confidence 50)

  The report restarts nothing and needs a report-only split of `scripts/upgrade/lib/stale-procs.sh`, which `brew.sh`
  also uses. A running browser survived its directory being removed (measured on CfT), though replacing Chrome's files
  under a live daemon through dpkg was not run.

  Change: drop the report and AE12 if the first Chrome upgrade under a live daemon shows no breakage.

## DX Review Scorecard

```text
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      | 8/10   | 5/10   | ↑      |
| API/CLI/SDK          | 8/10   | 6/10   | ↑      |
| Error Messages       | 7/10   | 4/10   | ↑      |
| Documentation        | 8/10   | 5/10   | ↑      |
| Upgrade Path         | 8/10   | 6/10   | ↑      |
| Dev Environment      | 8/10   | 7/10   | ↑      |
| Community            | 3/10   | 3/10   | =      |
| DX Measurement       | 7/10   | 5/10   | ↑      |
+--------------------------------------------------------------------+
| TTHW                 | <2 min | no named command today               |
| Competitive Rank     | Champion (target)                            |
| Magical Moment       | designed via playwright-cli and --check      |
| Product Type         | Platform with a CLI and guidance surface     |
| Mode                 | POLISH                                       |
| Overall DX           | 7/10   | 5/10   | ↑      |
+====================================================================+
| DX PRINCIPLE COVERAGE                                               |
| Zero Friction      | covered                                        |
| Learn by Doing     | covered (one command, upstream's help)         |
| Fight Uncertainty  | covered (DX1, DX2, R4)                         |
| Opinionated + Escape Hatches | covered (shim defaults; -s=; direct Playwright) |
| Code in Context    | covered                                        |
| Magical Moments    | covered                                        |
| Agents Are Users   | covered (no interactive step; stop with a command) |
+====================================================================+
```

Prior column: this review's initial scores for the plan as written. Community stays at 3, honestly: no community surface
is in scope. Error Messages stays at 7 because Playwright's own message for a missing executable is not this plan's to
change.

Unresolved decisions from this review: none.

## GSTACK REVIEW REPORT

| Review         | Trigger                                                    | Why                             | Runs | Status             | Findings                                                  |
| -------------- | ---------------------------------------------------------- | ------------------------------- | ---- | ------------------ | --------------------------------------------------------- |
| CEO Review     | `/plan-ceo-review`                                         | Scope & strategy                | 0    | —                  | —                                                         |
| Outside Review | codex, plan-eng-review and plan-devex-review outside voice | Independent 2nd opinion         | 2    | disabled           | —                                                         |
| Eng Review     | `/plan-eng-review`                                         | Architecture & tests (required) | 2    | ISSUES OPEN (PLAN) | 47 issues, 0 critical gaps                                |
| Design Review  | `/plan-design-review`                                      | UI/UX gaps                      | 0    | —                  | —                                                         |
| DX Review      | `/plan-devex-review`                                       | Developer experience gaps       | 2    | ISSUES OPEN        | score: 5/10 → 7/10, TTHW: no named command today → <2 min |

- **OUTSIDE COVERAGE:** codex, plan-review phase, disabled by `codex_reviews` for both reviews; no findings.
- **VERDICT:** no review CLEAR yet — eng review required (both reviews' findings are accepted into the plan as mapped
  work).

**UNRESOLVED DECISIONS:**

- 1 open for Brett, blocking nothing (plan Settled Decisions): where `GSTACK_CHROMIUM_PATH` points
