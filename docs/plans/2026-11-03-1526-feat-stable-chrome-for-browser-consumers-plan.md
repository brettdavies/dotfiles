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

- **Objective:** One system-owned browser set, updated by dotfiles on its own cadence, that every consumer on the Linux
  server and the Mac launches and none downloads. Separately, a chosen answer for what agents use on pages nobody
  vetted, with the sandbox on, certificate checks enforced, and revocation data live.
- **Means:** One Chrome for Testing (CfT) build plus one WebKit build, aliased for every Playwright revision, serve the
  tests and every default Playwright launch. A small dotfiles launcher enforces the hardened flags for agent browsing.
  Google Chrome stable is the recommended browser behind that launcher, and a CLI (not MCP) is the recommended tool
  agents drive it with.
- **Brett's direction (verbatim):** "let's harden a single system playwright and tests. We update it separately from any
  repo. repo's use what's available on the system, not their own preferences. gstack, etc incl". My reading: one
  system-owned set that dotfiles updates, used by the e2e repos, gstack, crawl4ai, and agent scripts, with no consumer
  downloading its own.
- **Product authority:** Requirements govern behavior and Key Decisions record why. The measurements in this plan are
  the evidence. Where a solutions doc or runbook disagrees with a measurement here, the doc is what gets rewritten.
- **Open blockers:** Brett decides what agents browse with, which tool they drive it with, how the seven-day gate
  applies to browser builds, and whether CI joins the set (Outstanding Questions). The system set for tests does not
  wait on the first two.
- **Execution profile:** User-space provisioning, shell config, one launcher, doc updates, and a bump workflow. If
  Chrome is chosen, also a system package and apt configuration that the operator applies, because the agent's settings
  deny `sudo`. Proof is runtime measurement on both machines. bats covers the script seams.
- **Stop conditions:** Stop and bring the finding to Brett if a real suite fails on a candidate CfT build where it
  passes on the set's current build, if the launcher breaks a consumer's pipe connection, or if any browser behind the
  launcher runs a renderer without its own user and PID namespaces on the Linux server.
- **Who finishes:** `ce-plan` enriches this file in place. The operator runs every `/etc` step. Brett files the gstack
  issue, which is drafted and pending with him.

---

## Product Contract

### Summary

Replace the per-Playwright-version browser map with one CfT build and one WebKit build, aliased for every revision a
consumer can ask for. The four e2e repos, gstack, and crawl4ai then resolve to that build with no configuration of their
own, and their installs become no-ops. dotfiles chooses the version and moves it on a schedule of its own.

The tests and the open web then split, because the two have different needs. Tests need a stable, reproducible build.
Agents on untrusted pages need the newest fixes and a supported update path. The recommendation is Chrome stable behind
a hardened launcher for agent browsing, the Playwright CLI as the agent's tool, and CfT for tests and for gstack's
headed sessions, which need `--load-extension` and which branded Chrome blocks.

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
| WebKit            | Playwright's own patched build; no branded Safari. It has its own revision per release.                                                                                                                                                                                               | playwright.dev/docs/browsers                            |

**Drift, measured with a 23-step probe.** The probe covers launch, context, tracing, navigation, fill, click, role
locators, aria snapshot, frames, evaluate, console, workers, routing, popups, downloads, dialogs, screenshots, PDF,
cookies and storage state, media emulation, coverage, video, and close. The rows at CfT 157 ran against the full binary
and the headless shell; the canary and CfT 151 rows ran against the full binary.

