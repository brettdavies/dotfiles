---
title: "feat: Claude Code session pipeline (cc2md → gitleaks → gbrain + qmd)"
created: 2026-06-15
type: feat
target_repos: ['~/dotfiles', '~/.gbrain', '~/.config/qmd', '~/.claude']
status: ready
---

# feat: Claude Code session pipeline (cc2md → gitleaks → gbrain + qmd)

Personal-infra pipeline that ingests Claude Code session `.jsonl` files into a redacted markdown corpus, feeds gbrain's
synthesize phase, and adds a new qmd collection for raw-transcript search. Backfill + forward-capture in one design.

---

## Summary

Build a local pipeline that:

1. Converts the 1143 existing `~/.claude/projects/**/*.jsonl` files into redacted markdown via `cc2md` + a `gitleaks`
   shim
2. Drops them into a date-partitioned corpus dir (`~/.gbrain/transcripts/claude-code/YYYY-MM-DD/<session-id>.md`)
3. Keeps the corpus growing via a hybrid SessionEnd hook (real-time) + systemd timer (safety net)
4. Wires the corpus dir as `gbrain dream`'s `session_corpus_dir` so the nightly cycle distills transcripts into brain
   pages at `/home/brett/dev/meum-control/wiki/...`
5. Adds a new qmd `claude-code-sessions` collection over the raw corpus; the existing `meum` collection already covers
   synthesized brain pages
6. Provides a one-shot bypass-cooldown synthesize sweep with a cost cap for the historical backfill

Skips ghost entirely — full transcripts give synthesize more signal than ghost's lossy digest, and the redacted markdown
is already qmd-friendly.

---

## Problem Frame

`~/.claude/projects/` holds 1143 session jsonl, 1139 within Claude Code's default eviction window. Claude Code sweeps
local-disk transcripts under `CLAUDE_CONFIG_DIR` per the CLI's `cleanupPeriodDays` setting (sourced from Anthropic's own
SDK examples in `anthropics/claude-agent-sdk-{python,typescript}`); default is 30 days. Empirically confirmed: oldest
jsonl on disk is dated 2026-05-15, exactly 31 days before this plan was written — the sweep is active at the boundary.
gbrain's synthesize phase walks `.txt`/`.md` only, so jsonl never get distilled into brain pages, and the historical
record erodes by ~38 sessions/day as the window slides. qmd indexes none of it.

The eviction policy is configurable — setting `cleanupPeriodDays` to a larger value (e.g., `365`) in
`~/.claude/settings.json` would slow the bleed. That's a useful stopgap to consider in parallel with this pipeline, but
it doesn't replace the need for distillation + redaction + qmd indexing. This plan still ships regardless of whether the
setting gets raised.

gbrain config currently has `dream.synthesize.session_corpus_dir` unset, deliberately — the synthesize phase walks
`.txt`/`.md` files, and pointing it at `~/.claude/projects/` would pull in wrong-format `.txt` git-metadata files that
live alongside the jsonl. Synthesize skips with `not_configured` until a real corpus dir is pointed at it (U7 is the
wire-up step).

Brett's existing `meum` qmd collection (pattern `meum*/**/*.md`, 302 files) already indexes
`/home/brett/dev/meum-control` — which is also where synthesize writes brain pages via `sync.repo_path`. So the
synthesized-output search surface already exists; only the raw-transcript search surface and the conversion pipeline are
missing.

---

## Requirements

- **R1** — All 1143 existing jsonl converted to redacted markdown before 30-day eviction risks any of them
- **R2** — Forward capture catches new sessions automatically via SessionEnd hook (low latency) with a systemd timer
  safety net (catches abrupt terminations)
- **R3** — Redaction pass runs gitleaks against every transcript before it lands in the corpus dir, with audit-trail
  evidence of what was redacted
- **R4** — One-shot synthesize backfill against the historical corpus, user-monitored via the existing dream-budget
  audit ledger
- **R5** — New qmd collection `claude-code-sessions` over the raw corpus, marked excluded from default queries via `qmd
  collection exclude claude-code-sessions` so default `qmd query` results aren't dominated by raw-transcript noise.
  Targeted searches reach it via `qmd query -c claude-code-sessions "<phrase>"`
- **R6** — Pipeline is idempotent — re-running converts only new jsonl files; the verdict cache and content-hash slugs
  prevent synthesize re-spend
- **R7** — All audit/observability follows the existing ISO-week JSONL pattern in `~/.gbrain/audit/`

---

## Key Technical Decisions

### KTD1 — Hybrid forward-capture (hook + timer)

SessionEnd hook fires on normal session close for low-latency archiving. A 30-minute systemd timer sweeps anything the
hook missed (abrupt terminations, crashes, force-quits). Hook is the fast path; timer is the correctness guarantee.
Confirmed pattern in `~/dev/solutions-docs/runtime-errors/tmux-server-wedge-orphan-clients-2026-06-11.md`.

