---
title: "feat: CalVer backport + release-pipeline repair for dotfiles"
date: 2026-06-16
type: feat
status: ready
depth: standard
---

# feat: CalVer backport + release-pipeline repair for dotfiles

## Summary

Adapt the `github-repo-setup` "quad release pipeline" to this CalVer + git-cliff + stow repo, lean. Two concrete
outcomes: (1) repair the release runbook, whose changelog generator reference is dead; (2) add a CalVer-specific
post-release **backport-to-dev** mechanism so `dev` stops drifting behind `main` on release-only files (the CHANGELOG
foremost). Then heal the existing drift as the first run of the new mechanism, leaving the tree ready to cut a release.

Scope decisions (confirmed): **lean** adaptation (vendor two scripts + update `RELEASES.md`; no extra quad docs, no
orchestrator scripts); backport lands **via PR to dev**; **no** CI guard workflows.

---

## Problem Frame

The release flow is `feat → dev → release/* → main`; pushing `release/*` into `main` triggers `release.yml`, which
computes a CalVer tag (`YYYY.MM.DD[.N]`), reads the top `## [version]` section of `CHANGELOG.md` as release notes, tags,
and publishes a GitHub Release. Two defects:

1. **Dead generator reference.** `RELEASES.md` (lines ~133, ~168, ~263) instructs the release author to run
   `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh`. That file no longer exists. The runbook's
   changelog step is currently unrunnable as written.
2. **Silent `dev` drift.** `release/*` is cut from `origin/main` and regenerates `CHANGELOG.md` (plus occasional README
   / `RELEASES.md` release-prep polish) that never round-trips to `dev`. `RELEASES.md` even states "`dev` is untouched."
   Result: `dev`'s `CHANGELOG.md` is frozen at `## [2026.04.15]` while `main` has shipped through `2026.06.03`. This is
   the exact pattern documented in
   `docs/solutions/workflow-issues/post-release-backport-prevents-diff-b-false-positives-2026-05-07.md`, and it makes
   the next release's triple-diff "B" step noisy enough to hide a real missed cherry-pick.

The skill ships `templates/sync-dev-after-release.sh` and `templates/generate-changelog.py`, but both assume SemVer
(`vX.Y.Z`) branch/tag shapes and a plain-text `VERSION` file — neither of which exists here. They need CalVer adaptation
before they fit.

---

## Requirements

- **R1** — The release runbook's changelog step must reference a generator that exists in-repo and works for CalVer.
- **R2** — A repeatable, surgical backport brings `main`'s release-only files (default: `CHANGELOG.md`) onto `dev` after
  each release, via a PR to `dev`.
- **R3** — The backport must be **surgical**, never a blanket `dev`↔`main` sync. `dev` is ~132 commits ahead of `main`;
  any merge or wholesale checkout would revert unreleased work. Only named release-artifact files move, and only `main →
  dev`.
- **R4** — CalVer is first-class: version validation accepts `YYYY.MM.DD` and same-day `YYYY.MM.DD.N`; no `v` prefix; no
  `VERSION` file.
