---
title: "feat: add a docs-drift audit that mechanically verifies the root CAPITAL documentation"
date: 2026-08-10
status: implementation-ready
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
plan_type: feat
---

# feat: add a docs-drift audit that mechanically verifies the root CAPITAL documentation

## Summary

`scripts/docs-audit.py` turns "the root documentation is accurate" from an assertion into a command. It extracts the
structural claims the nine root CAPITAL-letter documents make about the repository — table rows, layout-tree paths,
package lists, counts, relative links — and compares each against the repository as-built, exiting non-zero with a
per-rule finding list.

This plan is a hard prerequisite for
[`2026-08-10-031-docs-release-cut-and-capital-doc-accuracy-plan.md`](./2026-08-10-031-docs-release-cut-and-capital-doc-accuracy-plan.md).
That plan's acceptance criterion — "100% up to date" — is defined as `scripts/docs-audit.py` exiting `0`. The audit must
therefore exist, and must reach the release branch by cherry-pick, before the doc pass can claim anything.

It lands on `dev` through the standard feature-branch → PR flow, because it is code plus a change to a consumer-facing
runbook (`RELEASES-PREFLIGHT.md`). It must merge to `dev` **before** the release branch is cut.

## Context and rationale

Seven of the nine root CAPITAL documents were last touched on `2026-06-26`, the date of the last release. `README.md`
was touched only by unrelated feature work. Substantial work has landed since, and a sample audit against the filesystem
already finds concrete, mechanically-detectable drift:

- `README.md`'s Stow-package table has 33 rows against 34 packages on disk. The `shell` package — the root of the entire
  shell config chain, and the first entry in `SHARED_PACKAGES` — has no row.
- `README.md`'s `local` package row names 4 binaries; `stow/local/dot-local/bin/` holds 14. Nine user-facing CLIs are
  undocumented.
- `README.md`'s repo-layout tree omits `scripts/nightly-autocommit.sh`, `scripts/qmd-llama-rebuild.sh`,
  `scripts/rectangle-defaults.sh`, `scripts/setup_gogcli.sh`, `scripts/sync-dev-after-release.sh`, `scripts/tmux/`,
  `snapshots/`, `cliff.toml`, and `docs/progressive-disclosure-evals.md`.
- `AGENTS.md`'s "Current units" list omits `config/systemd/system/apparmor-playwright.service`.
- `BOOTSTRAP.md`'s manual stow package lists omit `gbrain` and `codex-proxy` from both platform lines, and omit six more
  from the macOS line, against `SHARED_PACKAGES` / `DESKTOP_PACKAGES` in `scripts/stow-deploy`.
- `README.md` and `RELEASES.md` disagree about whether `protect-main.json` carries required status checks. The ruleset
  file settles it: it does.

Every one of those is a set-equality or path-existence question. A person re-checking them by eye each release is the
failure mode that produced this drift. Prior art in the solutions corpus argues the same point from the other side: an
audit script with no check for the thing the prose prescribes reports "compliant" while the biggest gap sits in plain
sight (`docs/solutions/best-practices/audit-scripts-as-documentation-immune-system-2026-04-20.md`). The rule set below
is therefore derived from the claims the documents actually make, not from a generic checklist.

### Decision: Python, stdlib-only, not shell

`scripts/generate-changelog.py` is the in-repo precedent for a non-trivial release-support tool. Markdown table parsing
and set-difference reporting are miserable in shell and cheap in Python. The script is stdlib-only (no `uv run`, no
venv) so it can be invoked from a bare launcher, and sets `sys.dont_write_bytecode = True` at the top so it leaves no
`__pycache__` in the project tree.

### Decision: not wired as an enforcing required check this cycle

`shellcheck` and `bats` are required status checks on both `dev` and `main` (`.github/rulesets/protect-dev.json`,
`.github/rulesets/protect-main.json`). Wiring the audit into `tests/` as an assertion that the live repo is drift-free
would turn the required `bats` check red on `dev` the moment this PR opens, because the docs are stale — the PR could
not merge. `tests/docs-audit.bats` is therefore a **smoke test only**: it asserts the script runs, honors `--json`, and
reports a known finding against a synthetic fixture. Flipping it to enforce against the live repo is a named follow-up
(see Open Questions), taken after the doc pass has landed on `dev` via the release backport.

## Assumptions

