---
title: "feat(qmd): integrate qmd-serve sequential-mode daemon into dotfiles"
type: feat
status: active
date: 2026-04-21
origin: .context/compound-engineering/todos/009-ready-p2-integrate-qmd-serve-sequential.md
---

# feat(qmd): integrate qmd-serve sequential-mode daemon into dotfiles

## Overview

Track the manually-configured qmd-serve daemon (the persistent `qmd serve --sequential` HTTP server at `127.0.0.1:7832`)
in dotfiles so it survives reinstalls and deploys to new hosts via `scripts/stow-deploy`. The service is already running
live on bigdaddy; this plan formalizes the three manual pieces (service unit, env var, binary dispatch) as stow-managed
assets and unifies three sibling qmd services (`qmd-embed`, `qmd-update`, `qmd-serve`) on a single binary-resolution
pattern.

The work reuses four established patterns shipped in PR #40 (opendataloader-pdf socket activation) — stow-managed sh
wrapper in `dot-local/bin`, hardened systemd user service, idempotent enable script under `scripts/`, and static bats
assertions with a manual smoke checklist. No new patterns are introduced.

## Problem Frame

Three pieces that were set up by hand on bigdaddy need to live in the repo (origin todo, lines 11–21):

1. `qmd-serve.service` — systemd user service at `~/.config/systemd/user/qmd-serve.service` running `qmd serve
   --sequential` (sequential-mode owns VRAM coexistence in-process — peak ~2.6 GB instead of ~5.4 GB).
2. `QMD_SERVER=http://127.0.0.1:7832` — exported so the qmd CLI routes through the daemon.
3. A stable way to invoke the **fork** `qmd` binary (`~/dev/qmd/qmd`, brettdavies/qmd `feat/ollama-backend` branch)
   instead of whatever `bun add -g qmd` installs — currently via a fragile `~/.bun/bin/qmd -> ~/dev/qmd/qmd` symlink
   that bun may overwrite.

None of this is version-controlled, so a fresh machine has to be hand-wired. This plan eliminates the hand-wiring while
also cleaning up two pre-existing inconsistencies in `stow/qmd/` uncovered during design:

- `qmd-embed.service` hardcodes `/home/brett/.bun/bin/qmd` (breaks if bun is reinstalled or the user differs).
- `qmd-update.service` uses a bare `qmd` command via `Environment=PATH=...` (works, but inconsistent with its sibling).

## Requirements Trace

- **R1.** `qmd-serve.service` lives in `stow/qmd/dot-config/systemd/user/` and deploys via `scripts/stow-deploy` without
  manual steps. (origin: Acceptance Criteria #1, #3)
- **R2.** `QMD_SERVER` is exported in all shell contexts (interactive, non-interactive zsh, cron, Claude Code, systemd
  child processes that source `.profile`) and tracked in the repo. (origin: Acceptance Criteria #2; origin Revision 1;
  CLAUDE.md "Shell Config Chain")
- **R3.** The qmd binary used by both humans and services resolves to the brettdavies/qmd fork without relying on a
  bun-owned symlink that bun can overwrite. (origin: Findings bullet 3; origin Revision 2)
- **R4.** Activation on a fresh host (or after a reboot that clears manual state) is a single idempotent script.
  (origin: Revision 3)
- **R5.** Static assertions plus a manual smoke checklist prove the package shape is correct and describe the live-run
  verification that CI can't do. (origin: Revision 4)
- **R6.** All three qmd services (`qmd-embed`, `qmd-update`, `qmd-serve`) use the same binary-resolution pattern. (new,
  flagged in planning discussion — section "Key Technical Decisions" below)
- **R7.** `qmd-embed.service`'s Ollama-unload `ExecStartPre` is reviewed and removed iff confirmed redundant with
  `qmd-serve`'s sequential VRAM ownership. (origin: "Opportunistic scope" block)

## Scope Boundaries

- Not a socket-activated service. Unlike opendataloader-pdf, qmd-serve stays always-on — sequential mode owns VRAM
  coexistence in-process. (origin: note after "Approved 2026-04-21.")
- No idle-exit. qmd-serve must stay resident to keep models warm.
- No bootstrap-from-scratch script that clones the fork. (origin: "Why NOT the full bootstrap script (Option 2)")
- No PATH reorder in `.profile`. `~/.bun/bin` still wins over `~/.local/bin` globally — the enable script handles the
  one-shot shadow removal. Broader PATH policy is out of scope. (user decision 3a, this session)
- No cleanup of `config/shell/local-paths.sh`'s redundant Bun prepend. Spun off as todo 015. (user instruction, this
  session)

