---
title: "feat: Socket-activate opendataloader-pdf-hybrid with idle-exit"
type: feat
status: completed
date: 2026-04-21
completed: 2026-04-21
origin: .context/compound-engineering/todos/014-complete-p3-spike-opendataloader-pdf-systemd-wrapper.md
pr: brettdavies/dotfiles#40
solution_doc: docs/solutions/deployment-issues/systemd-socket-activation-uv-tool-python-service-2026-04-21.md
---

# feat: Socket-activate opendataloader-pdf-hybrid with idle-exit

## Overview

Replace the current ad-hoc `opendataloader-pdf-hybrid` launch pattern (started by `mc-pdf.sh`, cleaned up by a fragile
bash trap, observed squatting 4.4 GB of VRAM for 12+ hours) with a systemd user unit that is socket-activated on first
connect and self-terminates after an idle period. A thin Python launcher in `~/.local/bin/` wraps upstream's FastAPI
app, honors `LISTEN_FDS` for FD passthrough to uvicorn, and runs an asyncio watchdog that shuts the server down when
idle. The stow package ships the socket, service, and launcher; a companion script handles the one-time migration (stop
any orphan, enable the socket). No changes to mc-pdf callers are required — they already check `/health` first, which
the socket listener satisfies before the backend is spawned.

## Problem Frame

On a 24 GB RTX 3090 Ti shared with ollama (`gemma4:26b` pinned at 18.7 GB via `OLLAMA_KEEP_ALIVE=-1`) and qmd-serve
(~0.8 GB), the unsupervised hybrid server's 4.4 GB resident footprint leaves no headroom for qmd's expansion-model
context allocations (~560 MB), causing CUDA OOM on `qmd query`. The immediate OOM was mitigated by unpinning ollama, but
opendataloader-pdf will continue to squat indefinitely between mc-pdf invocations because:

1. The hybrid server has no native idle-exit — it runs until killed.
2. `mc-pdf.sh`'s EXIT trap only kills servers it started itself; any process orphaned by SIGKILL, stale subshell, or
   adoption-as-external survives.
3. No systemd supervision exists to reclaim the process.

The spike (origin document) validated that the upstream server responds cleanly
to SIGTERM (0.5 s exit, full VRAM reclaimed), that `uvicorn.run(fd=...)` accepts a socket-activated FD via a ~35-LOC
launcher, that cold start is ~10.5 s worst case (well under mc-pdf's 60 s patience budget), and that ollama/vLLM are not
applicable because the 4.4 GB is CV inference (EasyOCR + TableFormer + docling layout), not LLM inference. Socket
activation + launcher-level idle-exit is the recommended implementation path.

## Requirements Trace

- R1. Hybrid server holds 0 MiB VRAM when idle for >1 min with no recent requests (see origin: spike Work Log, measured
  4378 MiB freed on SIGTERM).
- R2. First connect after idle cold-starts to a serving state within mc-pdf's 60 s patience budget (measured worst case:
  ~10.5 s).
- R3. mc-pdf skill callers require no changes — existing `curl /health` probe satisfies itself against the
  socket-activated listener.
- R4. Current `--force-ocr --log-level warning` invocation arguments preserved.
- R5. Stow package deploys via `scripts/stow-deploy --all` on Linux and is cleanly skipped on macOS.
- R6. Migration from existing ad-hoc listener is one-shot, idempotent, and safely re-runnable.
- R7. uv-tool upgrades (`uv tool upgrade opendataloader-pdf`) do not break the launcher or the systemd unit.

## Scope Boundaries

- Not shipping an ollama / vLLM integration for docling's optional picture description enrichment. Spike established
  this is orthogonal to the VRAM problem and is a separate feature.
- Not shipping a `--device cpu` preset or fallback mode. Known lever, not needed.
- Not consolidating with the parallel todos `008` (ollama override) and `009` (qmd-serve integration) into a unified
  `gpu-services` meta-package. Each service has independent lifecycle; revisit only if all three land within the same
  sprint.
- Not upstreaming the `--idle-timeout` flag to opendataloader-pdf. Launcher-level idle-exit keeps this self-contained;
  upstream PR is a future consideration.
- Not modifying `mc-pdf.sh` itself. The skill's existing `/health` check makes socket activation transparent.

### Deferred to Separate Tasks

- Closing todo `014` and opening follow-up todo `015` once this plan ships: tracked in the todo backlog, not this plan.
- Documenting the resulting pattern in `docs/solutions/deployment-issues/` via `/ce-compound` after shipping: that's a
  post-ship capture step, not plan scope.