| Playwright                                     | Its pin       | Build under test          | Drift             | Result                                                                                                                                                                                               |
| ---------------------------------------------- | ------------- | ------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.40.0, 1.45.0, 1.49.1                         | 120, 127, 131 | CfT 157.0.8103.38         | +37 to +26 majors | 22 of 23 steps; video not run (no ffmpeg for those revisions here). A `Target closed` rejection stays unhandled, and Node 26 exits on it unless trapped. Not checked against each version's own pin. |
| 1.52.0, 1.55.1, 1.57.0, 1.59.1, 1.60.0, 1.62.1 | 136 to 151    | CfT 157                   | +21 to +9         | 22 of 23; video not run for the same reason                                                                                                                                                          |
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
- WebKit tolerates revision drift on this evidence. agentnative-site's `mobile-ios` and `tablet` projects on Playwright
  1.61.1 gave 88 pass, 4 fail, 8 skip on WebKit 2311 (its own), and the same result on WebKit 2336 and on 2370
  (1.64.1's) aliased as 2311. The 4 fails match the control.
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
| Time behind Linux stable, last 20 releases (2026-08-06 to 2026-11-03) | 15 releases: 0.3 to 1.5 h, median 0.8 h. 3 releases: a newer CfT already existed. 2 releases: no CfT build at all, about 5 days behind.                                                                                                                                                | The Linux stable build, by definition. Each host's unattended run adds up to a day.                                                                        |
| The two gaps                                                          | 151.0.7922.108 (41 security fixes): 122 h until CfT 151.0.7922.138. 154.0.8037.97 (11 security fixes): 113.5 h until CfT 155.                                                                                                                                                          | Shipped                                                                                                                                                    |
| Integrity of the download                                             | HTTPS from `storage.googleapis.com`; the JSON API lists URLs and publishes no hash                                                                                                                                                                                                     | SHA256 in a signed apt index                                                                                                                               |
| Compiled-in distrust, default flags                                   | Rejects the compromised-CA host with `ERR_CERT_REVOKED`                                                                                                                                                                                                                                | Same                                                                                                                                                       |
| CRLSet under Playwright's default flags                               | None: `--disable-component-update` blocks it, and `revoked.badssl.com` loads with status 200                                                                                                                                                                                           | Same                                                                                                                                                       |
| CRLSet with that one flag removed                                     | Version 10881 arrives at about 62 s; `revoked.badssl.com` then fails with `ERR_CERT_REVOKED`                                                                                                                                                                                           | Version 10881 at about 70 s; same result                                                                                                                   |
| Time until a revoked certificate fails, one context held open         | 65 s (6 s with the seeded config below)                                                                                                                                                                                                                                                | 65 s                                                                                                                                                       |
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
an open browser context, so a very short-lived session has only what is compiled in.

**A hardened launch needs five things**, on either build:

1. No `--no-sandbox` and no `--disable-setuid-sandbox`.
2. An AppArmor `userns` grant at the binary's real path on Ubuntu.
3. No `--disable-component-update`, for CRLSet.
4. No `--disable-background-networking`, for Safe Browsing. This lets the browser's background traffic to Google
   through.
5. No `--ignore-certificate-errors`, and any tool setting that ignores HTTPS errors turned off.

**One launcher enforces this for every tool that accepts an executable path.** A trial script that drops those flags and
`exec`s the real binary was measured under a default `chromium.launch()`: no `--no-sandbox` on the process, renderers
sandboxed, label `playwright-chromium`, pipes intact, `revoked.badssl.com` loading at launch and failing with
`ERR_CERT_REVOKED` after 100 s. Under agent-browser, the launcher kept `--args "--no-sandbox"` from reaching the
browser, and the revoked host failed by 140 s. The launcher was not measured over Chrome stable or on the Mac.

### "No Chrome?"

Chrome is not needed for tests or for gstack's headed sessions, where CfT is the better fit. Chrome is needed only if
agents browse untrusted pages on a build Google supports for that.

|                      | Chrome stable                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Buys**             | Google's supported browser for untrusted pages. Every Linux stable release, including those CfT skips (41 and 11 security fixes in the last 20 releases). A signed update path. A setuid sandbox fallback when no AppArmor profile is loaded. PKI Metadata and the other components with no config. The standard path that Playwright CLI, Playwright MCP, Chrome DevTools, and agent-browser all find by themselves. |
| **Costs on Linux**   | One operator `sudo` deploy per host. Google's apt source and keyring, `/etc/cron.daily/google-chrome`, a `chromemgmt` group, and update-alternatives entries for `google-chrome` and `x-www-browser`. An `Origins-Pattern` drop-in and a list refresh for unattended upgrades. 453 MB. A version that moves on Google's schedule, with running browsers left on the replaced executable until restarted.              |
| **Costs on the Mac** | None new: Chrome 156.0.8078.80 is already installed and updated by Google.                                                                                                                                                                                                                                                                                                                                            |
| **Cannot do**        | Load gstack's side panel, because branded Chrome blocks `--load-extension`. So gstack's headed sessions stay on CfT in every option.                                                                                                                                                                                                                                                                                  |

### Agent Browsers

Each tool was installed into a scratch directory at the newest version the seven-day gate allows on 2026-11-03, and
driven through one job on a local page: open, snapshot, fill, click, read a heading, follow a link to a new tab. All
three candidates finished it.

|                                 | Playwright CLI                                                                                                                                                | Chrome DevTools for agents (CLI)                                                                                                | agent-browser                                                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Publisher, license              | Microsoft, Apache-2.0                                                                                                                                         | Google, Apache-2.0                                                                                                              | Vercel Labs, Apache-2.0                                                                                                                                          |
| Newest / newest the gate allows | 0.1.23 / 0.1.22 (2026-09-28)                                                                                                                                  | 1.12.0 / 1.12.0 (2026-10-22)                                                                                                    | 0.41.2 / 0.40.0 (2026-10-27)                                                                                                                                     |
| Size installed                  | 19 MB (bundles `playwright-core` 1.64.0-alpha)                                                                                                                | 15 MB, no dependencies                                                                                                          | 115 MB (native binaries for seven platforms); bun blocks its postinstall and the launcher still works                                                            |
| Browser by default              | `chrome` channel at `/opt/google/chrome/chrome`; absent, it fails and prints `Run "npx playwright install chrome"`                                            | Stable at `/opt/google/chrome/chrome`; absent, it fails                                                                         | Its own download, then Chrome on PATH, then `~/.cache/puppeteer`, then `~/.cache/ms-playwright`. On this host that means the Puppeteer cache's stale 133 or 150. |
| Downloads a browser             | Only if asked (`install-browser`)                                                                                                                             | No                                                                                                                              | `agent-browser install` downloads CfT; `doctor --fix` can reinstall                                                                                              |
| Points at a chosen binary by    | `PLAYWRIGHT_MCP_EXECUTABLE_PATH`, or a config named by `PLAYWRIGHT_MCP_CONFIG`                                                                                | `--executablePath` on `start`                                                                                                   | `AGENT_BROWSER_EXECUTABLE_PATH`                                                                                                                                  |
| Sandbox                         | On for branded channels; off for CfT and `executablePath` unless `PLAYWRIGHT_MCP_SANDBOX=true`. Measured on with it set.                                      | On, measured at the covered CfT path                                                                                            | On unless `CI` is set, or root, or a container. Measured on at the covered path. At an uncovered path it fails and suggests `--args "--no-sandbox"`.             |
| CRLSet with no launcher         | Blocks it; `ignoreDefaultArgs` in the config lifts that (measured `ERR_CERT_REVOKED`)                                                                         | Does not block it (measured `ERR_CERT_REVOKED`)                                                                                 | Hard-coded; only the launcher lifts it                                                                                                                           |
| Separating two agents           | `PLAYWRIGHT_CLI_SESSION` or `-s=`; measured apart                                                                                                             | One browser for all, including with `CHROME_DEVTOOLS_MCP_SESSION_ID`; a per-agent `XDG_RUNTIME_DIR` separated them              | `AGENT_BROWSER_SESSION`; measured apart                                                                                                                          |
| Phones home                     | Update check, off with `NO_UPDATE_NOTIFIER` or `CI`                                                                                                           | Usage statistics on by default; update check. `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`, `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS` | None documented; `upgrade` is a command                                                                                                                          |
| Guardrails for untrusted pages  | `PLAYWRIGHT_MCP_ALLOWED_ORIGINS`, which its docs say is not a security boundary; file access limited to workspace roots                                       | None                                                                                                                            | `--allowed-domains` (measured blocking), `--content-boundaries` (measured nonce markers), `--max-output` (measured cap), `--action-policy`, encrypted auth vault |
| Known advisories                | `@playwright/mcp` before 0.0.40 (CVE-2025-9611); `playwright` before 1.55.1 (CVE-2025-59288)                                                                  | Before 1.1.0 (CVE-2026-53765, CVE-2026-53766)                                                                                   | None listed                                                                                                                                                      |
| Release pace                    | About monthly lately                                                                                                                                          | 2 in the last 3 weeks                                                                                                           | 6 in the last 9 days                                                                                                                                             |
| Install under the gate          | `bunx @playwright/cli@0.1.22`; the gate rejected 0.1.23 with `blocked by minimum-release-age`. Its banner prints `npm install -g ...@latest` unless silenced. | `bunx chrome-devtools-mcp@1.12.0`                                                                                               | `bunx agent-browser@0.40.0`; never `agent-browser upgrade`                                                                                                       |
| Homebrew formula                | `playwright-cli` 0.1.23                                                                                                                                       | `chrome-devtools-mcp` 1.12.0                                                                                                    | `agent-browser` 0.41.1                                                                                                                                           |

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

|                                    | Option A: CfT for tests, Chrome for browsing (recommended)                  | Option B: CfT only, no Chrome                                                                                                                     |
| ---------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tests, default Playwright launches | System CfT set                                                              | System CfT set                                                                                                                                    |
| gstack headed (Mac)                | System CfT set, side panel works                                            | Same                                                                                                                                              |
| gstack headless (Linux)            | Launcher over Chrome through `GSTACK_CHROMIUM_PATH`                         | Launcher over CfT, or the alias alone                                                                                                             |
| crawl4ai                           | `chrome_channel: chrome` per covered caller, sandbox opt-in                 | Alias, sandbox opt-in                                                                                                                             |
| Agent CLI                          | Launcher over Chrome                                                        | Launcher over CfT                                                                                                                                 |
| Who updates the browsing build     | apt with unattended upgrades on Linux; Google's updater on the Mac          | A dotfiles timer polling CfT, hourly                                                                                                              |
| Who updates the test set           | dotfiles, weekly, through a bump that runs the suites                       | The same, as a second build on disk unless tests also follow stable hourly                                                                        |
| Operator work                      | One `sudo` deploy per host that browses                                     | None                                                                                                                                              |
| Security residue                   | Up to a day of apt lag; running browsers keep the old build until restarted | Google's "unsafe" statement stands; about 5-day gaps on releases CfT skips (2 of the last 20); no setuid fallback; download integrity is TLS only |

Option B's appeal, one binary everywhere, does not fully survive: a test set under a bump gate and a browsing build on
an hourly timer are two builds, unless tests give up the gate.

**Recommendation: Option A with the Playwright CLI, no MCP, no skill loaded by default.** The Chrome deploy is a
one-time operator step, and in exchange agents run the build Google supports and never sit on a release CfT skipped. The
tool choice follows from this fleet: every setting reaches the Playwright CLI through the environment on both machines,
including the per-agent session, and it has the smallest `--help` and MCP surface. Its token cost is tied with Chrome
DevTools. Chrome DevTools stays the tool to reach for when a task needs performance traces, Lighthouse, or heap
snapshots. agent-browser is the choice if Brett wants a domain allowlist and content boundaries more than he wants a
slow-moving dependency, used without its skill and with its executable path set.

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

Who opens pages Brett does not control, what they run today, and where each goes under the recommendation.

| Consumer                                                            | Machine                         | Pages it opens                                                      | Browser today                            | Sandbox today                               | Under the recommendation                                                                                |
| ------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| gstack browse (`/browse`, `/qa`, `/scrape`, handoff, cookie import) | Linux, 1.94.33.0                | Arbitrary URLs, credentialed sessions too                           | CfT 156.0.8078.4                         | On, through the dotfiles AppArmor profile   | Launcher over Chrome, sandbox on (R9)                                                                   |
| gstack browse, headed                                               | Mac, 1.93.42.0                  | Same; its skill prefers Aside there                                 | CfT 151.0.7922.34                        | On                                          | System CfT set, side panel works (R6)                                                                   |
| crawl4ai CLI and skill scripts                                      | Linux, 0.9.5                    | Arbitrary sites                                                     | CfT 156.0.8078.4                         | Off unless `CRAWL4AI_CHROMIUM_SANDBOX=true` | Chrome where installed, sandbox and certificate checks on (R7)                                          |
| crawl4ai CLI                                                        | Mac, 0.7.7 on Playwright 1.56.0 | Arbitrary sites                                                     | None found in the cache for 1.56.0       | Off                                         | Moves to a release at or above 0.9.5, then as Linux (R7)                                                |
| Agent CLI, new                                                      | Both                            | Arbitrary sites                                                     | Not installed                            | n/a                                         | Launcher over Chrome (R9, R10)                                                                          |
| Ad hoc agent scripts                                                | Both                            | Arbitrary sites                                                     | Default pinned build with `--no-sandbox` | Off                                         | Launcher by guidance (R11); a script that ignores it gets the system set, never older than a bump cycle |
| Puppeteer downloads in `~/.cache/puppeteer`                         | Linux                           | No consumer identified; agent-browser's auto-detect would find them | CfT 133.0.6943.141, 150.0.7871.24        | Unknown                                     | Identified, then repointed or removed (Deferred)                                                        |
| Codex browser plugin, Cursor `browser-tools-mcp@1.2.0`              | Mac                             | Arbitrary sites                                                     | Mac's Chrome                             | On                                          | Unchanged                                                                                               |
| e2e suites: lmgroktfy, agentnative-site, meum-sites, streamsgrp     | Linux                           | Own builds and own staging                                          | CfT 151 locally; CfT 149 in CI           | Off                                         | System CfT set (R5); CI per the fourth question                                                         |
| Lighthouse CI (agentnative-site, meum-sites)                        | Linux                           | Own site                                                            | Cannot launch locally                    | Off by config                               | `CHROME_PATH` to the set's binary (Deferred)                                                            |

### Key Decisions

- **One physical build, aliased per revision.** The set holds one CfT build, its headless shell, one WebKit, and ffmpeg.
  Every revision resolves to them. Real suites at 1.61.1 and 1.64.1 passed as they do on their pins, and the alias
  mechanism is already live for 1228. Governs R1, R2, R5, R6, R7.
- **Aliases run ahead of today's revisions.** A forward range of symlinks serves a revision that does not exist yet, so
  a Dependabot bump of `@playwright/test` works on the day it lands, and a repo's Playwright version stops being
  something dotfiles tracks. Governs R2.
- **The version is pinned in the repo, and a job bumps it.** Machines run the same dotfiles version, so the pin belongs
  in dotfiles. A scheduled job proposes the newest CfT Stable the gate allows, and the real suites run before it merges.
  This follows the bump pattern in `docs/plans/2026-11-02-2155-feat-yazi-plugin-auto-bump-plan.md`. Governs R4.
- **The bump records a hash.** CfT publishes none, so the bump writes the sha256 of each archive it verified into the
  pin, and hosts check against it. Governs R3, R4.
- **Tests and untrusted browsing get separate decisions.** Reproducibility and security pull a browser's update cadence
  in opposite directions. Governs R4, R9, R13.
- **gstack's headed sessions run on CfT in every option.** The side panel needs `--load-extension`, which CfT honors and
  Chrome blocks (measured). Governs R6.
- **One launcher is the single point of hardening.** gstack's headless path, agent-browser, and any script that forgets
  `chromiumSandbox: true` have no setting that reaches all five conditions. A launcher that strips those flags and
  `exec`s the binary covers them with one small file, and it keeps the per-OS browser path in one place. Governs R9,
  R10, R11.
- **Tests stay outside the launcher.** Suites use the raw alias path: their pages are trusted, and background network
  traffic and component downloads would make runs less hermetic. Governs R5.
- **CLI, not MCP, for agents.** Benchmarked at 1.5 to 5 times less input than MCP for the same job, and an MCP schema
  sits in context for the whole session. Governs R10.
- **Per-agent sessions by environment.** All three tools default to one shared browser across agents on a host, which
  would mix tabs and cookies across slots (measured on Chrome DevTools). The session variable is set wherever an agent's
  environment is built. Governs R10.
- **The install is per host for Chrome, and shared for the set.** The repo deploys to many headless servers that run no
  browser, so the Chrome deploy is opt-in per host. A host without it keeps the set's behavior. Governs R13, R15.
- **The Mac keeps Google's own updater.** Chrome there is outside Homebrew, and the cask declares `auto_updates`.
  Governs R14.
- **Dotfiles adds no AppArmor profile for Chrome and needs no new one for CfT.** Ubuntu's `chrome` profile covers the
  install path, and the existing `chromium-*` glob covers the set when its directories keep that prefix. Governs R3,
  R13.

### Requirements

**System browser set**

- R1. Each host that deploys it, the Linux server and the Mac alike, holds exactly one CfT build (full and headless
  shell), one WebKit build, and ffmpeg in `$PLAYWRIGHT_BROWSERS_PATH`, at versions named once in dotfiles.
- R2. Every Playwright revision a consumer at 1.57 or later asks for resolves to that build through an alias, for
  Chromium and WebKit, including revisions newer than the set. Each alias directory carries the install markers.
- R3. `playwright install` in any consumer is a no-op and deletes nothing. The set survives a consumer's cleanup through
  one `.links` client per aliased revision, numeric names on its real directories (cleanup parses revisions as
  integers), and `PLAYWRIGHT_SKIP_BROWSER_GC` as a second layer. Provisioning verifies each archive against its recorded
  sha256 and keeps the `curl` plus `unzip` path, because node's extractor deadlocks on this kernel.
- R4. dotfiles moves the set on its own schedule with no repo involved. A weekly job on the Linux server runs the
  candidate and the current build through the real suites, and opens a PR only when the failing set does not grow. A
  deploy flips aliases atomically and keeps the previous build until the next deploy. A check that changes nothing fails
  when a host's set differs from the pin or the pin is older than a stated age, names the fix command, and carries a
  stable reason and the values it compared.

**Consumers**

- R5. Each e2e suite runs locally on the set with no change to its Playwright config or its version pin.
- R6. gstack browse resolves to the set with no pointer and no patch, in every launch path including its install probes.
  Its headed sessions load the side panel on CfT.
- R7. crawl4ai resolves to the set with no per-caller browser setting. `CRAWL4AI_CHROMIUM_SANDBOX=true` is exported
  wherever the sandbox can work. Covered callers set `ignore_https_errors` off. With Chrome installed, covered callers
  also set the Chrome channel.
- R8. No browsing consumer on either machine passes `--no-sandbox` outside a context where the sandbox cannot work
  (root, a container, CI).

**Agent browsing**

- R9. A dotfiles-owned launcher on PATH drops `--no-sandbox`, `--disable-setuid-sandbox`, `--disable-component-update`,
  `--disable-background-networking`, and every `--ignore-certificate-errors*` form, then `exec`s the agent browser, so
  the browser keeps the caller's pipes and AppArmor's path match. It refuses to run as root, naming why, because the
  browser's sandbox cannot start there. It reads the browser's path from one variable that shell config exports only
  when the binary exists, and it holds no path of its own. gstack's Linux pointer, the agent CLI, and the guidance all
  name the launcher. When the browser is absent it exits before opening a page, says the host has no agent browser, and
  names the deploy command.
- R10. The agent CLI chosen in the second question installs at an exact version the gate allows, with its update notices
  and any telemetry off, and each agent gets its own browser through an environment variable. Its output directory is
  outside the working tree.
- R11. The guidance agents read before opening a page routes them: read a page with `defuddle`, scrape with crawl4ai,
  interact with the agent CLI, run product QA with gstack. It says never to run `playwright install`, never pass
  `--no-sandbox`, never install a browser tool at `@latest`, and to script any job that repeats. That guidance is the
  always-loaded `stow/claude/dot-claude/CLAUDE.md`, the CLI tools guide, and the browser-related skills.
- R12. An agent browser on the Linux server runs renderers with their own user and PID namespaces and seccomp filter
  mode, rejects the compromised-CA host from launch, and rejects a revoked certificate within two minutes of launch with
  a context open.

**If Option A: Chrome**

- R13. The Linux server has Chrome stable from Google's signed apt repository at its standard path, declared in dotfiles
  and applied by a deploy script the operator runs on each host that needs it. It updates without operator action within
  a day of Google publishing to its index: an `Origins-Pattern` drop-in adds Google's origin to unattended upgrades, and
  a drop-in on `apt-daily-upgrade.service` refreshes Google's list first.
- R14. The Mac keeps its existing Google-updated Chrome. Dotfiles neither installs a second copy nor moves it under
  Homebrew.
- R15. A host without Chrome keeps its consumers on the set, never exports a pointer to an absent binary, and notes the
  absence without failing. `GSTACK_CHROMIUM_PATH` is set only where the browser exists and only where headed sessions do
  not run.
- R16. The check in R4 also fails when an installed Chrome is older than a build an unattended run has had the chance to
  install, or when unattended upgrades do not cover it. A newer build than the last run is noted as pending. It reports
  any running browser on a replaced executable and names the restart, without restarting anything.

**If Option B: CfT only**

- R17. A user-level timer on each browsing host polls CfT's Stable channel hourly and installs the browsing build beside
  the set. The check in R4 fails when that build is more than a day behind. The launcher points at that build. Its
  components config is not used, so an update-server outage cannot stop browser launches.

**Provisioning cleanup**

- R18. No AppArmor grant stays deployed on a host for a browser path nothing on that host launches with its sandbox on.
  `config/apparmor.d/playwright` stays while the set runs sandboxed anywhere.

**Docs**

- R19. The always-loaded `CLAUDE.md`, the Playwright runbook, the CLI tools guide, and the solutions docs on Playwright
  launch describe the set, the launcher, and the browsing build as they are, and state the boot-time AppArmor behavior
  as measured.

### Acceptance Examples

- AE1. **Covers R2, R5.** **Given** the set is deployed at any CfT version, **when** lmgroktfy, meum-sites, and
  agentnative-site run their suites from a checkout with no local changes, **then** they pass as they do on the previous
  build and no file under `$PLAYWRIGHT_BROWSERS_PATH` changes.
- AE2. **Covers R1, R6.** **Given** the set is deployed on the Mac, **when** gstack's headed session opens, **then** the
  side panel loads, and a suite passes there.
- AE3. **Covers R2.** **Given** a repo bumps `@playwright/test` to a release newer than the set's last deploy, **when**
  its suite runs, **then** it runs on the set with no dotfiles change and no download.
- AE4. **Covers R3.** **Given** another tool runs `playwright install chromium`, **when** it finishes, **then** the set
  is intact and nothing downloaded. **Given** an archive whose hash differs from the pin, **when** provisioning runs,
  **then** it stops, names both hashes, and leaves the existing set in place.
- AE5. **Covers R4.** **Given** a candidate CfT build that fails a real suite, **when** the bump job runs, **then** the
  pin does not move and the job reports which suite failed.
- AE6. **Covers R6.** **Given** the set is deployed and no gstack variable is set, **when** `gstack-browser-ensure`
  runs, **then** it prints `BROWSER_OK` with the set's version and fetches nothing.
- AE7. **Covers R7, R8.** **Given** crawl4ai under the shell's defaults, **when** it crawls a page, **then** its
  browser's command line carries no `--no-sandbox`. **When** a covered caller crawls `https://expired.badssl.com/`,
  **then** the crawl fails with a certificate error.
- AE8. **Covers R9, R12.** **Given** the launcher and the agent browser are installed, **when** a default Playwright
  launch names the launcher as its executable, **then** renderers run in their own user and PID namespaces,
  `dv-g3b-emudhra.we-have-a-problem.com` fails at once, and `revoked.badssl.com` fails within two minutes.
- AE9. **Covers R9.** **Given** a host without the agent browser, **when** an agent launches through the launcher,
  **then** it exits before opening any page, names the deploy command, and never suggests `playwright install chrome`.
- AE10. **Covers R10.** **Given** two agents on one host, **when** each opens a page through the agent CLI, **then**
  neither sees the other's tabs, and neither working tree gains a file.
- AE11. **Covers R13, R16.** **Given** Google publishes a new stable build, **when** the host's next daily
  unattended-upgrade run completes, **then** the installed version matches it. **Given** Google's origin is missing from
  the unattended-upgrade configuration, **when** the check runs after an unattended run had the chance to install a
  build, **then** it exits non-zero with a stable reason, the file it read, and the deploy command.
- AE12. **Covers R16.** **Given** a gstack browse daemon started before an unattended upgrade replaced Chrome, **when**
  the check runs, **then** it names that process and the restart command.

### What Happens to the Pinned-Browser Machinery

| Item                                                                                                  | Today                                                 | Under this plan                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/playwright-browsers-deploy.sh`                                                               | A revision map per Playwright version                 | One pin (CfT version, WebKit revision, ffmpeg revision, hashes) and an alias range; no per-version map                                                              |
| `CONSUMER_CHROMIUM_REVS`                                                                              | Hand-kept list, 1223 and 1228                         | Replaced by the range                                                                                                                                               |
| PR #431's `.links` registration and `--check`                                                         | Registers the whole set                               | Kept and extended to the alias range; `--check` grows into R4's check                                                                                               |
| gstack's own `playwright install chromium`                                                            | Fetches 1248 when its probe fails                     | Never fires: its probe passes on the alias                                                                                                                          |
| `PLAYWRIGHT_BROWSERS_PATH`, `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`                                        | One shared cache; no auto-download on `bun install`   | Both stay; `PLAYWRIGHT_SKIP_BROWSER_GC` joins them                                                                                                                  |
| `config/apparmor.d/playwright`, `apparmor-playwright.service`                                         | Grant `userns` to `chromium-*` and the headless shell | Stay: the glob covers the set's directories and aliases                                                                                                             |
| `scripts/playwright-deps-deploy.sh`                                                                   | Binaries, AppArmor, opt-in apt deps                   | Keeps its role. Its `--chromium` flag, which runs `bun x playwright install --with-deps chromium` and downloads a browser, is replaced by installing the deps alone |
| `docs/solutions/tooling-decisions/browsing-agents-run-stable-chrome-not-a-playwright-pinned-build.md` | States that nothing headless receives a CRLSet        | Updated: the flag is the blocker, and one flag's removal restores it on both builds                                                                                 |

### Scope Boundaries

- Chrome stable is never the test suites' browser. It moves on Google's schedule, which is the drift the set exists to
  prevent, and it has no headless shell.
- Firefox is not in the set; no consumer launches it.
- Playwright MCP is not adopted. If one is ever added, it is pinned to an exact gate-cleared version at or above 0.0.40.
- Browsers in containers or as root keep the sandbox off by necessity. None of the consumers found runs one in a
  container.
- Lifting `kernel.apparmor_restrict_unprivileged_userns` host-wide
  (`docs/plans/2026-09-15-1428-feat-unprivileged-userns-host-plan.md`) is independent of this plan.
- The GStack Browser app on the Mac, a custom Chromium build, and gstack's Aside path are out of scope.
- emdash (an upstream third-party clone) and cf_office_hours (no Playwright config) are out of scope.
- Microsoft Edge is not proposed.
- Running each agent browser on Claude Code end to end was not done, so token cost rests on the benchmark plus the sizes
  measured here.

### Dependencies / Assumptions

- **PR #431 merges before the provisioning work.** The `.links` registration, the deploy script's `--check`, and
  `tests/playwright-browsers-deploy.bats` exist only on that branch.
- **gstack upstream.** A gstack issue draft (its probes ignore `GSTACK_CHROMIUM_PATH`; its install deletes other tools'
  browsers) is pending with Brett. The alias removes this plan's dependence on the first half, and `.links` with
  `PLAYWRIGHT_SKIP_BROWSER_GC` covers the second. The launcher covers gstack's headless `--disable-component-update`,
  which issues garrytan/gstack#3338 and #3440 raise.
- **Aliasing depends on Playwright's layout.** A Playwright that moves its executable path breaks the alias for that
  release. `--check` and the bump's suite run catch it before machines pull it.
- **CfT keeps publishing a headless shell and Stable channel data.** Both come from Google's public JSON API.
- **WebKit drift is measured on one project set.** agentnative-site's flows are the only WebKit consumer. A failure
  there drops back to one real WebKit directory per revision for that release, the one place the set might grow.
- **Ubuntu keeps shipping its `chrome` AppArmor profile** (Option A). If a later release drops it, Google's deb installs
  its own.
- **Removing `--disable-background-networking` lets the agent browser reach Google's services in the background.** That
  is the price of Safe Browsing, and it applies only behind the launcher.

### Outstanding Questions

**Resolve Before Planning (Brett)**

1. **What do agents browse with on pages nobody vetted?** (a) Chrome stable behind the launcher, with CfT for tests and
   gstack's headed sessions. (b) CfT only, no Chrome, with an hourly timer and the launcher. Recommendation: (a). This
   answers "no chrome?": tests and gstack's headed sessions do not need Chrome, and untrusted browsing is the one place
   it earns its one-time deploy. Google calls CfT unsafe for untrusted sites, and 2 of the last 20 stable releases (41
   and 11 security fixes) never got a CfT build, leaving it about 5 days behind. (b) is workable: CfT receives CRLSet
   and Safe Browsing the same way once the flags are gone. It keeps those two risks and needs no `sudo`.
2. **Which tool do agents drive it with?** (a) Playwright CLI. (b) Chrome DevTools CLI. (c) agent-browser, without its
   skill. (d) No new tool: gstack browse and crawl4ai only. Recommendation: (a). Token cost is a near tie across the
   CLIs, and MCP is what costs more. The Playwright CLI takes all its settings from the environment on both machines,
   has the smallest help and schema, and separates agents with one variable. (b) has the strongest defaults (sandbox on,
   CRLSet not blocked, smallest snapshot) but needs a per-agent `XDG_RUNTIME_DIR` and sends usage statistics unless told
   not to. (c) is the only one with a domain allowlist and content boundaries, and it released 6 times in 9 days. (d)
   adds nothing to maintain; agents outside gstack's skills would call `browse` directly, and its skill file is 34,684
   characters.
3. **How does the seven-day gate apply to browser builds?** (a) The test set stays under the gate (the bump takes the
   newest CfT Stable at least seven days old), the agent browser is exempt by name in the supply-chain guide, and the
   agent CLI stays under the gate at an exact pin. (b) Every browser build is exempt, and the test set follows stable as
   soon as the suites pass. (c) No exemption. Recommendation: (a). Tests open only their own pages, so a week's lag
   costs nothing and gives regressions time to surface. The builds the gate would delay on the browsing side are the
   ones fixing exploited bugs, and Google's apt index serves only the newest build, so holding Chrome back means
   mirroring old debs. The gate's threat, a malicious upload to an open registry, does not match a vendor-signed
   repository. (c) leaves agents a week behind on exploited-in-the-wild fixes.
4. **Does CI join the set?** (a) CI stays as it is: each repo's workflow runs `playwright install` for its pinned build.
   (b) CI downloads the set's CfT version through a shared action, so local and CI run one build. Recommendation: (a)
   for now. CI is not the system dotfiles owns, and no suite here has screenshot assertions or failed across the 149 to
   157 gap. The cost is that a browser-version bug can pass locally and fail in CI, or the reverse. Choose (b) when that
   first happens. If Brett reads "repos use what's available on the system" as covering CI, (b) is the change: one
   action in `brettdavies/.github` plus a line in each of four workflows.

**Deferred to Planning**

- **The first execution gate.** After the first deploy and before any consumer moves: does CfT at its real path start
  with its sandbox on (R12), and under Option A does Chrome at `/opt/google/chrome/chrome`? A failure takes the Goal
  Capsule's stop condition.
- How a host picks up a moved pin. Hosts need a daily user-level timer or a post-merge step, because a 330 MB download
  does not belong in `git pull`.
- The alias range's bounds. A forward range for both Chromium and WebKit is about 400 symlinks and as many `.links`
  clients.
- Where the shell-config block that owns the launcher's target lives, and which crawl4ai callers dotfiles configures:
  the crawl4ai skill's scripts and browser template, `crwl` through `-b` or `-B`, and each importing repo such as
  scrawl2. crawl4ai's CLI result on an expired certificate was inconclusive here: both settings ended in the same
  `NoneType` error, so AE7 measures it properly. crawl4ai's managed-browser modes resolve their binary through
  `~/.crawl4ai/chromium.path` rather than `chrome_channel`.
- Which variable names the per-agent session, and where it is set: the agent-slot launcher knows the slot's key, and an
  interactive shell needs a default.
- What populated `~/.cache/puppeteer` (bun's cache holds puppeteer 24.43.1), and whether that tool gets
  `PUPPETEER_EXECUTABLE_PATH` or the cache goes. agent-browser's auto-detect would find it if ever installed without its
  path set.
- Lighthouse CI's local path: `CHROME_PATH` to the set's binary, or to Chrome under Option A.
- The Mac's crawl4ai moves from 0.7.7 to a release at or above 0.9.5, and planning lists each importing repo's version.
- When the check runs unattended and where a failure shows: the repo already surfaces host checks at session start
  (`failed-user-units.sh`), silent when they pass.
- Whether `apparmor.service` runs on every boot of this host or only some, which decides how much the setuid fallback
  matters.

### Sources / Research

- Repo: `scripts/playwright-browsers-deploy.sh`, `scripts/playwright-deps-deploy.sh`, `config/apparmor.d/playwright`,
  `config/systemd/system/apparmor-playwright.service`, `config/shell/caches.sh`, `config/shell/supply-chain.sh`,
  `docs/runbooks/playwright-browser-launch.md`, `stow/claude/dot-claude/guides/cli-tools.md`, PR #431
  (`fix/playwright-cache-gc-guard`, open).
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

### Engineering Review (plan-eng-review, 2026-11-03)

The review ran unattended in an agent slot, with no question tool. Each choice below was auto-decided on its
recommendation, under the slot's standing instruction to settle review questions from code, docs, and precedent and
record them here. Brett's four Outstanding Questions are not review decisions and stay open. Evidence kinds:
`coreBundle.js`, `scripts/`, and #431's branch are static reads; the Measured sections of the plan are live runs in
scratch directories. Proposed files are proposals, and no product code ran.

#### Scope Challenge

- **What already exists:** the alias mechanism (`link_consumer_alias`,
  `scripts/playwright-browsers-deploy.sh:223`); #431's per-alias `.links` clients and `--check`; the copy-deploy shape
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

- S1. [INFORMATIONAL] (confidence: 9/10) `scripts/playwright-browsers-deploy.sh:117` reads
  `if [ "$(uname -s)" != "Linux" ]; then` and exits 0 with "these are linux64 builds", so the script provisions nothing
  on the Mac, yet R1 and AE2 name the Mac. Disposition: accepted (D2): R1 now requires macOS provisioning from the same
  pin, and the Mac's archive names enter the deploy.
- S2. [INFORMATIONAL] (confidence: 9/10) `scripts/playwright-browsers-deploy.sh` on `dev` has no `--check` and
  `tests/playwright-browsers-deploy.bats` does not exist. They live on #431's branch. Disposition: no change;
  Dependencies already says #431 merges first.

Reality rows:

- `REALITY: premise-table finding about 70 premises [estimated], unverified=5 (CfT 157 sandbox at the covered path,
  launcher over Chrome, launcher on the Mac, Chrome sandbox at /opt, crawl4ai sandbox from /proc)
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1`
- `REALITY: already-done pass no commit on origin/dev since 2026-11-03 touches the named Playwright, AppArmor, or
  shell-cache files; #431 is open scripts/playwright-browsers-deploy.sh:1`
- `REALITY: surface-check pass every named variable and flag was exercised or read: PLAYWRIGHT_MCP_EXECUTABLE_PATH,
  _SANDBOX, _CONFIG, _OUTPUT_DIR, PLAYWRIGHT_CLI_SESSION, NO_UPDATE_NOTIFIER, AGENT_BROWSER_EXECUTABLE_PATH, _SESSION,
  --chrome-for-testing-config, PLAYWRIGHT_SKIP_BROWSER_GC (playwright-core 1.61.1 lib/coreBundle.js line 29090)
  scripts/playwright-browsers-deploy.sh:113`
- `REALITY: binding-decisions pass recorded eng decisions for this plan's earlier shape (conditional pointer, per-host
  install, report-not-restart, one path owner) are carried into R15, R16, and the launcher; Brett's direction outranks
  the pin-in-CI default and CI is asked as a question
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1`
- `REALITY: numbers pass suite counts and times from JSON reporter and GNU time; lag table from chromiumdash and
  chrome-for-testing git history; sizes from du and wc [measured]; about 20 files and about 400 symlinks [estimated]
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1`
- `REALITY: deferred-asks finding the brief asked for real-suite runs per consumer; streamsgrp opens no browser,
  crawl4ai ran through its CLI with no upstream suite, gstack ran 10 of its test files, the Mac ran nothing because this
  research is read-only there docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1`
- `REALITY: pr-count finding no ship policy on file, so the default is one PR per wave; this plan needs three dotfiles
  PRs (set, agent path, Chrome deploy) for review size and to keep the set independent of Brett's first two answers
  docs/plans/2026-11-03-1526-feat-stable-chrome-for-browser-consumers-plan.md:1`

#### 1. Architecture

```text
 dotfiles pin: CfT version, WebKit and ffmpeg revisions, sha256 of each archive
      ▲ bump job (Linux server, weekly): newest allowed CfT, real suites, PR to dev
      │
 host timer ──▶ scripts/playwright-browsers-deploy.sh ──curl, unzip, sha256──▶ $PLAYWRIGHT_BROWSERS_PATH
                                                          chromium-<N>/  chromium_headless_shell-<N>/  webkit-<N>/
                                                          chromium-<rev> ─▶ chromium-<N>  (range; each with a .links client)
      ┌───────────────┬───────────────────┬───────────────────┐
      ▼               ▼                   ▼                   ▼
  e2e suites     gstack probes,      crawl4ai default    any other default
  (raw alias)    gstack headed       channel             chromium.launch()

 shell config: [ -x <agent browser> ] ─▶ DOTFILES_AGENT_BROWSER_BIN and the tool pointers (unset when absent)
      ┌──────────────────┬────────────────────┐
      ▼                  ▼                    ▼
  agent CLI        gstack headless       agent scripts
      └──────────────────┴────────────────────┘
                         ▼
        launcher: refuses root, strips flags, exec ─▶ Chrome (Option A) or CfT (Option B)
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
  removed mid-session, reload, new page, new context, cross-site navigation, screenshot, and PDF all still worked. So a
  flip does not break a running browser, and no `/proc` gate is needed before removal. A browser starting at the moment
  of a flip could still read files from the old path. Disposition: accepted (D4): R4 flips aliases atomically and keeps
  the previous build until the next deploy, with no process scan.
- A3. [INFORMATIONAL] (confidence: 8/10) The plan's "reads the browser's path from one place" left the owner unnamed. A
  path table inside a stowed launcher and a second `[ -x ]` in shell config would be a hand-synced list (red flag 8).
  Stowed scripts cannot source repo-relative files. Disposition: accepted (D5): shell config owns the path and exports
  `DOTFILES_AGENT_BROWSER_BIN` only when the binary exists; the launcher reads that variable and has no path table. A
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

| Path            | Realistic failure                                                 | Handling                                                         | What the user sees                                     |
| --------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------ |
| Deploy download | Google's bucket serves a corrupt or swapped archive               | sha256 against the pin (AE4), test                               | Stops, both hashes named, old set intact               |
| Alias lookup    | A Playwright release moves its executable path                    | `--check` and the bump's suite run                               | `Executable doesn't exist`; `--check` names the alias  |
| Cleanup         | A tool with a scrubbed environment runs `playwright install`      | One client per alias (A1), test                                  | Nothing deleted                                        |
| Bump flip       | A daemon runs from the old build                                  | Measured safe; D4 keeps the previous build one cycle, test       | Session keeps working on the old build until restarted |
| Launcher        | Variable unset in a scrubbed environment                          | Exit with the deploy command (AE9), test                         | A named error before any page opens                    |
| Launcher        | Browser refuses `exec` under an unloaded AppArmor profile at boot | `FATAL ... No usable sandbox!` on CfT; setuid fallback on Chrome | Named failure, never an unsandboxed page               |
| Chrome apt      | Google's origin dropped from unattended upgrades                  | R16 check (AE11), test                                           | Session-start failure with the fix                     |
| CRLSet          | A session shorter than a minute                                   | No handling; compiled-in distrust still applies                  | Silent: a revoked-only certificate loads               |

The last row is silent with no test, and it is an accepted limit of both builds rather than a gap this plan can close:
the plan states it, and no consumer is told otherwise. Critical gaps: 0.

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
[+] scripts/playwright-browsers-deploy.sh (on #431)     [+] A repo runs its suite
  ├── [GAP] missing or malformed pin → usage error        ├── [GAP] [→E2E] set deployed, suites pass (AE1, live)
  ├── [GAP] sha256 mismatch → stop, keep the set          └── [GAP] [→E2E] newer Playwright, no dotfiles change (AE3, live)
  ├── [GAP] Linux and macOS archive names               [+] Another tool installs
  ├── [GAP] range aliases; real dir left alone            └── [GAP] [→E2E] playwright install, set intact (AE4, live)
  ├── [GAP] one client per alias, numeric names         [+] gstack
  ├── [GAP] deploy keeps the previous build               ├── [GAP] [→E2E] probe prints BROWSER_OK (AE6, live)
  └── --check                                             └── [GAP] [→E2E] headed side panel on the Mac (AE2, live)
      ├── [GAP] pin differs, pin too old                [+] Agent on an untrusted page
      └── [GAP] alias or client missing                   ├── [GAP] [→E2E] sandboxed, compromised CA refused (AE8, live)
[+] launcher (new)                                        ├── [GAP] [→E2E] two agents kept apart (AE10, live)
  ├── [GAP] strips each flag, keeps the rest whole        └── [GAP] [→E2E] crawl4ai sandbox and cert (AE7, live)
  ├── [GAP] pipes survive exec (fds 3 and 4)            [+] Host without the agent browser
  ├── [GAP] variable unset → ERROR plus deploy command    └── [GAP] [→E2E] stops before any page (AE9, live)
  └── [GAP] root → refuses                              [+] Chrome upgrade (Option A)
[+] shell-config block (new)                              └── [GAP] [→E2E] unattended run installs (AE11, live)
  ├── [GAP] binary present → exports set
  ├── [GAP] binary absent → nothing exported (REGRESSION, CRITICAL)
  └── [GAP] Mac path with spaces stays whole
[+] bump script (new)
  ├── [GAP] failing set grows → no PR, names the suite (AE5)
  └── [GAP] candidate younger than the gate → no change
[+] Chrome check, Option A (new)
  └── [GAP] stale, origin missing, replaced executable, absent → note

COVERAGE: 0/25 paths tested (all new)  |  Code paths: 16/25  |  User flows: 9/25
QUALITY: none yet  |  GAPS: 25 (9 live E2E, 0 eval)
```

Proposed tests, with value cards in the Test Plan artifact: extend `tests/playwright-browsers-deploy.bats` (from #431)
for the pin, hash, range, clients, numeric names, and `--check`; a new `tests/agent-browser-launcher.bats` over a stub
browser for the flags, pipes, unset variable, and root; pointer cases in `tests/shell-config.bats`; a new
`tests/browser-set-bump.bats` over fixture suite results; `tests/chrome-deploy.bats` under Option A over fixture
Packages files and a fixture `/proc`. The live checks have no CI equivalent.

Regression contract (carried from the eng decisions recorded for this plan): a host without the agent browser keeps
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
| D5  | A3              | shell config owns the path; launcher owns it                                      | shell config | R9 wording, `DOTFILES_AGENT_BROWSER_BIN`                                                                 |
| D6  | A4              | refuse root; let Chrome fail                                                      | refuse       | R9 wording                                                                                               |
| D7  | A5              | Linux-server timer with PR; GitHub workflow                                       | timer        | R4 wording, Deferred item settled                                                                        |
| D8  | Q1              | strip every form; exact match                                                     | every form   | R9 wording                                                                                               |
| D9  | Q2              | shared report-only scan; second scan                                              | shared       | R16 implementation constraint                                                                            |

Approval readiness: PASS (D1 to D9, auto-decided under the slot's standing authorization).

#### NOT in scope

- CI joining the set: Brett's fourth question.
- Firefox, Edge, Playwright MCP, the GStack Browser app, Aside: see Scope Boundaries.
- Restarting a user's browser automatically: the checks report, because a daemon may hold a live session.
- Patching gstack or crawl4ai: the alias and launcher make it unnecessary, and the gstack issue is Brett's to file.
- End-to-end agent runs on Claude Code: the benchmark covers token cost, and a repeat would spend model budget nobody
  asked for.

#### Parallelization

| Step                   | Modules touched                                             | Depends on           |
| ---------------------- | ----------------------------------------------------------- | -------------------- |
| System set             | `scripts/`, `config/playwright/`, `config/shell/`, `tests/` | #431                 |
| Bump job and timers    | `scripts/`, `stow/systemd/`, `stow/launchagent/`, `tests/`  | system set           |
| Launcher and agent CLI | `stow/local/`, `config/shell/`, `tests/`                    | questions 1 and 2    |
| Chrome deploy          | `scripts/`, `config/`, `tests/`                             | question 1 = A       |
| Guidance and docs      | `stow/claude/dot-claude/`, `docs/runbooks/`                 | launcher, system set |

Lane A: system set, then bump job (shared `scripts/`). Lane B: launcher, then guidance. Lane C: Chrome deploy. Launch A
after #431. B and C wait on Brett's answers, then run alongside A; `config/shell/` is shared, so merge A's shell change
first. `scripts/upgrade/lib/stale-procs.sh` belongs to lane C alone.

#### Implementation Tasks

- [ ] **T1 (P1, human: ~1d / CC: ~45min)** — provisioning — one pin, alias range, per-alias clients, numeric real
  directories, macOS archives, sha256
  - Surfaced by: Architecture — A1; Scope — S1
  - Files: `scripts/playwright-browsers-deploy.sh`, `config/playwright/`, `tests/playwright-browsers-deploy.bats`
  - Verify: `scripts/run-tests tests/playwright-browsers-deploy.bats`; AE1, AE3, AE4 live
- [ ] **T2 (P1, human: ~1h / CC: ~10min)** — provisioning — flip aliases atomically and keep the previous build one
  cycle
  - Surfaced by: Architecture — A2
  - Files: the deploy script, its bats
  - Verify: bats case; a live daemon survives a flip
- [ ] **T3 (P1, human: ~3h / CC: ~20min)** — launcher — strip flags in every form, refuse root, read the shell's
  variable, `exec`
  - Surfaced by: Architecture — A3, A4; Code quality — Q1
  - Files: `stow/local/dot-local/bin/`, `config/shell/`, `tests/agent-browser-launcher.bats`, `tests/shell-config.bats`
  - Verify: `scripts/run-tests tests/agent-browser-launcher.bats`; AE8, AE9
- [ ] **T4 (P2, human: ~1d / CC: ~30min)** — bump — weekly candidate, failing-set comparison, PR
  - Surfaced by: Architecture — A5
  - Files: `scripts/`, `stow/systemd/`, `tests/browser-set-bump.bats`
  - Verify: AE5
- [ ] **T5 (P1, human: ~30min / CC: ~10min)** — live — sandbox measurement at the real paths after the first deploy
  - Surfaced by: premise table, unverified rows
  - Files: none
  - Verify: AE8

The task store also carries eight tasks from the 2026-11-03 eng review of
`docs/plans/2026-11-02-2324-feat-agent-slots-on-the-mac-plan.md`, unchanged; they are that plan's work, not this one's.

#### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 applicable rows emitted, 5 unverified premises
- Architecture Review: 5 issues found
- Code Quality Review: 2 issues found
- Test Review: diagram produced, 25 gaps identified
- Performance Review: 3 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed (no tracked TODOS file)
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 4, all the plan's Resolve Before Planning questions for Brett; none of this review's own choices
  is open
- Outside voice: codex, disabled (`codex_reviews`)
- Parallelization: 3 lanes, 2 parallel / 1 sequential
- Lake Score: N/A (no answers scored for Completeness)

## GSTACK REVIEW REPORT

| Review         | Trigger                              | Why                             | Runs | Status             | Findings                   |
| -------------- | ------------------------------------ | ------------------------------- | ---- | ------------------ | -------------------------- |
| CEO Review     | `/plan-ceo-review`                   | Scope & strategy                | 0    | —                  | —                          |
| Outside Review | codex, plan-eng-review outside voice | Independent 2nd opinion         | 1    | disabled           | —                          |
| Eng Review     | `/plan-eng-review`                   | Architecture & tests (required) | 1    | ISSUES OPEN (PLAN) | 35 issues, 0 critical gaps |
| Design Review  | `/plan-design-review`                | UI/UX gaps                      | 0    | —                  | —                          |
| DX Review      | `/plan-devex-review`                 | Developer experience gaps       | 0    | —                  | —                          |

- **OUTSIDE COVERAGE:** codex, plan-review phase, disabled by `codex_reviews`; no findings.
- **VERDICT:** no review CLEAR yet — eng review required (its findings are accepted into the plan as mapped work).

**UNRESOLVED DECISIONS:**

- what agents browse with, which agent tool, how the seven-day gate applies to browser builds, and whether CI joins the
  set (plan Outstanding Questions)