1. `python3` on both host classes is 3.11 or newer. `scripts/generate-changelog.py` already uses `X | None` union
   syntax, so this is an existing repo requirement rather than a new one.
2. Features 1 and 2 (the tool-declaration audits, planned in parallel) may add or remove `stow/` packages,
   `config/shell/` fragments, and `stow/brew/Brewfile` entries before this lands. The audit is written against
   *structure*, not against today's contents, so their changes surface as findings rather than as script edits.
3. The nine files are exactly: `AGENTS.md`, `BOOTSTRAP.md`, `CHANGELOG.md`, `CONCEPTS.md`, `PROJECT.md`, `README.md`,
   `RELEASES.md`, `RELEASES-PREFLIGHT.md`, `RELEASES-RATIONALE.md`.

## Guardrails

- Repo-relative paths only in code, tests, and prose. No `/Users/<name>/`, no `/home/<name>/`, no machine hostnames.
- Never `git add` any `TODO*.md` / `*todo*.md` variant or anything under `.context/`. The repo root carries an untracked
  `todos/` directory; it stays untracked.
- `trash`, never `rm` / `git rm`. `rg` not `grep`, `fd` not `find`, `jaq` not `jq`.
- Every commit message and the PR body are authored in a `/tmp/` file, scrubbed with `/unslop`, and submitted via `git
  commit --file` / `gh pr create --body-file`. Never inline `-m`, never a heredoc — a PreToolUse hook rejects it.
- Conventional Commits. No AI attribution in any commit or PR body.
- Do not hand-edit `CHANGELOG.md`.

---

## Unit 1 — `scripts/docs-audit.py`

**Files:** `scripts/docs-audit.py` (new).

### Interface

```text
scripts/docs-audit.py [--json] [--rule ID ...] [--strict] [--repo PATH]
```

- Default: human-readable report grouped by rule, then by file. Exit `0` only when zero errors.
- `--json`: `{"errors": N, "warnings": N, "findings": [{"rule", "severity", "file", "line", "message"}]}` on stdout,
  nothing else. Same exit code.