## Context & Research

### Relevant Code and Patterns

- `stow/obsidian/` — closest precedent. Ships a systemd user unit (`dot-config/systemd/user/obsidian.service`) and a
  launcher in `dot-local/bin/obsidian`. Same directory structure applies here.
- `~/.config/systemd/user/qmd-serve.service` (live on dev host) — reference for `Type=simple`, `Restart=on-failure`,
  `NoNewPrivileges`, `PrivateTmp` hardening.
- `scripts/stow-deploy` line 23 — `SHARED_PACKAGES` array. Add `opendataloader-pdf` between `obsidian` and `caam`
  (alphabetical ordering broken here by deployment ordering, so position by convention: after `obsidian`).
- `scripts/stow-deploy` lines 263–270 — Linux-only package guard. Extend `rclone|qmd|obsidian)` case to
  `rclone|qmd|obsidian|opendataloader-pdf)`.
- `~/.claude/skills/markdown-convert/skills/mc-pdf/mc-pdf.sh` lines 59–109 — the caller's lazy-start pattern. The
  `/health` short-circuit at line 67 is what makes socket activation transparent.
- `~/.claude/skills/markdown-convert/skills/mc-pdf/mc-pdf-setup.sh` — optional hook point: the plan considers whether
  setup should auto-enable the socket.
- `tests/*.bats` — bats test patterns. `stow-deploy-packages.bats` shows how to assert on `SHARED_PACKAGES` contents;
  `symlinks.bats` shows file-presence assertions post-stow.
-

`/home/brett/.local/share/uv/tools/opendataloader-pdf/lib/python3.11/site-packages/opendataloader_pdf/hybrid_server.py`
(read-only upstream) — the launcher imports `create_app`, `_check_dependencies`, `_get_loop_setting`, `DEFAULT_HOST`,
`DEFAULT_PORT` from this module.

### Institutional Learnings

- `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md` — use `$HOME` / `%h`, gate
  platform-specific behavior on `uname -s`.
- `docs/solutions/deployment-issues/stow-symlink-breakage-by-atomic-writers.md` — if a program rewrites a stow-managed
  file, the symlink breaks. The launcher here is our code and never self-modifies; not applicable. The systemd units are
  never rewritten by systemd. Safe to stow.
- `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md` — startup-file matrix. Not directly relevant
  (systemd unit runs independent of shell files), but confirms the package ships nothing that needs to be sourced by
  shells.

### External References

- `systemd.socket(5)` — `Accept=no` (default) passes a single listening socket to the service as FD 3 via `$LISTEN_FDS`
- `$LISTEN_PID`.
- `uvicorn.run(fd=...)` — documented parameter; validated in spike.
- `asgi-lifespan` / FastAPI middleware docs — the watchdog uses standard ASGI middleware to timestamp requests; no
  private uvicorn internals.

## Key Technical Decisions

- **Ship the package to all Linux hosts via `SHARED_PACKAGES`, not a new dev-only gate.** Rationale: the systemd socket
  unit at rest costs ~0 resources. On hosts without `uv tool install opendataloader-pdf[hybrid]` run, first request
  returns a connection-reset (service fails to start, backend import fails). This is pragmatic graceful degradation that
  matches how `stow/obsidian/` behaves on hosts without Obsidian installed. No new conditional-deploy mechanism needed.
  On macOS, the package is skipped via the existing Linux-only case block.
- **Launcher named `opendataloader-pdf-hybrid-sa`**, not `opendataloader-pdf-hybrid`. The latter is owned by `uv tool
  install`. The `-sa` (socket-activation) suffix avoids path collision in `~/.local/bin/` and names intent clearly.
  Launcher shebangs `/home/brett/.local/share/uv/tools/opendataloader-pdf/bin/python` — this path is stable across `uv
  tool upgrade` (verified in spike).
- **Idle-exit at launcher level, not via external timer.** An ASGI middleware records the timestamp of each request
  completion; an asyncio background task polls every 5 s and, once (now − last_activity) exceeds the idle timeout AND no
  request is in flight, it trips uvicorn's `server.should_exit = True`. Uvicorn drains active connections (there are
  none by construction), closes the listening socket it received from systemd, and exits. systemd's socket unit keeps
  its own listen socket bound; on next connect, systemd respawns the service. Default idle timeout: **60 s (1 min)** —
  intentionally aggressive because qmd runs frequently and needs contiguous VRAM for its expansion-model context; ODL's
  4.4 GB must clear out fast to avoid blocking qmd. The ~10 s cold-start penalty on each fresh `mc-pdf` invocation is
  accepted (mc-pdf is rarer than qmd). Flag: `--idle-timeout` (set to `0` to disable).