- **R5** — The existing `dev` drift is healed (dev's `CHANGELOG.md` brought current with `main`@`2026.06.03`) as the
  first exercise of the new mechanism.
- **R6** — `RELEASES.md` documents the new backport step as a required post-merge action in the release lifecycle.

---

## Key Technical Decisions

- **KTD1 — Surgical backport, explicit allowlist.** The script copies named files from `origin/main` via `git checkout
  origin/main -- <file>` (the skill's approach), defaulting to `CHANGELOG.md`. It never merges branches or diffs the
  whole tree. This is the single most important safety property — see R3. Other release-prep files (`README.md`,
  `RELEASES.md`) are folded into the same PR by hand only when they actually drifted; the runbook says how.
- **KTD2 — CalVer adaptation, no `VERSION` file.** Replace the SemVer regex `^v[0-9]+\.[0-9]+\.[0-9]+$` with
  `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$`. Drop `VERSION_NO_V` and the `VERSION` write entirely (this repo derives
  the version from the date in CI; there is no file).
- **KTD3 — Backport via PR to dev.** Mirrors the skill's script and honors `RELEASES.md`'s "no direct commits to dev"
  rule. The PR body is composed in a `mktemp` file and submitted with `--body-file` (never inline `--body`), consistent
  with the repo's PR-authoring convention.
- **KTD4 — Vendor `generate-changelog.py`, teach it CalVer branches.** Vendor the skill's PEP 723 `uv run` generator to
  `scripts/generate-changelog.py`. Extend `detect_tag_from_branch()` to also match `release/YYYY.MM.DD[.N]` so the
  runbook no longer depends on the fragile `--tag` workaround; keep `--tag` working. The script's `v`-stripping logic is
  already a no-op for CalVer tags (they don't start with `v`), so no other version-handling change is needed.
- **KTD5 — Lean, no guards, no orchestrator scripts.** A config-only repo with a date-computed CI release does not need
  the Rust/crates/homebrew-oriented preflight/postflight orchestrators or the RATIONALE/PREFLIGHT/POSTFLIGHT docs. The
  backport step lives inline in `RELEASES.md`. Guard workflows are out (manual triple-diff stays).

---

## Implementation Units

### U1. Vendor + CalVer-adapt `scripts/generate-changelog.py`

**Goal:** Replace the dead `rust-tool-release/scripts/generate-changelog.sh` reference with an in-repo, CalVer-aware
generator that reproduces the existing `CHANGELOG.md` format (git-cliff section + PR-body `## Changelog` expansion with
author/PR attribution).

**Requirements:** R1, R4.

**Dependencies:** none.

**Files:**

- `scripts/generate-changelog.py` (new; vendored from
  `~/.claude/skills/github-repo-setup/templates/generate-changelog.py`, then adapted)
- `tests/generate-changelog.bats` (new)

**Approach:**

- Copy the template verbatim, then change `detect_tag_from_branch()`: accept `release/YYYY.MM.DD` and
  `release/YYYY.MM.DD.N` in addition to `release/vX.Y.Z`. Return the matched string as the tag unchanged (no `v`).
- Update the failure message to name the CalVer branch shape.
- Leave `--tag`, `--check`, `--dry-run`, and the git-cliff + PR-expansion pipeline intact. The `tag[1:] if
  startswith("v")` line stays — harmless for CalVer.
- Keep the `#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 uv run --script` shebang (repo standard: `uv run` for Python).
- Confirm `[remote.github]` in `cliff.toml` already provides owner/repo for PR-body expansion (it does).

**Patterns to follow:** existing bats suites `tests/supply-chain-gate.bats`, `tests/shell-config.bats` for structure;
the script's own `--check` / `--dry-run` modes as offline-testable seams.

**Test scenarios (`tests/generate-changelog.bats`):**

- `--check` against a `CHANGELOG.md` whose top section is `## [Unreleased]` only → exit 1.
- `--check` against a `CHANGELOG.md` with a versioned `## [2026.06.03]` top section → exit 0.
- CalVer branch detection: on a worktree/branch named `release/2026.06.16`, the script resolves tag `2026.06.16` without
  `--tag`.
- Same-day suffix: branch `release/2026.06.16.1` resolves tag `2026.06.16.1`.
- `--tag 2026.06.16` passthrough still works when not on a release branch.
- Note: full generation needs `GITHUB_TOKEN` + network; tests cover the offline seams (`--check`, branch detection)
  only.

**Verification:** `bats tests/generate-changelog.bats` green; `scripts/generate-changelog.py --check` runs against the
repo's `CHANGELOG.md` and exits per its top section.

### U2. Vendor + CalVer-adapt `scripts/sync-dev-after-release.sh` (the backport)

**Goal:** A repeatable, surgical post-release backport that lands `main`'s `CHANGELOG.md` (and any named release
artifacts) onto `dev` via a PR.

**Requirements:** R2, R3, R4.

**Dependencies:** U1 (the post-sync drift check shells out to `scripts/generate-changelog.py --dry-run`).

**Files:**

- `scripts/sync-dev-after-release.sh` (new; vendored from
  `~/.claude/skills/github-repo-setup/templates/sync-dev-after-release.sh`, then adapted)
- `tests/sync-dev-after-release.bats` (new)

**Approach:**

- **Argument:** one positional CalVer version. Validate with `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$`; reject SemVer
  and garbage (KTD2). Drop `VERSION_NO_V`.
- **Preflight guards (keep from template):** clean working tree; `git fetch origin --tags`; tag exists locally; tag is
  an ancestor of `origin/main` (release actually merged); GitHub Release exists and is not draft (skip gracefully if
  `gh` absent).
- **Backport body (adapt):** `git switch dev && git pull --ff-only`; cut `chore/sync-dev-after-<version>`; surgically
  `git checkout origin/main -- CHANGELOG.md` (KTD1) — **remove the `VERSION` write**. If no diff, clean up and exit 0
  (idempotent).
- **Drift sanity (adapt):** if `scripts/generate-changelog.py` is executable and `git-cliff` is on PATH, run `--dry-run
  --tag <version>`; warn (don't fail) on drift.
- **PR (keep):** push branch; compose PR body in `mktemp`; `gh pr create --base dev --body-file ...`. Title
  `chore(release): sync dev after <version>`. No AI-attribution trailer.
- Set `set -euo pipefail`; full-path independence is fine (interactive script, not a systemd unit).

**Technical design (directional, not spec):**

```text
validate CalVer arg
guard: clean tree, tag exists, tag ⊆ origin/main, GH release published
switch dev; ff-pull; branch chore/sync-dev-after-<v>
git checkout origin/main -- CHANGELOG.md      # surgical; never a merge
if no diff -> cleanup + exit 0
commit; optional generate-changelog.py --dry-run drift warning
push; gh pr create --base dev --body-file <mktemp>
```

**Patterns to follow:** `tests/heredoc-pr-guard.bats` and `tests/pre-push-skip-md-only.bats` for testing a bash script's
pure logic; existing `scripts/sync/*.sh` for bash house style.

**Test scenarios (`tests/sync-dev-after-release.bats`):**

- Version validation accepts `2026.06.03` and `2026.06.03.1`; rejects `v1.2.3`, `2026.6.3`, `latest`, empty → exit 64.
- Dirty working tree → exits non-zero before touching branches.
- Missing tag locally → clear error, exit 66 (stub `git`/`gh` or run in a fixture repo).
- Idempotent no-op: when `dev`'s `CHANGELOG.md` already matches `origin/main`, the script exits 0 and creates no branch
  (assert via a fixture or a mocked `git checkout`/`git diff`).
- No inline `gh pr create --body "..."`: assert the script uses `--body-file` (guards against the heredoc PreToolUse
  hook and the repo convention).

**Verification:** `shellcheck scripts/sync-dev-after-release.sh` clean; `bats tests/sync-dev-after-release.bats` green;
`scripts/sync-dev-after-release.sh 2026.06.03` (real run in U4) opens a dev PR whose only changed file is
`CHANGELOG.md`.

### U3. Update `RELEASES.md` — fix the dead reference, document the backport

**Goal:** The runbook points at the vendored generator and includes the post-release backport as a required step.

**Requirements:** R1, R6.

**Dependencies:** U1, U2 (references the files they create).

**Files:**

- `RELEASES.md` (modify)

**Approach:**

- Replace every `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh` reference (steps in "Releasing dev to
  main", "CHANGELOG is generated, never hand-written", and "Troubleshooting") with `scripts/generate-changelog.py`.
  Update the invocation to `GITHUB_TOKEN=$(gh auth token) scripts/generate-changelog.py` and note CalVer branch
  detection now works without `--tag` (keep `--tag` as the fallback note).
- Add a new subsection after "Tagging and publishing" (e.g., **"Backport to dev after release"**): once the `release/* →
  main` PR has merged, the tag published, and the GitHub Release created, run `scripts/sync-dev-after-release.sh
  <version>`; review and merge the resulting `chore(release): sync dev after <version>` PR. Explain the
  surgical-CHANGELOG rationale and link the solutions doc. Replace the standing "`dev` is untouched" claim with "`dev`
  receives the release-only files back via the backport PR."
- Mention that README / `RELEASES.md` release-prep edits, if any, get folded into the same backport PR by hand.

**Patterns to follow:** existing `RELEASES.md` voice and section structure; `feedback_git_tracked_docs_current_truth`
(state present truth, no dated addenda).

**Test scenarios:** none — documentation. `Test expectation: none — prose runbook, no behavioral change.`

**Verification:** `markdownlint-cli2` passes; no remaining `rg "rust-tool-release/scripts/generate-changelog"` hits in
`RELEASES.md`; the backport step reads as an ordered part of the lifecycle.

### U4. One-time drift heal — backport `main`@`2026.06.03` onto dev

**Goal:** Bring `dev`'s `CHANGELOG.md` current with the latest published release, validating U2 end-to-end.

**Requirements:** R5.

**Dependencies:** U1, U2, U3 (and they must be merged to `dev` first, so the scripts exist on `dev`).

**Files:** none created — operational run of `scripts/sync-dev-after-release.sh 2026.06.03`.

**Approach:**

- After U1–U3 merge to `dev`, run `scripts/sync-dev-after-release.sh 2026.06.03`.
- The script opens a `chore(release): sync dev after 2026.06.03` PR whose sole change is `CHANGELOG.md` (dev top moves
  from `## [2026.04.15]` to `## [2026.06.03]`, gaining the 05.02 / 05.11 / 05.16 / 06.03 sections).
- Verify the diff touches only `CHANGELOG.md` (R3 safety), then merge.
- Check whether `README.md` / `RELEASES.md` also drifted from `main`'s release-prep (`git diff origin/dev..origin/main
  -- -- README.md RELEASES.md`); if real release-only polish exists, fold it into the same PR by hand.

**Test scenarios:** none — one-time operational heal. `Test expectation: none — verified by the post-merge state
assertion.`

**Verification:** post-merge, `git show origin/dev:CHANGELOG.md | head -6` shows `## [2026.06.03]` at top; the next
release's triple-diff "B" step no longer lists `CHANGELOG.md` as drift.

---

## Scope Boundaries

**In scope:** the two vendored+adapted scripts, their bats tests, the `RELEASES.md` repair, and the one-time CHANGELOG
heal.

### Deferred to Follow-Up Work

- **Cutting the actual release.** After this lands and dev is healed, cut `release/2026.06.16` per `RELEASES.md`
  (cherry-pick PR squashes since `2026.06.03`, regenerate `CHANGELOG.md` with the new `scripts/generate-changelog.py`,
  PR to main). Operational, runbook-driven — not part of building the pipeline.
- **Full quad docs** (RATIONALE / PREFLIGHT / POSTFLIGHT) and the `scripts/release/` orchestrators — intentionally
  skipped per KTD5; revisit only if this repo grows crates/homebrew/multi-env surfaces.
- **CI guard workflows** (`guard-release-branch`, `guard-main-docs`) — skipped; manual triple-diff stays.

**Out of scope:** changing `release.yml`'s CalVer/tag/publish logic; changing `cliff.toml` parsers; ruleset / required
status-check changes.

---

## Branch & Delivery Discipline

- This plan doc commits directly to `dev` (planning-only exception).
- U1–U3 are code + consumer-facing runbook → land on a single `feat/release-backport-pipeline` branch, PR to `dev`,
  squash-merge. `## Changelog` in the PR body: the new backport script + the runbook repair are operator-facing, so they
  earn `### Added` / `### Fixed` bullets.
- U4 runs only after that PR merges (the scripts must exist on `dev`), and produces its own `chore(release)` PR.

---

## Risks & Mitigations

- **Blanket sync reverts dev (high severity).** A merge or `git checkout origin/main .` would roll back ~132 unreleased
  commits. *Mitigation:* surgical per-file `git checkout origin/main -- <file>` only (KTD1, R3); dirty-tree guard; bats
  test asserting only named files move; U4 verification asserts the diff is `CHANGELOG.md`-only before merge.
- **CalVer `.N` suffix edge case.** Same-day reruns produce `2026.06.16.1`. *Mitigation:* regex allows the optional
  `.N`; explicit test scenarios in U1 and U2.
- **Generator runtime deps.** `generate-changelog.py` needs `GITHUB_TOKEN` + `git-cliff` + network for a full run.
  *Mitigation:* both tools confirmed installed; runbook documents `GITHUB_TOKEN=$(gh auth token)`; the drift check in U2
  is gated on availability and only warns.
- **PR-body hook.** Inline `gh pr create --body "..."` is rejected by the `heredoc-pr-guard` PreToolUse hook.
  *Mitigation:* the script uses `mktemp` + `--body-file` (KTD3); a bats test asserts it.

---

## Verification (end-to-end)

1. `shellcheck scripts/sync-dev-after-release.sh` → clean.
2. `bats tests/generate-changelog.bats tests/sync-dev-after-release.bats` → green.
3. `scripts/generate-changelog.py --check` → exits per the repo CHANGELOG's top section.
4. Merge the `feat/release-backport-pipeline` PR to `dev`.
5. `scripts/sync-dev-after-release.sh 2026.06.03` → opens a dev PR; confirm the diff is `CHANGELOG.md` only; merge.
6. `git show origin/dev:CHANGELOG.md | head` → `## [2026.06.03]` on top.
7. Proceed to cut `release/2026.06.16` per `RELEASES.md` (deferred follow-up).

---

## Sources & Research

- Skill templates: `~/.claude/skills/github-repo-setup/templates/sync-dev-after-release.sh`,
  `.../generate-changelog.py`; skill body "Release workflow (feat → dev → release/* → main)".
- `docs/solutions/workflow-issues/post-release-backport-prevents-diff-b-false-positives-2026-05-07.md` — the documented
  drift pattern and the surgical-backport remedy.
- Repo current state: `RELEASES.md`, `.github/workflows/release.yml`, `cliff.toml`; `dev`@`CHANGELOG.md` top
  `2026.04.15` vs `main`@`2026.06.03`; `dev` ~132 commits ahead of `main`.