- `--rule ID`: run only the named rule(s). Repeatable. Used by the doc pass to iterate on one file at a time.
- `--strict`: promote `warning`-severity findings to errors.
- `--repo PATH`: audit an arbitrary checkout (default: the script's own repo root). Required by the bats fixture test.

### Rules

Each rule is one function with one responsibility, registered in a `RULES` dict keyed by id. The file will exceed 200
lines; that is the documented uniform-function-file exemption to the 200-line refactor trigger — evaluate it by SRP, and
each rule function is single-purpose. If any rule function needs more than roughly 40 lines, extract its parser into
`scripts/lib/` rather than growing the rule.

| Id                     | Claim under test                                                                                                        | Source of truth                                                                                 | Severity |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | -------- |
| `stow-table`           | `README.md` § Stow Packages table rows                                                                                  | directories directly under `stow/` (ignore `.stow-global-ignore`)                               | error    |
| `stow-deploy-coverage` | every package is in `SHARED_PACKAGES`/`DESKTOP_PACKAGES` or named in README's outside-`--all` prose                     | `scripts/stow-deploy` array literals                                                            | error    |
| `shell-fragments`      | `README.md` § Shell Environment table rows                                                                              | files in `config/shell/`                                                                        | error    |
| `layout-paths-exist`   | every path token in `README.md`'s Repository Layout fenced block resolves                                               | filesystem (`Path.exists()`, glob-aware for entries like `*-enable.sh`)                         | error    |
| `layout-coverage`      | every tracked entry at repo root, and directly under `scripts/`, `config/`, `docs/`, `.github/`, is named in that block | `git ls-files` (tracked only, so untracked `todos/` and `.context/` never appear)               | error    |
| `hooks-table`          | git-hook tables in `README.md` **and** `AGENTS.md`                                                                      | `.githooks/` (excluding `setup`)                                                                | error    |
| `workflows-table`      | `README.md` § CI and Testing table rows                                                                                 | `.github/workflows/*.yml`                                                                       | error    |
| `systemd-units`        | system-unit lists in `README.md` and `AGENTS.md`                                                                        | `config/systemd/system/`                                                                        | error    |
| `apparmor-profiles`    | AppArmor profile tables in `README.md` and `AGENTS.md`                                                                  | `config/apparmor.d/`                                                                            | error    |
| `bootstrap-stow-lists` | the two manual `stow --dotfiles ...` package lists in `BOOTSTRAP.md`                                                    | `SHARED_PACKAGES` (headless line), `SHARED_PACKAGES + DESKTOP_PACKAGES` (macOS line)            | error    |
| `local-bin`            | binaries named in `README.md`'s `local` package row                                                                     | `stow/local/dot-local/bin/`                                                                     | error    |
| `counts`               | every `N <noun>` numeric claim registered in `COUNT_CLAIMS`                                                             | the matching filesystem count                                                                   | error    |
| `links`                | every relative markdown link target and every backticked repo path in the nine files resolves                           | filesystem; `docs/solutions` is a symlink and counts as resolving                               | error    |
| `privacy`              | no `/Users/<name>/`, no `/home/<name>/` other than `/home/linuxbrew`, no host literal                                   | the host literal is read out of `scripts/tailscale-serve-setup.sh` at runtime, never hardcoded  | error    |
| `temporal`             | no temporal-narration tokens in the nine files                                                                          | regex list; `CHANGELOG.md` exempt in full, `RELEASES.md` exempt inside release-history sections | warning  |
| `changelog-generated`  | `CHANGELOG.md` is generator-faithful                                                                                    | delegates to `scripts/generate-changelog.py --check`; skipped when git-cliff is absent          | error    |

`COUNT_CLAIMS` is a small table mapping a regex to a counting callable, seeded with `PROJECT.md`'s "N stow packages" and
"N shell environment fragments", and `README.md`'s tmuxinator "N projects". Adding a claim means adding a row.

`layout-coverage` needs a deliberate-omission allowlist (dot-files the tree does not enumerate). Keep it as a
module-level frozenset with a one-line WHY per entry, under ten entries. If it grows past that, the tree is the thing
that is wrong, not the allowlist.

The `privacy` rule must never contain a hostname literal in its own source. It reads `EXPECTED_HOST` out of
`scripts/tailscale-serve-setup.sh` at runtime and searches for that value. A rule that hardcodes the secret it is
guarding against is the leak.

### Verification

1. `python3 scripts/docs-audit.py --help` exits `0` and prints the interface above.
2. `python3 scripts/docs-audit.py --json | jaq -e '.findings | length > 0'` succeeds on the current `dev` tree — the
   audit must *find* the known drift, not report a clean repo. Confirm by eye that the findings include at least: the
   missing `shell` row (`stow-table`), the stale `local` row (`local-bin`), the missing `apparmor-playwright.service`
   (`systemd-units`), and the `BOOTSTRAP.md` package-list divergence (`bootstrap-stow-lists`).
3. `python3 scripts/docs-audit.py --rule stow-table --json | jaq -r '.findings[].rule'` prints only `stow-table`.
4. `python3 scripts/docs-audit.py` exits non-zero while findings exist, and the human report names every finding's file
   and line.
5. `fd -H __pycache__ .` returns nothing after every invocation above.
6. `python3 -m py_compile scripts/docs-audit.py` exits `0`. (`shellcheck` does not cover Python, so this is the
   equivalent syntax gate.)
7. `rg -n 'ollama\.|\.ts\.net|/Users/|/home/(?!linuxbrew)' scripts/docs-audit.py` returns nothing — the audit source
   itself is privacy-clean.

---

## Unit 2 — `tests/docs-audit.bats`

**Files:** `tests/docs-audit.bats` (new).

Smoke coverage only. Deliberately does **not** assert the live repo is clean.

Cases:

1. `--help` exits `0`.
2. `--json` against a synthetic fixture repo (built in `setup()` under `$BATS_TEST_TMPDIR`) emits parseable JSON.
3. The fixture, seeded with a `stow/` package that has no README row, produces exactly one `stow-table` error.
4. The fixture, corrected, produces zero `stow-table` errors and exit `0` for `--rule stow-table`.
5. `--rule` with an unknown id exits non-zero with a usage error rather than silently passing. A rule-id typo that
   silently passes is exactly how an audit reports "compliant" while checking nothing.

The fixture must be built entirely inside `$BATS_TEST_TMPDIR` and must never invoke `scripts/stow-deploy` or touch the
real `$HOME` — `tests/stow-deploy-*.bats` carry the same constraint for the same reason.

### Verification

1. `bats tests/docs-audit.bats` fully green.
2. `bats tests/` fully green (no interference with the other 15 suites).
3. `git status --short` after the run is clean apart from the intended new files, and nothing was written outside
   `$BATS_TEST_TMPDIR`.

---

## Unit 3 — `RELEASES-PREFLIGHT.md` wiring

**Files:** `RELEASES-PREFLIGHT.md` (modified).

Add one section between `### Changelog completeness` and `### Cross-platform deploy sanity`:

- Heading: `### Documentation accuracy`.
- One checkbox: `scripts/docs-audit.py` exits `0`. Findings hold the release; fix the document, not the audit, unless
  the audit's expectation is itself wrong.
- One sentence naming what the audit does and does not cover: it verifies structural claims (tables, paths, counts,
  links); it cannot verify prose, so prose accuracy stays a read-through.

Write it in present tense. Do not narrate that the check is new.

### Verification

1. `markdownlint-cli2 RELEASES-PREFLIGHT.md` clean.
2. `python3 scripts/docs-audit.py --rule links` reports no new finding for `RELEASES-PREFLIGHT.md` — the new reference
   resolves.
3. Every command in the new section runs as written from the repo root.

---

## Sequencing

`Unit 1` → `Unit 2` → `Unit 3`. Units 2 and 3 both depend on Unit 1's interface being final.

## Landing

1. Branch: `feat/docs-audit`, cut from `dev`.
2. Commits (each authored in `/tmp/commit-msg-$(uuidv7).md`, `/unslop`-scrubbed, submitted with `git commit --file`):
   - `feat(scripts): add docs-audit drift checker for root documentation`
   - `test(docs-audit): cover the audit CLI against a synthetic fixture`
   - `feat(releases): gate the release cut on the documentation audit`

   The third is `feat`, not `chore` or `docs`, because it adds a gate a release operator must satisfy. `cliff.toml`
   drops `chore`, `style`, `test`, `ci`, and `build` from the changelog, so a user-observable change typed `chore`
   vanishes from the release notes.
3. Push. The `.githooks/pre-push` hook runs `shellcheck` and `bats` locally; both must pass before the push completes.
4. PR to `dev`, title `feat(scripts): add a documentation drift audit`. Body authored in
   `/tmp/pr-body-dotfiles.feat-docs-audit.md`, filled from `.github/pull_request_template.md`, scrubbed with `/unslop`,
   submitted with `--body-file`, then `trash`ed on success.
5. Fill `## Changelog → ### Added` with the audit and the preflight gate. This PR body is the changelog input for both.
6. Watch CI. `shellcheck` and `bats` are required on `dev`. A completed watcher is not a green watcher — confirm with
   `gh pr view <num> --json statusCheckRollup,mergeStateStatus` and assert every conclusion is `SUCCESS`.
7. Squash-merge.

## Acceptance criteria

- [ ] `scripts/docs-audit.py` exists, is stdlib-only, writes no bytecode, and implements every rule in the table.
- [ ] Run against the current `dev` tree it reports findings that include the six concrete drifts named in § Context.
- [ ] `bats tests/docs-audit.bats` green; `bats tests/` green.
- [ ] `RELEASES-PREFLIGHT.md` carries the gate, is markdownlint-clean, and its new commands run as written.
- [ ] Merged to `dev` with `shellcheck` and `bats` both `SUCCESS`.
- [ ] No `__pycache__`, `.venv`, `.pytest_cache`, or `uv.lock` anywhere in the tree afterwards.

## Open questions (recorded, not blocking)

1. **When does the bats test start enforcing against the live repo?** Recommendation: a follow-up PR after the release
   backport lands the corrected docs on `dev`, converting `tests/docs-audit.bats` to run `scripts/docs-audit.py` against
   the repo root and assert exit `0`. That makes documentation drift a red required check. It cannot happen in this PR
   without blocking this PR.
2. **Should `temporal` be an error rather than a warning?** It is regex-driven and will produce false positives on
   legitimate uses (the word "legacy" inside a quoted upstream name). Warning by default, `--strict` to escalate.
   Revisit once the false-positive rate is known.
3. **Should the audit cover `stow/claude/dot-claude/` documentation too?** Out of scope here: those files are deployed
   user configuration, not this repo's own front door. Named so the boundary is explicit.