- **Preserve mc-pdf's `--force-ocr --log-level warning` args in the service `ExecStart`.** The skill expects force-OCR
  behavior on this port. A future enhancement could parameterize via an `EnvironmentFile=` pointing at
  `~/.config/opendataloader-pdf/hybrid.conf`, but YAGNI for this iteration.
- **Companion enable script, not auto-enable on stow.** `scripts/stow-deploy` does not run per-package post-install
  hooks (see `stow/obsidian/` — also requires manual `systemctl --user enable --now obsidian.service`). Ship
  `scripts/opendataloader-pdf-enable.sh` that handles orphan cleanup + `daemon-reload` + `enable --now` + `/health`
  smoke. Document the one-time run in `mc-pdf-setup.sh`'s success message.
- **Bats tests cover static assertions only.** Live socket-activation behavior requires a functioning uv-tool install
  and ~10 s for cold start; heavier than CI should carry. Manual smoke checklist in the plan supplements the bats suite.

## Open Questions

### Resolved During Planning

- **How does the idle watchdog avoid tearing down an in-flight request?** — An in-flight counter is incremented at
  middleware entry and decremented at exit (with `finally`). The watchdog only trips `should_exit` when counter == 0 AND
  idle window elapsed. Uvicorn's own graceful-shutdown already waits for active connections to finish, giving a second
  line of defense.
- **Does idle-exit play nicely with socket activation re-activation?** — Yes. Uvicorn exiting closes its copy of FD 3
  (the accepted listener). systemd retains its own copy of the socket (`Accept=no` model) and re-forks the service on
  the next incoming connection. This is the textbook pattern from `systemd.socket(5)`.
- **Where do the units live in the stow package?** — Match `stow/obsidian/` exactly:
  `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.socket` and `…/opendataloader-pdf.service`, with
  the launcher at `stow/opendataloader-pdf/dot-local/bin/opendataloader-pdf-hybrid-sa`.
- **Does this ship to headless Ubuntu fleet?** — Yes, via `SHARED_PACKAGES`. Graceful degradation on hosts without the
  uv-tool installed (see Key Decisions). No new gating mechanism.
- **Should `mc-pdf.sh` change?** — No. Its existing `/health` probe makes socket activation invisible.

### Deferred to Implementation

- **Exact idle watchdog poll interval and flush behavior.** 5 s poll + 60 s default idle are planning numbers; the
  implementer may tune based on observed cold-start + per-test results.
- **Whether `ExecStartPre=` should include an `rm` of stale temp files.** The upstream server writes to
  `tempfile.NamedTemporaryFile` with `delete=False` then `os.unlink` in `finally`. Crash recovery (SIGKILL) can leak
  `/tmp/*.pdf`. Worth considering an `ExecStartPre=/bin/sh -c 'rm -f /tmp/tmp_pdf_file*.pdf'` but only if observed
  leakage shows it matters. Defer.
- **Whether to set `MemoryMax=` or other `systemd` resource limits.** Worth considering once ship-measured steady-state
  is known. Not planning-time.

## Implementation Units

- [x] **Unit 1: Stow package skeleton**

**Goal:** Create the `stow/opendataloader-pdf/` package with socket unit, service
unit, and a placeholder launcher. The launcher in this unit is a minimal passthrough (no idle-exit, no FD handling) that
mirrors the current ad-hoc behavior — just enough for the deploy path to be testable. Unit 2 adds the real launcher
logic.

**Requirements:** R5.

**Dependencies:** None.

**Files:**

- Create: `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.socket`
- Create: `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.service`
- Create: `stow/opendataloader-pdf/dot-local/bin/opendataloader-pdf-hybrid-sa`

**Approach:**

- `.socket`: `ListenStream=127.0.0.1:5002`, `Accept=no`, `WantedBy=sockets.target`.
- `.service`: `Type=simple`, `Requires=opendataloader-pdf.socket`, `After=opendataloader-pdf.socket`, `ExecStart=`
  invokes the launcher with `--force-ocr --log-level warning`. Hardening: `NoNewPrivileges=true`, `PrivateTmp=true`.
  `Restart=on-failure`, `RestartSec=5`.