### KTD2 — gitleaks as a redactor, not just a detector

`gitleaks --redact` flag affects logs/stdout only — it does NOT rewrite files. The pipeline runs `gitleaks dir <corpus>
--report-format json --exit-code 0` then a custom Python shim parses the findings (each carries `File`, `StartLine`,
`StartColumn`, `EndLine`, `EndColumn`, `Secret`, `RuleID`) and rewrites each affected file with `Secret →
[REDACTED:<RuleID>]` placeholders, reverse-sorted by offset to avoid drift. Fail-open on gitleaks subprocess crash
(write the file with a warning header; surface in audit).

### KTD3 — Date-partitioned corpus layout

`~/.gbrain/transcripts/claude-code/YYYY-MM-DD/<session-id>.md` (date taken from jsonl `modified_at` via `cc2md list
--json`). Date partitioning gives free `--from`/`--to` scoping for ad-hoc synthesize sweeps and stays scan-friendly past
10K files.

### KTD4 — Backfill sweep is informational, no enforced cost cap

`gbrain dream` exposes no `--bypass-cooldown` or `--max-usd` flag, AND its JSON envelope carries no `cost_usd` field
(verified against `src/core/cycle/synthesize.ts:546-564` + `src/core/cycle.ts:317-388`). Rather than build a synthetic
cap from a non-existent field, U6 ships as a **manual, user-monitored sweep**: loop `gbrain dream --phase synthesize
--input <file> --json` per transcript; the existing dream-budget audit (`~/.gbrain/audit/dream-budget-*.jsonl`,
`cumulative_cost_usd` field) is the real-time cost ledger the user watches in another pane. User stops the loop (Ctrl-C
or signal) when satisfied. The `--input` mode skips `checkCooldown` per `synthesize.ts` (the cooldown logic only fires
on corpus-dir-scan path). Verdict cache (`dream_verdicts` table) only helps on second + subsequent runs since first-pass
file paths are new.

### KTD5 — qmd collection ordering: BEFORE NAS entries

Per `~/dev/solutions-docs/deployment-issues/qmd-collection-ordering-nas-resilience-20260403.md`,
`~/.config/qmd/index.yml` is processed strictly top-to-bottom; one ENOENT crashes the whole indexer. Insert
`claude-code-sessions` BEFORE any `nas-*` entries to keep indexing resilient.

### KTD6 — Reuse `meum` for synthesized side; new collection for raw only

Synthesize writes to `/home/brett/dev/meum-control/wiki/personal/reflections/...` and `/wiki/originals/ideas/...` via
the configured `sync.repo_path`. The existing `meum` qmd collection (`pattern: meum*/**/*.md`) already covers this path.
No new collection needed for the synthesized side. Plan creates only `claude-code-sessions` for raw transcripts.

---

## High-Level Technical Design

```mermaid
flowchart LR
    A[Claude Code session ends] -->|SessionEnd hook| Hook[claude-code-archive.sh<br/>hook]
    Timer[systemd timer<br/>every 30 min] -->|oneshot| Wrapper[claude-code-archive.sh<br/>wrapper]
    Hook --> Wrapper
    Wrapper --> CC2MD[cc2md per jsonl<br/>--raw --markdown gfm]
    CC2MD --> Redact[gitleaks-redact.py<br/>JSON findings → placeholders]
    Redact --> Corpus[~/.gbrain/transcripts/<br/>claude-code/YYYY-MM-DD/sid.md]
    Corpus -->|qmd update| QmdRaw[qmd: claude-code-sessions<br/>explicit-only]
    Corpus -->|nightly gbrain-dream.timer| Dream[gbrain dream<br/>--phase synthesize]
    Dream --> Brain[meum-control/wiki/<br/>personal/reflections, originals]
    Brain -->|qmd update| QmdSynth[qmd: meum<br/>auto-included in default search]
    OneShot[claude-code-synthesize-sweep.sh<br/>user-invoked, cost-capped] -.->|--input loop| Dream
    Wrapper -->|append| Audit[~/.gbrain/audit/<br/>claude-code-archive-YYYY-WNN.jsonl]
```

Two ingest paths converge at the wrapper. Wrapper is the single source of truth for cc2md + redact + corpus-write +
audit. The hook calls the wrapper with `--single <jsonl-path>` for low-latency capture; the timer calls it with no args
for full-corpus sweep. Synthesize is decoupled — the existing nightly `gbrain-dream.timer` picks up the new corpus once
`session_corpus_dir` is wired (U7), and the one-shot sweep script (U6) is the user-invoked backfill.

---

## Output Structure