### Deferred to Separate Tasks

- **Fork launcher script commit to `brettdavies/qmd`.** The `~/dev/qmd/qmd` bash launcher was hand-written; it should
  live in the fork repo. Tracked on the fork, not here. (origin: Deferred/still-open bullet 1)
- **Fork URL/branch pinning & upstream PR #511 follow-up.** If upstream lands sequential mode, flip the wrapper back to
  upstream; revisit post-ship. (origin: Deferred/still-open bullet 2)
- **PATH-prepend dedupe in `config/shell/local-paths.sh`.** Redundant with `.profile`; spun off as todo
  `015-pending-p3-dedupe-path-prepends-local-paths-sh.md`.

## Context & Research

### Relevant Code and Patterns

- **Closest sibling pattern (ratified in PR #40):** `stow/opendataloader-pdf/`
- `dot-local/bin/opendataloader-pdf-hybrid-sa` — sh wrapper that `exec`s `$HOME/.local/share/uv/tools/.../python` with
  arguments. Identical shape as what this plan introduces for `qmd`.
- `dot-config/systemd/user/opendataloader-pdf.service:8` — `ExecStart=%h/.local/bin/opendataloader-pdf-hybrid-sa ...`.
  Uses systemd's `%h` specifier, not a hardcoded path.
- `dot-config/systemd/user/opendataloader-pdf.service:10-14` — hardening (`Restart=on-failure`, `RestartSec=5`,
  `NoNewPrivileges=true`, `PrivateTmp=true`). qmd-serve inherits this shape; qmd-embed/update already have the subset
  they need.
- **Enable script template:** `scripts/opendataloader-pdf-enable.sh`. Line-for-line structure qmd-serve-enable will
  mirror — Linux gate, port detection, idempotent systemd enable, `/health` smoke with 30 s budget, error path that
  prints recent journal logs.
- **bats template:** `tests/opendataloader-pdf.bats`. Static assertions + commented-header manual smoke checklist.
- **Existing qmd package (what changes, what doesn't):**
- `stow/qmd/dot-config/systemd/user/qmd-embed.service:10` — `ExecStart=/home/brett/.bun/bin/qmd embed` **must change
  to** `ExecStart=%h/.local/bin/qmd embed`.
- `stow/qmd/dot-config/systemd/user/qmd-embed.service:9` — `ExecStartPre` Ollama-unload HTTP call; review and remove iff
  redundant (R7).
- `stow/qmd/dot-config/systemd/user/qmd-update.service:7` — `ExecStart=/bin/sh -c 'qmd cleanup 2>/dev/null; qmd update'`
  **must change to** `ExecStart=/bin/sh -c '%h/.local/bin/qmd cleanup 2>/dev/null; %h/.local/bin/qmd update'` for
  pattern unification. `Environment=PATH=...` line (line 6) becomes unnecessary but can stay — belt-and-suspenders.
- `qmd-embed.timer` / `qmd-update.timer` — untouched; timers orchestrate, don't execute.
- **Shell env authority:** `stow/shell/dot-profile:147-150` currently holds the `QMD_SERVER` export directly. Convention
  in `config/shell/*.sh` is feature-named files (`caam.sh`, `gogcli.sh`, `python.sh`, `models.sh`, `telemetry.sh`).
  Moving to `config/shell/qmd.sh` aligns with that convention.
- **Shared-package registration:** `scripts/stow-deploy:23` already lists `qmd`. No change needed.
  `scripts/stow-deploy:265` already gates `qmd` as Linux-only. No change needed.
- **`tests/stow-deploy-packages.bats:22,26`** already assert `qmd` is in SHARED_PACKAGES and in the Linux-only block. No
  change needed.

### Institutional Learnings

- **`docs/solutions/deployment-issues/systemd-socket-activation-uv-tool-python-service-2026-04-21.md`** — the ODL
  solution doc. Pattern lessons that transfer to qmd-serve (sh wrapper, `%h/.local/bin/...` ExecStart, Linux-gated
  idempotent enable script, hardening flags, bats + manual-smoke split). Pattern lessons that **don't** transfer: socket
  activation and idle-exit (qmd-serve is always-on).
- **`docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`** — stow dot-prefix + Linux-only gate
  pattern already embedded in `scripts/stow-deploy`.
- **`docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`** — zsh vs bash startup file matrix.
  Reinforces: `QMD_SERVER` must live somewhere sourced by `.profile` (so non-interactive zsh and systemd-invoked scripts
  see it).

### External References

- None. This is a dotfiles reorganization around established systemd/stow patterns; no new external tech.

## Key Technical Decisions

- **`QMD_SERVER` location: `config/shell/qmd.sh`, not `.profile`.** (user decision 1a, this session)
- Rationale: `config/shell/*.sh` uses feature-named files by convention. `.profile` should carry only base plumbing
  (Homebrew, PATH skeleton, GPG_TTY). Feature env vars belong in `config/shell/<tool>.sh`.
- Net movement: delete 4 lines from `stow/shell/dot-profile`, create `config/shell/qmd.sh` with the same export and
  comment.
- **Unify all three qmd service `ExecStart`s on `%h/.local/bin/qmd`.** (user decision 2a, this session)
- Rationale: matches the opendataloader-pdf `%h/.local/bin/...` convention; removes the hardcoded user path in
  qmd-embed; makes all three services invariant to bun reinstalls; makes the stow sh wrapper the single source of
  binary-dispatch truth.
- **Keep PATH order; enable script handles shadow removal for this PR.** (user decision 3a, this session)
- Rationale: reordering PATH in `.profile` is a whole-environment change. Scope this PR to qmd; the enable script
  removing `~/.bun/bin/qmd` is a one-shot that's idempotent on re-run.
- **qmd-serve stays always-on, not socket-activated.** (origin doc)
- Rationale: sequential-mode owns VRAM coexistence in-process; idle-exit would cold-start models on every query.
- **sh wrapper dispatches to fork via `$HOME`, not hardcoded user path.** (origin Revision 2; matches ODL pattern)
- Rationale: wrapper works for any user, portable across dev/prod-deployment hosts.

## Open Questions

### Resolved During Planning

- **Is the `ExecStartPre` Ollama-unload in `qmd-embed.service` still needed?** — Validate during implementation by
  running `qmd embed` with the step disabled under realistic VRAM load; if embedding completes without OOM, remove. (See
  Unit 4.)
- **Does qmd-serve's `/health` endpoint exist and return within reasonable time?** — Resolved: verified live on
  bigdaddy, returns JSON `{"ok":true,"version":"2","backend":"local","models":{...}}` within the curl budget.
- **Does the fork launcher `~/dev/qmd/qmd` exist and work from a fresh shell?** — Resolved: confirmed present (1471
  bytes, `Apr 11 01:42`), exec's bun against the TypeScript source; the wrapper's `exec "$HOME/dev/qmd/qmd" "$@"`
  forwards cleanly.

### Deferred to Implementation

- **Exact port/bind flags for qmd-serve's ExecStart.** The live service runs `qmd serve --port 7832 --bind 127.0.0.1
  --sequential`. The stowed unit should match — verify against the live unit during Unit 3. Port must match `QMD_SERVER`
  (`7832`).
- **Restart policy for qmd-serve (on-failure vs always).** Match opendataloader-pdf's `Restart=on-failure`
  `RestartSec=5`, unless live behavior suggests `always`. Decide at implementation by checking what the hand-made unit
  on bigdaddy uses.
- **Whether to keep `Environment=PATH=...` in `qmd-update.service` after switching to `%h/.local/bin/qmd`.** The
  variable becomes unnecessary when ExecStart uses absolute paths, but leaving it is harmless belt-and-suspenders.
  Prefer removing for consistency with qmd-serve + qmd-embed (which won't need it either).

## Implementation Units

- [ ] **Unit 1: Move `QMD_SERVER` export to `config/shell/qmd.sh`**

**Goal:** Establish `config/shell/qmd.sh` as the single home for qmd-related shell env, per the feature-named
convention in `config/shell/*.sh`. Delete the direct export from `.profile`.

**Requirements:** R2

**Dependencies:** None.

**Files:**

- Create: `config/shell/qmd.sh`
- Modify: `stow/shell/dot-profile` (remove lines 147–150)
- Test: `tests/shell-config.bats` (add assertion that `QMD_SERVER` is exported post-profile sourcing)

**Approach:**

- New file is a plain POSIX `sh`-compatible export (no aliases — `config/shell/*.sh` is sourced by `.profile` under
  POSIX `sh`, per CLAUDE.md). Preserve the existing comment explaining sequential-mode VRAM math + linking to the
  service unit.
- `.profile` change is a 4-line deletion (comment + blank + export); verify `.profile`'s `config/shell/*.sh` glob loop
  (lines 34–40) picks up the new file.

**Patterns to follow:**

- `config/shell/caam.sh`, `config/shell/gogcli.sh`, `config/shell/telemetry.sh` — feature-named file shape.
- Existing comment style in `stow/shell/dot-profile:147-149` — retain the three-line rationale.

**Test scenarios:**

- *Happy path:* Sourcing `.profile` on a fresh shell sets `QMD_SERVER=http://127.0.0.1:7832`.
- *Edge case:* Non-interactive shell (`bash -c 'source ~/.profile && env | grep QMD'`) still exports `QMD_SERVER`.
- *Regression:* `stow/shell/dot-profile` no longer contains `QMD_SERVER` (grep asserts absence).

**Verification:**

- `env | grep QMD_SERVER` prints `QMD_SERVER=http://127.0.0.1:7832` in a fresh zsh and a fresh bash.
- `bats tests/shell-config.bats` passes.

---

- [ ] **Unit 2: Add stow sh wrapper for the `qmd` binary**

**Goal:** Ship a stow-managed `~/.local/bin/qmd` sh wrapper that dispatches to the brettdavies/qmd fork launcher. Makes
`qmd` resolve identically for humans and for systemd services.

**Requirements:** R3, R6

**Dependencies:** None (the wrapper does not need Unit 1).

**Files:**

- Create: `stow/qmd/dot-local/bin/qmd` (executable sh wrapper, `+x` bit)
- Test: `tests/qmd-serve.bats` (see Unit 6 — this unit contributes assertions)

**Approach:**

- Wrapper is a 3-line sh script using `exec "$HOME/dev/qmd/qmd" "$@"`. `$HOME` expands at invocation so the wrapper is
  user-portable without modification.
- Must be marked executable in the repo (`chmod +x` before commit) — stow preserves the file mode.
- This is a file-level symlink into `~/.local/bin/` (stow deploys with `--no-folding`), so the enable script can safely
  remove `~/.bun/bin/qmd` without breaking adjacent bun-managed binaries.

**Patterns to follow:**

- `stow/opendataloader-pdf/dot-local/bin/opendataloader-pdf-hybrid-sa` — same `exec "$HOME/..." "$@"` shape with
  `#!/bin/sh` shebang.
- `stow/obsidian/dot-local/bin/obsidian` — similar `exec "$HOME/..." "$@"` precedent.

**Test scenarios:**

- *Happy path:* `stow/qmd/dot-local/bin/qmd` exists, is executable, begins with `#!/bin/sh`.
- *Portability:* The wrapper contains `$HOME/dev/qmd/qmd` and no hardcoded `/home/<user>/` path (the existing ODL test
  `! grep -q '/home/[a-z]*/' "$LAUNCHER_SH"` pattern).
- *Integration (manual smoke):* After `stow qmd`, `command -v qmd` resolves to `~/.local/bin/qmd` once `~/.bun/bin/qmd`
  is removed (enable-script's job).

**Verification:**

- `bash stow/qmd/dot-local/bin/qmd --version` (after the fork launcher is reachable) prints the fork's qmd version.

---

- [ ] **Unit 3: Stow `qmd-serve.service` systemd user unit**

**Goal:** Track the qmd-serve unit as a stow-managed file so it survives reinstalls. Unit shape mirrors the
  currently-running
hand-made unit on bigdaddy but uses `%h/.local/bin/qmd` for binary dispatch.

**Requirements:** R1

**Dependencies:** Unit 2 (wrapper must exist for the ExecStart path to resolve).

**Files:**

- Create: `stow/qmd/dot-config/systemd/user/qmd-serve.service`
- Test: `tests/qmd-serve.bats`

**Approach:**

- Unit shape: `[Unit]` Description; `[Service]` `Type=simple`, `ExecStart=%h/.local/bin/qmd serve --port 7832 --bind
  127.0.0.1 --sequential`, `Restart=on-failure`, `RestartSec=5`; hardening `NoNewPrivileges=true`, `PrivateTmp=true`;
  `[Install]` `WantedBy=default.target`.
- No `After=network-online.target` needed — binds loopback.
- Port 7832 must match `QMD_SERVER`. Bind 127.0.0.1 is explicit (no external exposure).
- Before committing, compare against `~/.config/systemd/user/qmd-serve.service` on bigdaddy and capture any field the
  hand-made unit has that this plan missed (e.g., `Environment=` lines, ordering relative to Ollama).

**Patterns to follow:**

- `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.service` — `Type=simple`, `%h/.local/bin/...`
  ExecStart, `Restart=on-failure` `RestartSec=5`, hardening triple (`NoNewPrivileges`, `PrivateTmp`),
  `WantedBy=default.target`.

**Test scenarios:**

- *Happy path:* `qmd-serve.service` exists at the expected path in the stow package.
- *Structure:* `ExecStart=%h/.local/bin/qmd serve` is present (leading anchor + trailing space to avoid false matches).
- *Structure:* `--sequential`, `--port 7832`, `--bind 127.0.0.1` all present on the ExecStart line.
- *Hardening:* `NoNewPrivileges=true` and `PrivateTmp=true` present.
- *Restart policy:* `Restart=on-failure` present, `RestartSec=` present with a numeric value.
- *Install:* `WantedBy=default.target` present so the service autostarts on login.
- *No hardcoded paths:* `! grep -q '/home/[a-z]*/' qmd-serve.service`.

**Verification:**

- `systemd-analyze --user verify stow/qmd/dot-config/systemd/user/qmd-serve.service` reports zero warnings on a host
  with the wrapper deployed.

---

- [ ] **Unit 4: Update `qmd-embed.service` + `qmd-update.service` to use `%h/.local/bin/qmd`; review Ollama-unload**

**Goal:** Unify binary dispatch across all three qmd services. Remove the hardcoded `/home/brett/.bun/bin/qmd` path from
qmd-embed. Validate and (likely) remove the redundant Ollama-unload `ExecStartPre` now that qmd-serve owns sequential
VRAM coexistence.

**Requirements:** R6, R7

**Dependencies:** Unit 2 (wrapper must exist).

**Files:**

- Modify: `stow/qmd/dot-config/systemd/user/qmd-embed.service`
- Line 10: `ExecStart=/home/brett/.bun/bin/qmd embed` → `ExecStart=%h/.local/bin/qmd embed`
- Line 9: review the Ollama-unload `ExecStartPre`; remove iff confirmed redundant.
- Line 7: `Environment=PATH=...` becomes unnecessary once ExecStart uses an absolute path. Remove for consistency.
- Modify: `stow/qmd/dot-config/systemd/user/qmd-update.service`
- Line 7: `ExecStart=/bin/sh -c 'qmd cleanup 2>/dev/null; qmd update'` → `ExecStart=/bin/sh -c '%h/.local/bin/qmd
  cleanup 2>/dev/null; %h/.local/bin/qmd update'`
- Line 6: `Environment=PATH=...` — remove for the same reason as qmd-embed.
- Test: `tests/qmd-serve.bats` or a shared `tests/qmd-services.bats` — assert the new `ExecStart` shapes.

**Approach:**

- The Ollama-unload review is a runtime check: with qmd-serve handling VRAM sequentially, Ollama should already be
  unloaded or model-sharing should be in-process. Test by disabling the ExecStartPre (comment it out locally), running
  `systemctl --user start qmd-embed.service`, and watching `nvidia-smi` + journalctl for VRAM pressure or OOM. If clean,
  delete the `ExecStartPre` line. If not clean, keep it with a comment explaining why qmd-serve doesn't subsume it.
- Document the outcome in the PR description so future-me knows whether the removal stuck.

**Patterns to follow:**

- `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.service:8` — `%h/.local/bin/...` ExecStart
  precedent.

**Test scenarios:**

- *Happy path:* qmd-embed.service `ExecStart` starts with `%h/.local/bin/qmd embed`.
- *Happy path:* qmd-update.service `ExecStart` uses `%h/.local/bin/qmd cleanup` and `%h/.local/bin/qmd update`.
- *Regression:* Neither file contains `/home/[a-z]*/` (no hardcoded user paths).
- *Conditional (if Ollama-unload removed):* qmd-embed.service has no `ExecStartPre` referencing `ollama` / `11434`.
- *Conditional (if kept):* the `ExecStartPre` line is preserved with a trailing inline comment explaining why.

**Verification:**

- `systemctl --user daemon-reload && systemctl --user start qmd-embed.service` completes with exit status 0.
- `journalctl --user -u qmd-embed.service --since "5 minutes ago"` shows `qmd embed` completing without OOM.
- Same for qmd-update.

---

- [ ] **Unit 5: Add `scripts/qmd-serve-enable.sh`**

**Goal:** Idempotent one-shot script that activates qmd-serve on a fresh host: removes the bun-shadow, reloads systemd,
enables + starts the service, smoke-tests `/health`, prints recent logs. Safe to re-run.

**Requirements:** R4

**Dependencies:** Units 2, 3 (wrapper + service must be stow-deployed first).

**Files:**

- Create: `scripts/qmd-serve-enable.sh` (executable)
- Test: `tests/qmd-serve.bats` (shape assertions)

**Approach:**

- Direct port of `scripts/opendataloader-pdf-enable.sh` adapted to qmd-serve. Structure:

1. `set -euo pipefail`.
2. Linux gate — `[ "$(uname -s)" != "Linux" ] && { echo "NOTE: qmd-serve is Linux-only..." >&2; exit 0; }`.
3. Port/service constants — `PORT=7832`, `SERVICE_UNIT="qmd-serve.service"`.
4. Shadow removal — if `[ -L "$HOME/.bun/bin/qmd" ] || [ -f "$HOME/.bun/bin/qmd" ]`, print a note and `rm -f`. Safe
   because the stow wrapper at `~/.local/bin/qmd` takes over.
5. Orphan-listener cleanup — `ss -Htnl "sport = :7832"`; `systemctl --user stop qmd-serve.service` then SIGTERM any
   remaining `bun .*qmd.ts` process; wait up to 5 s for the port to clear.
6. `systemctl --user daemon-reload && systemctl --user enable --now qmd-serve.service`.
7. Smoke: `curl --silent --fail --max-time 30 http://127.0.0.1:7832/health -o $tmp`. On failure, print journal tail (20
   lines) with remediation hint.
8. Print the 10 most recent journal lines on success.
9. Trailing NOTE explaining that qmd-serve is always-on (no idle-exit).

**Patterns to follow:**

- `scripts/opendataloader-pdf-enable.sh` — full structure. The only structural diff vs ODL: no socket unit here
  (qmd-serve is not socket-activated), so it's `enable --now qmd-serve.service` (not `.socket`).

**Test scenarios:**

- *Happy path:* Script exists and is executable.
- *Happy path:* Script references `qmd-serve.service`.
- *Happy path:* Script has a `curl ... /health` smoke invocation with `--max-time`.
- *Happy path:* Script has a `uname -s` Linux-only gate with a `Linux-only` NOTE string.
- *Happy path:* Script removes `~/.bun/bin/qmd` shadow when present (grep for the `rm -f.*bun/bin/qmd` or equivalent
  pattern).
- *Integration (manual smoke — see checklist in Unit 6):* On a host with a dangling `~/.bun/bin/qmd`, running the script
  leaves `command -v qmd` resolving to `~/.local/bin/qmd`.
- *Integration (manual smoke):* On a host with an orphan listener on :7832 (not owned by systemd), the script stops it,
  enables the unit, and smoke-passes.

**Verification:**

- `shellcheck scripts/qmd-serve-enable.sh` reports no errors.
- Running the script twice in a row is a no-op the second time (idempotency): second-run output doesn't include
  "Existing listener detected" or "Removing `~/.bun/bin/qmd` shadow" unless the environment actually regressed.

---

- [ ] **Unit 6: Add `tests/qmd-serve.bats`**

**Goal:** Static assertions covering the stow package, service unit, wrapper, and enable-script shape. Manual smoke
checklist in the file header captures the live verification steps CI can't run.

**Requirements:** R5

**Dependencies:** Units 2, 3, 4, 5 (all files the tests assert against).

**Files:**

- Create: `tests/qmd-serve.bats`

**Approach:**

- Direct port of `tests/opendataloader-pdf.bats`. Header comment block with manual-smoke checklist covering:

1. Cold start: `bash scripts/qmd-serve-enable.sh` → `/health` within 10 s.
2. Sequential VRAM cycling: submit a query that requires `embed` then `rerank` then `generate` back-to-back; watch
   `nvidia-smi` show one model resident at a time, peak ~2.6 GB.
3. Persistence across reboot: `sudo reboot`; after login, verify `systemctl --user is-active qmd-serve.service` returns
   `active` and `/health` responds.
4. qmd-embed.service still works: `systemctl --user start qmd-embed.service` completes without OOM; nvidia-smi shows
   qmd-serve retains its baseline model allocation.
5. qmd CLI routes through serve: `qmd query "test"` with `QMD_SERVER` set; compare against unsetting `QMD_SERVER`
   (should fall back to local mode).
6. Shadow removal is correct: `command -v qmd` → `~/.local/bin/qmd`, not `~/.bun/bin/qmd`.
7. Teardown: `systemctl --user disable --now qmd-serve.service` is clean.

- Static assertion sections:
- Package layout (files exist + executable bits).
- Wrapper shape (`$HOME` reference, no hardcoded user paths).
- qmd-serve.service contents (ExecStart shape, hardening, WantedBy).
- qmd-embed.service + qmd-update.service contents (no hardcoded `/home/brett/`, uses `%h/.local/bin/qmd`).
- Enable script shape (Linux gate, /health smoke, shadow-removal line).
- Optional shell-env assertion: `config/shell/qmd.sh` exists and exports `QMD_SERVER=http://127.0.0.1:7832`.

**Patterns to follow:**

- `tests/opendataloader-pdf.bats` — full template, including the checklist comment block.

**Test scenarios:**

- All assertions above. Aim for ~15–20 `@test` blocks; error on the side of specificity (e.g., assert the exact port
  number, not just "port is present").

**Verification:**

- `bats tests/qmd-serve.bats` passes with no skips when run on bigdaddy.
- `bats tests/` as a whole still passes (no regressions in the other 10 bats files).

## System-Wide Impact

- **Interaction graph:** `config/shell/qmd.sh` joins the `.profile` glob chain (sourced alongside `caam.sh`,
  `gogcli.sh`, etc.). Non-interactive zsh, cron, and systemd services that source `.profile` now get `QMD_SERVER` there
  instead of directly from `.profile`.
- **Error propagation:** qmd-serve's `Restart=on-failure` + `RestartSec=5` means transient OOM or network failure
  restarts automatically. If the binary itself is broken (e.g., fork launcher exits 1 immediately), systemd enters
  rate-limited restart; journalctl surfaces this. Enable script's `/health` smoke catches this within 30 s of enable.
- **State lifecycle risks:**
- `~/.bun/bin/qmd` shadow removal is destructive (rm). On hosts where the user wants to keep bun-managed qmd (e.g., the
  upstream binary, not the fork), the shadow would be recreated by the next `bun add -g qmd`. Acceptable: this host
  explicitly prefers the fork.
- `QMD_SERVER` move from `.profile` to `config/shell/qmd.sh`: until both changes land together (single atomic
  commit/PR), a stale clone would have `QMD_SERVER` exported from neither. Mitigate by landing both in the same PR.
- **API surface parity:** qmd CLI behavior unchanged — same binary, same `QMD_SERVER`, same service. No breaking change
  to external consumers.
- **Integration coverage:** Cross-layer scenarios that static bats can't prove (sequential VRAM cycling under
  simultaneous embed+rerank+generate load; reboot persistence; fallback when `QMD_SERVER` is unset) live in the manual
  smoke checklist per Unit 6.
- **Unchanged invariants:**
- `scripts/stow-deploy` SHARED_PACKAGES list and Linux-only gate are already correct for `qmd`; not touched.
- `tests/stow-deploy-packages.bats` already covers `qmd` package enrollment; not touched.
- `qmd-embed.timer` and `qmd-update.timer` schedule is unchanged — only the `.service` units they point at are edited.
- macOS behavior: qmd package is already Linux-only via `scripts/stow-deploy:265`; macOS users see no change.

## Risks & Dependencies

| Risk | Mitigation |
| ---- | ---------- |
| Fork launcher at `~/dev/qmd/qmd` is missing on the target host | Enable script should fail loudly in the `/health` smoke; print remediation NOTE pointing at how to clone the fork. Not in scope to auto-clone — that's the "rejected Option 2". |
| `QMD_SERVER` disappears for one shell-session during the migration | Land `config/shell/qmd.sh` add + `.profile` delete in the same commit so no in-between state. |
| Ollama-unload removal causes VRAM OOM for qmd-embed | Revert the removal if smoke fails; keep the `ExecStartPre` with a comment documenting why qmd-serve doesn't subsume it. Test before removing. |
| bun reinstalls `~/.bun/bin/qmd` between enable-script runs | Enable script is idempotent — re-running handles it. Document in the enable-script NOTE. |
| Live bigdaddy unit has a field this plan misses (e.g., custom `Environment=` or `After=`) | Unit 3 explicitly compares the new file against the live `~/.config/systemd/user/qmd-serve.service` before commit. |
| PATH ordering still has `~/.bun/bin` winning over `~/.local/bin` in all child processes | Acknowledged scope exclusion. Child processes that resolve `qmd` before the shadow removal will find `~/.bun/bin/qmd` — but after enable-script runs, the symlink is gone, so `~/.local/bin/qmd` wins regardless of PATH order. Acceptable. |

## Documentation / Operational Notes

- **CLAUDE.md update:** Optional but preferred — add a one-liner under the Shell Config Chain section noting the
  convention "feature env vars → `config/shell/<tool>.sh`; `.profile` is base plumbing only." Not strictly required for
  this PR, but captures the rule the move demonstrates.
- **`docs/solutions/`:** Consider a `docs/solutions/deployment-issues/` entry after ship documenting "unifying systemd
  user services on `%h/.local/bin/<wrapper>`" as a pattern — builds on the ODL solution doc but captures the always-on
  variant and the shadow-removal technique. Spin off at document-release time, not now.
- **PR #40 follow-up:** Update ODL solution doc cross-reference to point to this plan's ship commit, so future readers
  see both the socket-activated (ODL) and always-on (qmd-serve) applications of the pattern.
- **Idempotency:** `scripts/qmd-serve-enable.sh` is safe to re-run. No warnings needed for that.

## Sources & References

- **Origin document:**
  [`.context/compound-engineering/todos/009-ready-p2-integrate-qmd-serve-sequential.md`](../../.context/compound-engineering/todos/009-ready-p2-integrate-qmd-serve-sequential.md)
- **Pattern precedent:**
  [`docs/solutions/deployment-issues/systemd-socket-activation-uv-tool-python-service-2026-04-21.md`](../solutions/deployment-issues/systemd-socket-activation-uv-tool-python-service-2026-04-21.md)
- **Related code:** `stow/opendataloader-pdf/` (pattern template), `stow/qmd/` (existing sibling services),
  `stow/shell/dot-profile:147-150` (existing `QMD_SERVER` export), `config/shell/*.sh` (feature-named shell files).
- **Related PR:**
  [#40 — feat(opendataloader-pdf): socket-activated hybrid server with idle-exit](https://github.com/brettdavies/dotfiles/pull/40)
- **Spin-off todo:** `.context/compound-engineering/todos/015-pending-p3-dedupe-path-prepends-local-paths-sh.md`
  (PATH-prepend dedupe in `config/shell/local-paths.sh` — not in this PR).