- Launcher: executable Python script with shebang `/home/brett/.local/share/uv/tools/opendataloader-pdf/bin/python`. In
  this unit it simply invokes upstream `main()` (no FD handling yet).
- File mode on launcher: 0755 (stow preserves mode).

**Patterns to follow:**

- `stow/obsidian/dot-config/systemd/user/obsidian.service` — unit file shape, `Description`, `After`, hardening,
  `[Install]` section.
- `stow/obsidian/dot-local/bin/obsidian` — executable launcher script in `dot-local/bin/` with Linux-specific shebang.

**Test scenarios:**

- Happy path: `scripts/stow-deploy opendataloader-pdf` on Linux creates three symlinks under `~/.config/systemd/user/`
  and `~/.local/bin/`.
- Edge case: running the same command twice is idempotent (stow's `-R`).

**Verification:**

- After stow, `systemd-analyze --user verify opendataloader-pdf.socket opendataloader-pdf.service` reports no errors.
- `~/.local/bin/opendataloader-pdf-hybrid-sa` is executable and shebang points at a real interpreter.

- [x] **Unit 2: Launcher with FD handling and idle-exit watchdog**

**Goal:** Replace the Unit 1 placeholder with the real launcher: honors
`LISTEN_FDS` to pass FD 3 to `uvicorn.run(fd=...)` (socket-activated path), adds `--idle-timeout` flag, installs ASGI
middleware that timestamps request completions, and runs a background asyncio task that trips `server.should_exit` when
idle. Falls back to `host`/`port` binding when invoked outside systemd.

**Requirements:** R1, R2, R4, R7.

**Dependencies:** Unit 1.

**Files:**

- Modify: `stow/opendataloader-pdf/dot-local/bin/opendataloader-pdf-hybrid-sa`
- Modify: `stow/opendataloader-pdf/dot-config/systemd/user/opendataloader-pdf.service` (add `--idle-timeout 60` to the
  `ExecStart` line)

**Approach:**

- Argparse flags: `--host`, `--port`, `--force-ocr`, `--log-level`, `--idle-timeout SECONDS` (default 60, `0` disables
  watchdog).
- Import `create_app`, `_check_dependencies`, `_get_loop_setting`, `DEFAULT_HOST`, `DEFAULT_PORT` from
  `opendataloader_pdf.hybrid_server`.
- Add a small `IdleWatchdog` class that:
- Tracks `last_activity` (monotonic) and an `in_flight` counter (protected by an `asyncio.Lock` to avoid TOCTOU on
  counter reads).
- Exposes an ASGI-style middleware: on request entry, increment in_flight; on exit (finally), decrement and update
  last_activity.
- Spawns a background task from the ASGI lifespan context manager that polls every 5 s and, when `idle_timeout > 0` AND
  `in_flight == 0` AND `(now − last_activity) > idle_timeout`, sets `uvicorn_server.should_exit = True` and exits the
  loop.
- Pass the `uvicorn.Server` reference into the watchdog. Uvicorn's `server_class=...` hook or a post-startup lookup via
  `asyncio.get_event_loop` is the implementer's call — spike findings indicate a subclass of `uvicorn.Server` that
  exposes itself to the app state is the cleanest.
- The upstream `create_app()` already wraps the FastAPI app in an `asynccontextmanager` lifespan. The launcher must wrap
  or compose that lifespan, not replace it. A thin "outer lifespan" that delegates to the inner one and runs the
  watchdog alongside is the pattern.
- LISTEN_FDS dispatch: when `LISTEN_FDS > 0` AND `LISTEN_PID == os.getpid()`, call `uvicorn.run(app, fd=3, ...)`.
  Otherwise `uvicorn.run(app, host=args.host, port=args.port, ...)`. Validated in spike.
- Match `_get_loop_setting()` choice (upstream uses `auto` on non-Windows).

**Technical design:** *(directional — the implementer should treat this as
context, not a spec to reproduce verbatim)*

```text
Launcher startup
  ├─ parse args
  ├─ build FastAPI app via upstream create_app(force_ocr=...)
  ├─ compose outer lifespan that:
  │    ├─ delegates to upstream's inner lifespan (converter init)
  │    ├─ spawns idle_watchdog_task (idle_timeout, in_flight, last_activity)
  │    └─ on shutdown, cancels the watchdog task
  ├─ install request-timing middleware (in_flight++ / last_activity = now)
  └─ dispatch to uvicorn:
       if LISTEN_FDS set + PID matches → uvicorn.run(app, fd=3, …)
       else                             → uvicorn.run(app, host, port, …)
```

**Patterns to follow:**

- Upstream `opendataloader_pdf.hybrid_server.create_app` lifespan pattern (asynccontextmanager + `yield`).
- FastAPI middleware docs: `@app.middleware("http")` decorator or `BaseHTTPMiddleware` subclass — the implementer picks;
  both work.

**Test scenarios:**

- Happy path (standalone mode): launcher run directly with no `LISTEN_FDS` binds to `127.0.0.1:5002`, `curl /health`
  returns 200.
- Happy path (socket-activated mode): `systemd-socket-activate -l 127.0.0.1:5003 <launcher>` triggers cold start; first
  `curl /health` on :5003 returns 200 within ~5 s.
- Happy path (idle-exit): launcher started with `--idle-timeout 10`, no requests for 15 s — process exits cleanly (exit
  code 0 or SIGTERM-equivalent), listener unbinds.
- Edge case (idle-exit disabled): launcher with `--idle-timeout 0` stays running indefinitely; 60 s idle period does not
  trigger exit.
- Edge case (in-flight protection): request that takes > idle-timeout to complete (simulate by passing a large PDF or
  artificially slow docling call) does not cause mid-request shutdown.
- Error path (upstream import failure): launcher invoked with a broken venv (e.g., rename site-packages) exits non-zero
  within 2 s and writes a clear error to stderr.
- Integration: running under `systemd-socket-activate`, send one request, wait idle_timeout + 5 s, send another — second
  request succeeds (confirms re-activation works).

**Verification:**

- `ss -tnl` shows port 5002 listener owned by systemd's socket unit between idle-exits.
- `journalctl --user -u opendataloader-pdf.service` shows backend start / idle-exit cycles as expected.
- VRAM query (`nvidia-smi --query-compute-apps=pid,used_memory --format=csv`) shows zero MiB for the launcher process
  during idle periods.

- [x] **Unit 3: stow-deploy integration**

**Goal:** Wire the new package into `scripts/stow-deploy` so `--all` includes
it on Linux and skips it on macOS. Verify existing bats tests still pass.

**Requirements:** R5.

**Dependencies:** Unit 1 (package must exist before deploy integrates).

**Files:**

- Modify: `scripts/stow-deploy` (line 23: `SHARED_PACKAGES`; line 265: Linux-only case block).
- Modify: `tests/stow-deploy-packages.bats` (assert on new package name in shared set and Linux-only set).

**Approach:**

- Add `opendataloader-pdf` to `SHARED_PACKAGES` after `obsidian` (ordering: keep the existing group shape; obsidian and
  opendataloader-pdf are the two headless-server GUI-adjacent services, read well together).
- Extend the Linux-only platform guard: `rclone|qmd|obsidian)` → `rclone|qmd|obsidian|opendataloader-pdf)`.

**Patterns to follow:**

- Existing Linux-only trio (`rclone|qmd|obsidian`) — exact same pattern.
- `docs/plans/2026-04-01-001-feat-gogcli-stow-package-plan.md` — most recent stow-package-addition plan.

**Test scenarios:**

- Happy path: `bash scripts/stow-deploy --all` on Linux deploys the new package alongside the others.
- Happy path: `bash scripts/stow-deploy --all` on macOS skips the new package with a `WARNING: opendataloader-pdf is
  Linux-only` message, exits 0.
- Edge case: bats test `stow-deploy-packages.bats` asserts `opendataloader-pdf` is in `SHARED_PACKAGES` array and in the
  Linux-only case block.
- Edge case: `bash scripts/stow-deploy opendataloader-pdf` (explicit single package) on Linux deploys it.

**Verification:**

- `bats tests/stow-deploy-*.bats` green.
- After `--all` on Linux: all three symlinks present under `$HOME` per Unit 1's verification.

- [x] **Unit 4: Migration + enable companion script**

**Goal:** One-shot script that stops any orphan `opendataloader-pdf-hybrid`
process on :5002, reloads systemd user units, enables the socket unit (`--now`), and confirms `/health` responds.
Idempotent and safe to re-run.

**Requirements:** R6.

**Dependencies:** Unit 1 (socket unit must be stowed), Unit 3 (stow-deploy already deployed the package).

**Files:**

- Create: `scripts/opendataloader-pdf-enable.sh`
- Modify: `~/.claude/skills/markdown-convert/skills/mc-pdf/mc-pdf-setup.sh` (append a one-line hint pointing at the new
  enable script — NO automatic invocation, since mc-pdf-setup runs per-user and the enable script touches systemd; let
  users run it explicitly once).

**Approach:**

- Script logic, in order:

1. Guard: exit early if not Linux (`uname -s`).
2. Detect + stop any existing listener on :5002: if `ss -tnlp 'sport = :5002'` shows a process, try `systemctl --user
   stop opendataloader-pdf.service 2>/dev/null`, then `pkill -TERM -f opendataloader-pdf-hybrid` as a fallback. Wait up
   to 5 s for the port to clear.
3. `systemctl --user daemon-reload`.
4. `systemctl --user enable --now opendataloader-pdf.socket`.
5. Smoke: `curl --max-time 30 http://127.0.0.1:5002/health` must return `{"status":"ok"}`. (This triggers the first
   socket-activated start; cold path is ~10.5 s, 30 s margin covers it.)
6. Print the log tail (`journalctl --user -u opendataloader-pdf.service --no-pager -n 20`) for confirmation.

- Error behavior: non-zero exit on any failure, with a clear message about what to check next.
- Follow `~/.claude/CLAUDE.md` shell script conventions: `ERROR:`, `WARNING:`, `NOTE:` prefixes to stderr.

**Patterns to follow:**

- No direct precedent in this repo for a per-package enable script (obsidian users enable its service by hand). This is
  a small new pattern — keep the script compact and self-documenting.
- `mc-pdf-setup.sh` for shell script shape (`set -euo pipefail`, section echoes, explicit error prefixes).

**Test scenarios:**

- Happy path (fresh install, no orphan): script runs cleanly, socket unit becomes active, `/health` returns 200.
- Happy path (re-run): second invocation is a no-op for the "enable" step (`systemctl enable --now` is idempotent),
  smoke still passes.
- Edge case (orphan exists): prior `opendataloader-pdf-hybrid` PID holding :5002 is stopped (SIGTERM, not SIGKILL)
  before enabling the socket.
- Error path (uv-tool not installed): `/health` smoke fails within 30 s timeout; script exits non-zero with a message
  pointing at `mc-pdf-setup.sh`.
- Error path (non-Linux): script exits with code 0 and a skip message on macOS (matching other Linux-only tool
  behavior).

**Verification:**

- After script completes: `systemctl --user is-active opendataloader-pdf.socket` returns `active`. `curl /health`
  returns 200. VRAM query shows the launcher process holding its expected footprint (or zero if the watchdog has already
  fired post-smoke).

- [x] **Unit 5: Bats test coverage + manual smoke checklist**

**Goal:** Bats coverage for the static parts of the package (layout,
stow-deploy wiring, enable-script structural sanity). A manual smoke checklist documents the live-behavior tests that
require a working uv-tool install.

**Requirements:** R5, R6 (in addition to per-unit scenarios).

**Dependencies:** Units 1, 3, 4.

**Files:**

- Create: `tests/opendataloader-pdf.bats`
- Modify: `docs/plans/2026-04-21-001-feat-opendataloader-pdf-socket-activation-plan.md` (this file — append a "Manual
  smoke checklist" subsection once the suite stabilizes; the checklist also appears in the bats file as a comment for
  implementers who grep).

**Approach:**

- Bats cases (static):

1. Package layout exists: socket unit, service unit, launcher script all present at the expected stow paths.
2. Socket unit references `:5002` and `Accept=no` (default or explicit).
3. Service unit `ExecStart` references `%h/.local/bin/opendataloader-pdf-hybrid-sa` and includes `--force-ocr
   --idle-timeout`.
4. Service unit sets `NoNewPrivileges=true` and `PrivateTmp=true`.
5. Launcher is executable (0755) and has a shebang referencing a real interpreter path.
6. `scripts/opendataloader-pdf-enable.sh` is executable and references `opendataloader-pdf.socket` and `curl
   .../health`.
7. `SHARED_PACKAGES` in `scripts/stow-deploy` contains `opendataloader-pdf`.
8. The Linux-only case block in `scripts/stow-deploy` contains `opendataloader-pdf`.

- Bats cases (best-effort, skipped if uv-tool missing):

1. If `/home/brett/.local/share/uv/tools/opendataloader-pdf/bin/python` exists, run the launcher with `--help` and
   expect it to list the new `--idle-timeout` flag.

- Manual smoke checklist (as a comment header in the bats file and as a plan appendix):
- [x] Cold start: fresh boot, `systemctl --user start opendataloader-pdf.socket`, `curl /health` < 15 s.
- [x] Conversion: `curl -X POST -F "files=@test.pdf" /v1/convert/file` returns 200 with JSON body.
- [x] Idle-exit: no requests for idle-timeout + 30 s; `ss -tnlp` shows systemd (not python) as the listener owner.
- [x] Re-activation: after idle-exit, next `curl /health` triggers cold start and succeeds.
- [x] VRAM reclaim: `nvidia-smi` shows 0 MiB for the launcher PID between idle-exits.
- [x] Concurrent requests: two parallel `curl` POSTs both complete (serialized by the upstream `threading.Lock`, no
  crashes).
- [ ] Teardown: `systemctl --user disable --now opendataloader-pdf.socket` cleanly stops everything and does not leave
  orphans. *(not live-tested — systemd disable-unit semantics trusted; run if/when removing the feature.)*
- [x] mc-pdf integration: run a known OCR-required PDF through the `mc-pdf` skill; output matches pre-migration
  behavior.

**Patterns to follow:**

- `tests/stow-deploy-packages.bats` — structural assertions on `scripts/stow-deploy` contents.
- `tests/symlinks.bats` — file / link presence assertions.

**Test scenarios:**

- Meta: the bats file itself runs green.
- Meta: the file-missing-check cases fail informatively when a required file is absent (run in a mutated-fixture
  worktree to confirm).

**Verification:**

- `bats tests/opendataloader-pdf.bats` green on the dev host.
- Manual smoke checklist all-green during final verification (outside CI).

## System-Wide Impact

- **Interaction graph:** `scripts/stow-deploy` gains a new shared package; `mc-pdf.sh` caller is unchanged (health-probe
  short-circuit does the work); `scripts/opendataloader-pdf-enable.sh` is the new operational entry point.
- **Error propagation:** a failed backend import (no uv-tool installed) surfaces as an `ActiveState=failed` on the
  service unit and a connection-reset to the client. mc-pdf's `/health` probe returns non-200 in that case, and the
  skill falls back to starting its own child (preserving today's behavior on unmigrated hosts).
- **State lifecycle risks:** mid-request shutdown guarded by the in-flight counter. Temp-file leakage on SIGKILL is a
  known minor leak, accepted for this iteration (see Deferred to Implementation).
- **API surface parity:** `127.0.0.1:5002` retains the same HTTP contract (FastAPI app unchanged; launcher is a thin
  wrapper). No change to `/health` or `/v1/convert/file` response shape.
- **Integration coverage:** unit bats tests cover static structure only. The cross-cutting behavior — cold start + VRAM
  reclaim + re-activation — is covered by the manual smoke checklist, run on the dev host before closing the work.
- **Unchanged invariants:** mc-pdf skill, markdown-convert skill, `opendataloader-pdf` and `opendataloader-pdf-hybrid`
  uv-tool launchers, ollama and qmd-serve services, and `OLLAMA_KEEP_ALIVE` configuration are all outside the blast
  radius.

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Idle watchdog tears down mid-request | In-flight counter + uvicorn graceful-shutdown provide two layers of protection. Explicit test scenario in Unit 2. |
| Launcher shebang breaks after `uv tool upgrade` | Spike verified uv preserves the tool directory path across upgrades. Mitigation: Unit 5 bats case runs launcher `--help` post-upgrade as a smoke. |
| Service fails to start on a host without uv-tool installed | Expected and documented behavior. `/health` returns non-200; mc-pdf skill's fallback path (start its own child) keeps behavior working on unmigrated hosts. Enable script error-exits with a pointer to `mc-pdf-setup.sh`. |
| Orphan on :5002 blocks socket activation | Enable script (Unit 4) stops orphans before enabling the socket. |
| Idle-timeout default too aggressive (cold start on every fresh mc-pdf session) | Deliberate — 60 s was chosen so qmd (frequent) is never starved by ODL's residual 4.4 GB. The ~10 s cold-start cost on a fresh mc-pdf session is accepted. Configurable via `--idle-timeout` flag if tuning proves necessary. |
| Future upstream change to `opendataloader_pdf.hybrid_server` internals breaks the launcher | Launcher imports a small surface (`create_app`, `_check_dependencies`, `_get_loop_setting`, `DEFAULT_HOST`, `DEFAULT_PORT`). Bats smoke in Unit 5 catches breakage. Worst case: pin uv-tool version in `mc-pdf-setup.sh`. |

## Documentation / Operational Notes

- Update `CLAUDE.md`'s stow package list (memory + file) to include `opendataloader-pdf` in the shared/Linux-only set.
- The manual smoke checklist lives in Unit 5's bats file and in this plan; it is NOT a separate runbook. Post-ship, if
  the pattern proves durable, capture the full implementation story in `docs/solutions/deployment-issues/` via
  `/ce-compound`.
- Post-ship, todo `014` can be marked `complete` and a follow-up `015` opened only if a specific enhancement (CPU-mode
  preset, ollama VLM integration, upstream PR) gets scheduled. The spike recommendation is fully executed by this plan.

## Sources & References

- **Origin document:** `.context/compound-engineering/todos/014-complete-p3-spike-opendataloader-pdf-systemd-wrapper.md`
- Related code: `stow/obsidian/`, `scripts/stow-deploy`, `~/.claude/skills/markdown-convert/skills/mc-pdf/mc-pdf.sh`
- Related todos: `008-pending-p3-stow-ollama-systemd-override.md`, `009-pending-p2-integrate-qmd-serve-sequential.md`
- External docs: `systemd.socket(5)`, [uvicorn CLI reference](https://www.uvicorn.org/settings/)
- Prior-art plan: `docs/plans/2026-04-01-001-feat-gogcli-stow-package-plan.md`

## Post-ship notes (2026-04-21)

All five implementation units landed in a single squashed merge:

- **PR:** [brettdavies/dotfiles#40](https://github.com/brettdavies/dotfiles/pull/40) — merged to `dev` at `6982037`.
- **Follow-on docs PR:** [brettdavies/dotfiles#41](https://github.com/brettdavies/dotfiles/pull/41) — surfaces
  `docs/solutions/` in the project `CLAUDE.md` Reference section, merged at `35e2627`.
- **Compounded solution:**
  `docs/solutions/deployment-issues/systemd-socket-activation-uv-tool-python-service-2026-04-21.md` — reusable pattern
  write-up for the next uv-tool Python daemon that needs supervision.
- **New feedback memory:** `feedback_gpu_service_idle_tuning.md` — captures the aggressive-TTL preference that drove
  `--idle-timeout 60` so todos `008` (ollama `KEEP_ALIVE`) and future GPU-shared services inherit the same bar.

Deviations from the plan (all minor, captured for traceability):

- **Launcher split into two files.** Plan described a single Python launcher with a hardcoded shebang. Implementation
  uses an `sh` wrapper (`opendataloader-pdf-hybrid-sa`) + `.py` module (`…-sa.py`). The `sh` wrapper expands `$HOME` at
  runtime, avoiding a per-user-hardcoded shebang that would break fleet portability. Pattern documented in the solution
  doc.
- **`mc-pdf-setup.sh` hint dropped.** The plan proposed appending a pointer to `scripts/opendataloader-pdf-enable.sh`
  inside `mc-pdf-setup.sh`. That file lives outside this repo (it's in the `markdown-convert` skill, not stow-managed),
  so the modification was skipped. The enable script's own error message already points users at `mc-pdf-setup.sh` on
  smoke failure, which covers the fresh-host case.
- **Smoke-checklist `Teardown` left unchecked.** Intentional — disabling the socket on the dev host would interrupt live
  use. Systemd's `disable --now` semantics are well-known; the item is documented for anyone removing the feature, not
  as a required pre-ship test.

Measurements on bigdaddy post-deploy (repeated from the Work Log for locality):

- SIGTERM → exit: 0.51 s (4378 MiB VRAM freed)
- Boot → `/health 200`: 3.35 s cold start
- First `/v1/convert/file`: 7.11 s (cold, EasyOCR + TableFormer lazy-load)
- Warm `/v1/convert/file`: 1.3–2.0 s
- Idle-exit: triggers at 60 s + up to 5 s poll jitter; VRAM fully reclaimed, systemd retains the listener
- Re-activation: next `/health` cold-starts a fresh PID in ~2.9 s
- `mc-pdf` e2e via the SA listener: skill saw the listener as "already running", reused it, produced valid markdown
  output with frontmatter — zero caller changes required.

Remaining three-way VRAM contention (ollama `gemma4:26b` + warm ODL + qmd concurrent) is **not** solved by this plan.
That needs todo `008` (flip `OLLAMA_KEEP_ALIVE` to a finite value). This plan addresses the idle-squat failure mode
only.