```text
~/dotfiles/
├── docs/plans/
│   └── 2026-06-15-feat-claude-code-session-pipeline-plan.md     (this file)
├── scripts/sync/
│   ├── claude-code-archive.sh                                    NEW
│   ├── claude-code-synthesize-sweep.sh                           NEW
│   └── lib/
│       └── gitleaks-redact.py                                    NEW
└── stow/
    ├── gbrain/dot-config/systemd/user/
    │   ├── claude-code-archive.service                           NEW
    │   └── claude-code-archive.timer                             NEW
    └── claude/dot-claude/
        ├── claude-code-archive.sh                                NEW  (hook)
        └── settings.json                                         MODIFY (add SessionEnd block)

~/.gbrain/
├── transcripts/claude-code/YYYY-MM-DD/<session-id>.md            NEW (corpus)
└── audit/claude-code-archive-YYYY-WNN.jsonl                      NEW (per-event audit)

~/.config/qmd/
└── index.yml                                                     MODIFY (add claude-code-sessions BEFORE nas-*)
```

The wrapper script is the load-bearing piece; everything else either calls it or wires it up. Per-unit `**Files:**`
sections are authoritative.

---

## Implementation Units

### U1. Wrapper script + cc2md backfill

**Goal:** Convert all 1143 existing jsonl to markdown via cc2md, writing to date-partitioned corpus dir. Idempotent
(skip if output already exists).

**Requirements:** R1, R6

**Dependencies:** none

**Files:**

- `scripts/sync/claude-code-archive.sh` (CREATE)
- Test: manual smoke against a small fixture dir; full backfill verifies behavior at scale

**Approach:**

- Match the `set +e / source ~/.profile / set -e` env-loading sandwich from `scripts/sync/gbrain-sync.sh` exactly —
  load-bearing per its comment block
- Two modes: no-arg (full sweep via `cc2md list --json`) and `--single <jsonl-path>` (hook path)
- For each candidate jsonl:
- Compute target path: `~/.gbrain/transcripts/claude-code/<YYYY-MM-DD-from-modified_at>/<session-id>.md`
- Skip if target already exists (idempotent)
- Run `cc2md "$jsonl" --raw --markdown gfm --thinking -o "<tmp>.md"` (include thinking blocks for synthesize signal)
- Hand `<tmp>.md` to U2's redaction shim
- On redaction success, mv to target; append `archived` event to audit JSONL
- On any failure, append `skipped` or `failed` event with reason; continue batch (don't abort)
- Audit JSONL: `~/.gbrain/audit/claude-code-archive-$(date -u +%G-W%V).jsonl`, schema `{schema_version: 1, ts:
  <RFC3339>, event: <discovered|converted|redacted|archived|skipped|failed>, session_id, jsonl_path, target_path?,
  rule_id?, error?}`

**Patterns to follow:**

- `scripts/sync/gbrain-sync.sh` — wrapper shape, env loading
- `~/.gbrain/audit/dream-budget-*.jsonl` — audit JSONL schema convention

**Test scenarios:**

- Happy: 1143 jsonl → 1143 md files in correct date dirs, all events logged
- Idempotent re-run: 0 new files; audit shows 0 `archived` events on second pass
- Single-file mode: `archive.sh --single <path>` converts only that one
- Bad jsonl (malformed JSON line): cc2md exits non-zero; wrapper logs `failed`, continues
- Empty `cc2md list --json`: wrapper exits 0 with `discovered: 0` audit event
- Disk full during write: wrapper logs `failed` for the in-flight file, exits non-zero so systemd surfaces it

---

### U2. Gitleaks redaction shim

**Goal:** Replace any gitleaks-detected secrets in cc2md output with `[REDACTED:<RuleID>]` placeholders before the file
lands in the corpus dir.

**Requirements:** R3

**Dependencies:** U1

**Files:**

- `scripts/sync/lib/gitleaks-redact.py` (CREATE)
- `scripts/sync/lib/gitleaks.toml` (CREATE — custom rules extending gitleaks' defaults; see Custom rules below)
- Test: `scripts/sync/lib/test_gitleaks_redact.py` (CREATE; pytest or stdlib unittest)

**Approach:**

- Input: path to a single markdown file
- Run `gitleaks stdin --config "$DOTFILES/scripts/sync/lib/gitleaks.toml" --report-format json --report-path -
  --exit-code 0` piping file content
- Parse JSON: array of findings with `File`, `StartLine`, `StartColumn`, `EndLine`, `EndColumn`, `Secret`, `RuleID`
- Reverse-sort findings by `(StartLine, StartColumn)` to splice from end-of-file backward (avoids offset drift)
- For each finding, replace `Secret` substring (or column range when `Secret` is partial) with `[REDACTED:<RuleID>]`
- Stream result to stdout (caller redirects to target path)
- On gitleaks subprocess failure: prepend a header line `<!-- [REDACTION-FAILED: gitleaks exited <N>] -->` and pass
  content through unchanged; emit audit event `redaction_failed`
- Audit each successful redaction with `{event: redacted, rule_id, count, line, column}` so review later is mechanical

**Custom rules (in `gitleaks.toml`):**

Extend gitleaks' default ruleset (`[extend] useDefault = true`) with rules for secret types in Brett's environment that
default rules don't cover:

- `op-uri` — `op://[a-zA-Z0-9_-]+/[a-zA-Z0-9_/-]+(?:/[a-zA-Z0-9_-]+)?` (1Password references; even though they're not
  literal secrets, they leak vault structure and item names)
- `litellm-key` — pattern for `sk-litellm-*` and any `LITELLM_*_KEY=` env-var lines
- `codex-proxy-token` — pattern for `Bearer` prefixed tokens in `Authorization:` headers AND the proxy's specific token
  shape if known
- `gbrain-postgres-dsn` — `postgresql://[^@]+@[^/]+(?:/[^?\s]+)?(?:\?[^\s]*)?` matching DSN-shaped strings
- `tailscale-hostname` — `[a-z0-9-]+\.tail[a-f0-9]+\.ts\.net` (Tailscale internal hostnames reveal network topology)
- `anthropic-key` — `sk-ant-[a-zA-Z0-9_-]+` (already in default; pin to make sure)

**Patterns to follow:**

- Subprocess + JSON-output pattern from `stow/claude/dot-claude/defuddle-webfetch.sh` (jaq @json escaping, fail-open
  mindset)

**Test scenarios:**

- Happy: fixture with known fake-secret pattern (`sk-test-deadbeefdeadbeefdeadbeefdeadbeef`) is replaced with
  `[REDACTED:generic-api-key]` placeholder
- Custom rule `op-uri`: fixture `op://secrets-dev/Brave Search API Key (Paid)/credential` is replaced with
  `[REDACTED:op-uri]`; the literal vault item title never lands in the corpus
- Custom rule `gbrain-postgres-dsn`: fixture
  `postgresql://kb_bigdaddy_wwdiji_app:hunter2@postgres.tail42ba87.ts.net:5432/kb_bigdaddy_wwdiji` is replaced; both the
  DSN body AND the `tail42ba87.ts.net` substring within it are redacted
- Custom rule `tailscale-hostname`: bare hostname `mybox.tail42ba87.ts.net` in a Bash output transcript is replaced with
  `[REDACTED:tailscale-hostname]`
- Custom rule `litellm-key`: `LITELLM_API_KEY=sk-litellm-abcd1234...` line is fully redacted
- Multiple findings on same line: all replaced, no offset drift, no chars lost
- No findings: input byte-identical to output (modulo trailing newline)
- gitleaks subprocess crash (kill -9 simulation): output gets warning header, content unredacted, audit event
  `redaction_failed`, exit 0
- False-positive in conversational text (e.g., a discussion of secret formats with an example string): redacted, BUT
  review-friendly because audit ledger names rule + location
- File with no detectable secrets but discussing the topic: nothing redacted

---

### U3. Systemd timer + service

**Goal:** Run U1's wrapper every 30 min as the safety-net path for sessions the hook missed.

**Requirements:** R2

**Dependencies:** U1

**Files:**

- `stow/gbrain/dot-config/systemd/user/claude-code-archive.service` (CREATE)
- `stow/gbrain/dot-config/systemd/user/claude-code-archive.timer` (CREATE)

**Approach:**

- Mirror `gbrain-sync.{service,timer}` shape exactly
- `.service`: `Type=oneshot`, `ExecStart=/home/brett/dotfiles/scripts/sync/claude-code-archive.sh`,
  `Environment=PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin`,
  `StandardOutput=append:%h/.gbrain/claude-code-archive.log`, `StandardError=append:%h/.gbrain/claude-code-archive.err`,
  hardening: `NoNewPrivileges=true`, `PrivateTmp=true`
- `.timer`: `OnCalendar=*:0/30`, `RandomizedDelaySec=60`, `Persistent=true`, `WantedBy=timers.target`
- Deploy via `scripts/stow-deploy gbrain` then `systemctl --user daemon-reload && systemctl --user enable --now
  claude-code-archive.timer`

**Patterns to follow:**

- `stow/gbrain/dot-config/systemd/user/gbrain-sync.service` and `.timer`

**Test scenarios:**

- After deploy + daemon-reload, `systemctl --user list-timers` shows `claude-code-archive.timer` with next-fire time
  within 30 min
- A jsonl manually dropped into `~/.claude/projects/test/` gets converted within one timer fire
- `Persistent=true` catches a missed run after laptop wake — verify in `journalctl --user -u claude-code-archive`
- Log files append, don't truncate, across runs

**Test expectation: minimal -- this is mostly declarative config; verification happens post-deploy via `list-timers` +
observed behavior.**

---

### U4. SessionEnd hook for real-time capture

**Goal:** At end of every Claude Code session, pre-archive that session's jsonl with low latency. Fire-and-forget; never
block shell exit.

**Requirements:** R2

**Dependencies:** U1, U4-pre (the payload-shape probe below)

**Files:**

- `stow/claude/dot-claude/claude-code-archive.sh` (CREATE — hook script)
- `stow/claude/dot-claude/settings.json` (MODIFY — add `SessionEnd` to `hooks` block)

**Execution note: do U4-pre first.** Before writing U4's hook, install a 3-line probe hook that dumps SessionEnd stdin
JSON to `/tmp/cc-sessionend-probe.json`. End a real CC session; inspect the file to confirm the actual payload shape
(specifically whether `transcript_path`, `cwd`, or only `session_id` is present). Write U4 against the confirmed schema.
Remove the probe hook after one session. The probe is throw-away; the receipt is the JSON file.

**Approach:**

- Hook receives session metadata as JSON on stdin per CC hook protocol — the U4-pre probe confirms the exact field set
- Use `$(cat)` not `$(</dev/stdin)` — `defuddle-webfetch.sh` documents an ENXIO bug under the latter pattern
- Extract via `jaq -r '.transcript_path // .session_id // ""'` — prefer `transcript_path` when CC supplies it (direct
  jsonl path, zero filesystem walk), fall back to `session_id` resolution; route all interpolated values through `jaq
  @json` if any go back as output
- Guard `command -v cc2md` and `command -v ~/dotfiles/scripts/sync/claude-code-archive.sh` — fail-open exit 0 if either
  is missing (timer will catch the session later)
- jsonl path resolution: (a) if `transcript_path` is set, use it directly; (b) else `find ~/.claude/projects -name
  "<session_id>.jsonl" -print -quit` (O(N) over a 1143-file tree, acceptable for a one-time hook fire)
- Invoke `nohup ~/dotfiles/scripts/sync/claude-code-archive.sh --single <jsonl> >/dev/null 2>&1 &` (fire-and-forget
  background)
- Always exit 0 — hook MUST NOT block shell exit on archive failure
- `settings.json` SessionEnd entry: matcher `""`, command `~/.claude/claude-code-archive.sh`, timeout 30
- Insert SessionEnd between existing `SessionStart` and `Stop` entries to preserve visual ordering

**Patterns to follow:**

- `stow/claude/dot-claude/solutions-prefetch.sh` — fail-open `set -uo pipefail`, jaq guards
- `stow/claude/dot-claude/defuddle-webfetch.sh` — `$(cat)` stdin pattern + jaq escaping

**Test scenarios:**

- Happy: end a CC session, archived markdown appears in corpus dir within seconds (latency bounded by cc2md+gitleaks per
  file)
- Hook fires when cc2md is missing: exit 0, warning to stderr, jsonl picked up by next timer sweep
- Hook fires during force-quit / OOM: best-effort; the timer is the safety net — DON'T treat this as a guarantee
- Hook input malformed (no `session_id`): exit 0 silently after audit warning
- Hook fires but archive.sh background process fails: exit 0 from hook (it's already detached); audit logs the failure
  on the background process side
- Concurrent sessions ending: each hook spawns its own background; audit JSONL writes are append-only and crash-safe

---

### U5. New qmd `claude-code-sessions` collection (default-excluded)

**Goal:** Make raw transcripts qmd-indexed but excluded from default `qmd query` results. Reachable via explicit `qmd
query -c claude-code-sessions "<phrase>"`.

**Requirements:** R5

**Dependencies:** U1 (corpus dir must exist with at least one markdown file before `qmd update`)

**Files:**

- `~/.config/qmd/index.yml` (MODIFY — add new collection BEFORE any `nas-*` entries per KTD5)

**Approach:**

- Run `qmd collection add ~/.gbrain/transcripts/claude-code/ --name claude-code-sessions`. Per `qmd collection`
  subcommand help, the positional is `<path>` and `--name` overrides the default-derived name. Pattern defaults to
  `**/*.md`; date-partitioned subdirs are walked recursively
- **Run `qmd collection exclude claude-code-sessions`** — this is the authoritative knob. Per `qmd collection exclude
  --help`: "Exclude collection in default queries". `qmd collection show` will then report `Include: no` for this
  collection. Verifiable via the existing `qmd collection show meum` shape — the `Include:` field is what controls
  default-query routing
- Verify ordering: open `~/.config/qmd/index.yml`, confirm `claude-code-sessions` entry is above any `nas-*` entries
  (per KTD5; one ENOENT in the NAS path halts the whole indexer)
- `qmd update -c claude-code-sessions` to populate the index
- `qmd embed -c claude-code-sessions` to generate vector embeddings

**Patterns to follow:**

- Existing `vault`, `solutions`, `meum` collection entries in `~/.config/qmd/index.yml` (all default `Include: yes`;
  this collection is the first deliberately-excluded one)
- `qmd collection include <name>` is the inverse if Brett later changes his mind

**Test scenarios:**

- Collection appears in `qmd collection list` after `add`
- `qmd collection show claude-code-sessions` reports `Include: no` after the `exclude` step
- `qmd query -c claude-code-sessions "<unique phrase from a known session>"` finds the expected file
- `qmd query "<phrase>"` (no `-c`) does NOT return the raw transcript — verified empirically (the `Include: no` flag
  scopes default queries to the other 14 included collections)
- Re-running `qmd update` is idempotent and only re-embeds changed files
- `qmd collection include claude-code-sessions` followed by `qmd query "<phrase>"` (no `-c`) DOES surface the transcript
  — confirms the toggle is the load-bearing knob

---

### U6. One-shot synthesize backfill sweep

**Goal:** After U1+U2+U7 (corpus populated, dir wired into gbrain config), run a manual synthesize sweep against the
historical sessions to populate meum-control brain pages. User-invoked, user-monitored, hand-rollable. Cost
observability via existing `~/.gbrain/audit/dream-budget-*.jsonl`; user stops the loop when satisfied.

**Requirements:** R4

**Dependencies:** U1, U2 (U7 recommended before this fires so the nightly loop picks up new sessions, but U6 is
independently executable against U1's corpus output)

**Files:**

- `scripts/sync/claude-code-synthesize-sweep.sh` (CREATE)

**Approach:**

- Enumerate `.md` files under `~/.gbrain/transcripts/claude-code/` (date-partition order so oldest sessions go first;
  the `dream_verdicts` content-hash cache no-ops already-judged files on repeat runs)
- Loop: `gbrain dream --phase synthesize --input <file> --json` per transcript
- Per-file audit event to `~/.gbrain/audit/claude-code-synthesize-sweep-$(date -u +%G-W%V).jsonl`: `{event: processed,
  session_id, file, verdicts_count, pages_written, exit_code}` (no cost field — that's in the dream-budget ledger gbrain
  already maintains)
- `--input` mode bypasses `checkCooldown` per `synthesize.ts` — confirmed
- NO enforced cost cap. User runs the script in one terminal pane and tails the dream-budget audit (`tail -f
  ~/.gbrain/audit/dream-budget-*.jsonl | jaq '.cumulative_cost_usd'`) in another. Stop the loop (Ctrl-C / SIGTERM) when
  satisfied. The script traps SIGINT/SIGTERM to write a final summary and exit cleanly
- Print summary at end (or on signal): total sessions processed, breakdown by verdict (cached / processed / skipped),
  pointer to the dream-budget ledger for the cost view
- NOT timer-driven — hand-invoked when user is ready

**Patterns to follow:**

- `scripts/sync/gbrain-dream.sh` for env loading + exec pattern
- `~/.gbrain/audit/dream-budget-*.jsonl` (read-only; the gbrain core already writes this)

**Test scenarios:**

- Happy: 10 input files → 10 `processed` audit events; final summary names sessions touched
- Verdict cache hit on second invocation: same files re-processed → zero LLM cost in dream-budget ledger, audit events
  show `verdicts_count` matching cache hits
- Single-file synthesize failure (gbrain dream exits non-zero for one file): wrap per-file, log to audit with exit_code,
  continue to next
- SIGINT mid-loop: trap fires, summary written, exit 0 (don't leave a half-finished audit line)
- No files in corpus dir: exit 0 with `summary` audit event saying 0 processed

---

### U7. Repoint `session_corpus_dir` + wire forward path

**Goal:** Once corpus has content, point gbrain at it so the existing nightly `gbrain-dream.timer` picks up new
transcripts automatically.

**Requirements:** R2 (forward path), R6 (no manual touch on steady state)

**Dependencies:** U1 (corpus has at least one file)

**Files:**

- Pure config — no new files

**Approach:**

- `gbrain config set dream.synthesize.session_corpus_dir ~/.gbrain/transcripts/claude-code/`
- Verify: `gbrain dream --phase synthesize --dry-run --json` shows transcripts discovered (no longer reports
  `session_corpus_dir is unset`)
- Document in audit: write one-time event `corpus_dir_set` to `~/.gbrain/audit/claude-code-archive-*.jsonl`
- Note the 12h `dream.synthesize.cooldown_hours` default means the nightly cycle processes only 1-2 new transcripts per
  fire on steady-state — that's by design and expected
- Self-consumption guard (`DREAM_OUTPUT_MARKER_RE` in `transcript-discovery.ts`) already protects against re-ingesting
  synthesized brain pages

**Patterns to follow:**

- Existing `gbrain config set` invocations in `~/.gbrain/config.json`

**Test scenarios:**

- After config set, `gbrain dream --phase synthesize --dry-run --json` reports discovered transcripts > 0
- Cooldown respected: second `gbrain dream` call within 12h sees `cooldown_active` skip reason — that's correct
- A fresh session ending now (via the hook) appears in the next cycle's discovery
- `dream_generated: true` frontmatter on synthesized pages prevents re-ingestion when synthesize writes to a path that
  overlaps the corpus dir (defense in depth — our corpus dir doesn't overlap meum-control, but the guard is the safety
  net)

**Test expectation: minimal -- pure config; verification via the dry-run output.**

---

## Scope Boundaries

### In scope

All 7 units above. The plan stands up backfill + forward capture + redaction + qmd + synthesize wire-up in one coherent
piece.

### Deferred to follow-up work

- **ghost installation** — explicitly skipped per user; full transcripts give synthesize more signal than ghost's lossy
  digest, and ghost's per-repo storage model fights the unified-corpus design here
- **jsonl → ghost-format converter** — same rationale; format chosen is full cc2md transcript
- **Per-project corpus layout** — flat date-partitioned chosen (user said no preference, session-level); per-project
  could be revisited if synthesize scoping becomes an issue
- **Redaction backfill of pre-existing meum-control brain pages** — synthesize-output redaction is a separate concern;
  this plan ensures input is clean post-gitleaks but does not re-scan existing brain pages
- **Cleanup policy for the corpus dir** — Claude Code drops jsonl after 30d, but our corpus is permanent; whether to
  archive past N months is an OQ
- **Solutions-docs entry** — `/ce-compound` after this lands; corpus has no prior art on gitleaks-as-redactor pattern
  (per learnings researcher)

### Out of scope

- Changes to upstream gbrain code (the synthesize phase, dream flag surface, `--max-usd` ergonomics) — this plan
  operates against the current gbrain CLI. If those flags would help, they go to a separate gbrain upstream PR
- Voice notes / meeting transcripts via `dream.synthesize.meeting_transcripts_dir` — separate pipeline
- Sharing the corpus or qmd index off-machine — local-only assumption underpins the redaction posture

---

## Open Questions

- **OQ1** — gitleaks performance for the 1143-file backfill. If gitleaks proves too slow (>100ms per file × 1143 ≈ 2
  min, acceptable), no action. If much slower, U2 could ship a regex-only fast path for backfill + full gitleaks for
  forward-capture. Decide at execution after measuring one batch.
- **OQ2** — Hook fire-and-forget vs sync. Plan picks fire-and-forget (background `nohup`). If session-end UX is
  unaffected by waiting ~1-2s for archive, sync is simpler. Verify in practice; revert is one-line.
- **OQ3** — Corpus cleanup / archive policy past N months. Out of scope for this plan; revisit after corpus exceeds ~5K
  files or 5GB.

---

## Risks

- **Risk-1 — Cost surprise from U6 backfill sweep** — Mitigated by manual invocation (not on a timer) + real-time
  observability via the existing `~/.gbrain/audit/dream-budget-*.jsonl` ledger; user stops the loop when satisfied. No
  enforced cap, so accidental runaway requires user inattention. Risk: low if monitored.
- **Risk-2 — gitleaks false positives redact innocent text** — Acceptable. Audit ledger names rule + location per
  redaction; manual review is mechanical. Conversational discussion of secret formats (e.g., "an OpenAI key looks like
  sk-...") may get scrubbed, but the placeholder + audit makes recovery possible. Risk: low.
- **Risk-3 — cc2md schema drift on future Claude Code versions** — cc2md is community-maintained (magarcia); a schema
  change could break conversion. Mitigation: pin cc2md version via brew (already at v0.1.0); monitor `cc2md` parse
  errors in audit. Risk: medium long-term; low near-term.
- **Risk-4 — SessionEnd hook misses abrupt termination** — Mitigated by the 30-min timer safety net (KTD1). The hook is
  the warm path; the timer is the correctness guarantee. Risk: low given the mitigation.
- **Risk-5 — qmd index.yml ordering trap** — If `claude-code-sessions` accidentally lands after any `nas-*` entries and
  a NAS path is unreachable, indexing fails fast for ALL collections from that point. Mitigated by explicit ordering
  check in U5 + the existing learnings doc. Risk: low if checked.
- **Risk-6 — `permissions.allow` silently overriding hook decisions** — Per
  `~/dev/solutions-docs/tooling/claude-code-pretooluse-hook-defuddle-webfetch-integration-20260325.md`, this is a known
  footgun for hooks that gate behavior. Our hook is fire-and-forget — it does not gate anything — so this doesn't apply.
  Calling out for completeness.
- **Risk-7 — Backfill spend on a fresh `dream_verdicts` cache** — Initial sweep runs verdict on all 1143; even at
  Haiku-tier (`tier.utility = litellm:gpt-5.4-mini`), order-of-magnitude is ~$10-25 in verdict calls alone before any
  Sonnet-tier synthesis (per-token rate × estimated transcript size has not been worked out; the dream-budget audit
  ledger is the authoritative real-time view). User-monitored via that ledger per Risk-1; stop the loop early if spend
  exceeds appetite. Subsequent runs reuse the verdict cache on the same `(file_path, content_hash)` pair.

---

## Sources & Research

### Local research

- `~/dotfiles/scripts/sync/gbrain-{sync,dream}.sh` — wrapper script templates; the `set +e / source / set -e`
  env-loading sandwich is load-bearing
- `~/dotfiles/stow/gbrain/dot-config/systemd/user/gbrain-{sync,dream}.{service,timer}` — unit templates
- `~/dotfiles/stow/claude/dot-claude/{solutions-prefetch,defuddle-webfetch}.sh` — hook templates (fail-open, `$(cat)`
  stdin pattern, jaq guards)
- `~/dotfiles/stow/claude/dot-claude/settings.json` — current hooks block; `SessionEnd` not yet registered
- `~/gbrain/src/commands/dream.ts` — flag surface confirmed: no `--bypass-cooldown`, no `--max-usd`; `--input` mode
  bypasses cooldown logic
- `~/gbrain/src/core/cycle/synthesize.ts:598-674` — `loadSynthConfig`, `checkCooldown`; cooldown only fires on
  corpus-dir-scan path
- `~/gbrain/src/core/cycle/transcript-discovery.ts` — `.txt`/`.md` walker; `DREAM_OUTPUT_MARKER_RE` self-consumption
  guard
- `~/.gbrain/audit/dream-budget-*.jsonl` — ISO-week JSONL schema reference

### Institutional learnings

- `~/dev/solutions-docs/deployment-issues/cron-to-systemd-user-timers-dotfiles-stow.md` — systemd timer pattern; `flock
  -n` + `OnFailure=` recovery service convention (consider for follow-up; not required for v1)
- `~/dev/solutions-docs/deployment-issues/qmd-collection-ordering-nas-resilience-20260403.md` — `index.yml` ordering
  crash semantics (KTD5)
- `~/dev/solutions-docs/tooling/qmd-claude-code-knowledge-search-integration.md` — `command -v qmd` guard pattern for
  hooks
- `~/dev/solutions-docs/tooling/claude-code-pretooluse-hook-defuddle-webfetch-integration-20260325.md` — hook gotchas
  (R6)
- `~/dev/solutions-docs/developer-experience/agent-ci-monitoring-via-posttooluse-hook-20260415.md` — fire-and-forget
  hook skeleton
- `~/dev/solutions-docs/runtime-errors/tmux-server-wedge-orphan-clients-2026-06-11.md` — hook + daily-timer dual-channel
  pattern validation (KTD1)
- `~/dev/solutions-docs/architecture-patterns/cross-platform-stow-package-gating-2026-05-17.md` — stow gating for
  Linux-only `.timer`/`.service`
- `~/dev/solutions-docs/deployment-issues/stow-conflict-resolution-wrapper.md` — use `scripts/stow-deploy`, never raw
  `stow`
- `~/dev/solutions-docs/integration-issues/gbrain-litellm-recipe-codex-proxy-routing.md` — production-validated model
  mapping (cited for context; this plan does not change it)

### External

- `https://github.com/magarcia/cc2md` — v0.1.0, MIT, brew-installable via `magarcia/tap/cc2md`. No batch mode; pipeline
  pattern documented in README's "Archiving Your Conversations in Git" section.
- `gitleaks` — Brett's existing homebrew install; `--redact` is detection-only, custom shim required for in-place
  mutation.
- Claude Code hook protocol —
  `SessionStart`/`SessionEnd`/`UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`Stop`/`Notification` events confirmed
  available; SessionEnd fires on session close.

### Unexplored — file via `/ce-compound` after landing

- gitleaks as a sanctioned redaction subprocess with JSON-output parsing — corpus has zero direct prior art
- gbrain `sync.repo_path` / synthesize-output routing pitfalls — corpus has no entries; gbrain-internal docs live in
  `docs/architecture/`, not `docs/solutions/`
