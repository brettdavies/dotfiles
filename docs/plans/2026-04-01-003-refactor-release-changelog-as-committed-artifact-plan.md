---
title: "refactor: Adopt changelog-as-committed-artifact release process"
type: refactor
status: active
date: 2026-04-01
---

# refactor: Adopt changelog-as-committed-artifact release process

## Overview

Replace the CI-generated changelog with a locally committed artifact, following the proven pattern from bird and
xurl-rs. git-cliff runs locally on a release branch (where individual commits are visible), CHANGELOG.md is committed to
the PR, and the release workflow simply extracts the latest section from the committed file.

## Problem Frame

The current release workflow runs `git-cliff` in CI on every push to `main`. With squash-only merging enforced, each
release PR becomes a single commit. git-cliff only sees the squash commit title — the individual `feat:`, `fix:`,
`refactor:` messages from development are invisible on main after squash. This produced an empty changelog for release
2026.04.01.

The bird and xurl-rs repos solved this exact problem (see
`docs/solutions/architecture-patterns/changelog-as-committed-artifact-20260319.md`).

## Requirements Trace

- R1. CHANGELOG.md is a committed artifact, not CI-generated
- R2. git-cliff runs locally on a release branch where individual commits are visible
- R3. The release workflow extracts changelog notes from the committed CHANGELOG.md (no git-cliff in CI)
- R4. CalVer versioning is preserved (YYYY.MM.DD format, not SemVer)
- R5. The release branch procedure is documented in a RELEASING.md file
- R6. cliff.toml includes `[remote.github]` for PR links and author attribution
- R7. Existing changelog history is preserved (--unreleased --prepend leaves prior entries untouched)

## Scope Boundaries

- No provenance guard workflow (dotfiles doesn't need it — direct commits to dev are fine for a personal config repo)
- No docs guard workflow (docs/ is a symlink to shared repo, not tracked on main)
- No `generate-changelog.sh` adaptation — use the existing script from `~/.claude/skills/rust-tool-release/scripts/`
  with `--tag` override for CalVer tags
- No changes to branch protection rulesets
- No changes to the squash-merge-only policy on main

## Context & Research

### Relevant Code and Patterns

- **Current release workflow:** `.github/workflows/release.yml` — triggers on push to main, runs git-cliff action,
  commits changelog, tags, creates release
- **Current cliff.toml:** `cliff.toml` — standard conventional commits config, missing `[remote.github]` section
- **Bird release workflow:** thin caller that triggers on tag push, extracts notes from committed CHANGELOG.md via awk
- **Bird cliff.toml:** includes `[remote.github]`, `footer` for pre-conventional releases, `ignore_tags`
- **generate-changelog.sh:** `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh` — two-stage: git-cliff
  for base entries, then PR body expansion via GitHub API

### Institutional Learnings

- `docs/solutions/architecture-patterns/changelog-as-committed-artifact-20260319.md` — canonical pattern reference
- `docs/solutions/workflow-issues/deterministic-release-workflow-pr-provenance-generated-changelogs-20260325.md` — full
  release pipeline with PR body expansion

## Key Technical Decisions

- **CalVer tag pattern in cliff.toml:** Use `tag_pattern = "\\d{4}\\.\\d{2}\\.\\d{2}.*"` to match CalVer tags
  (`2026.04.01`, `2026.04.01.1`). Bird uses `tag_pattern = "v[0-9].*"` for SemVer — dotfiles needs a different pattern.
- **No `v` prefix on tags:** CalVer tags are `2026.04.01`, not `v2026.04.01`. The cliff.toml template, release workflow,
  and generate-changelog.sh `--tag` all need to handle this.
- **Release branch naming:** `release/YYYY.MM.DD` (matching CalVer, no `v` prefix). The generate-changelog.sh script
  auto-detects version from `release/vN.N.N` branch pattern — CalVer won't match, so always pass `--tag` explicitly.
- **Release trigger: push to main, not tag push.** Bird triggers on tag push because tagging happens after merge. For
  dotfiles, keep the existing trigger (push to main) since the workflow computes CalVer from the date and creates the
  tag itself. This avoids an extra manual tagging step that adds friction for a config repo.
- **Keep CalVer computation in CI:** The release workflow already computes `YYYY.MM.DD` with same-day suffix handling.
  This stays — it's the right approach for a config repo where versions are dates, not semantic milestones.
- **No footer/ignore_tags needed:** generate-changelog.sh uses `--unreleased --prepend` which only adds new content.
  Existing CHANGELOG.md entries are preserved untouched. Footer/ignore_tags would remove git-cliff's tag range boundary,
  causing it to scan full history. Simpler and more correct to skip them.
- **Use generate-changelog.sh with --tag override:** Rather than adapting the script for CalVer branch detection, pass
  `--tag YYYY.MM.DD` explicitly. This is simpler and avoids modifying a shared script.

## Open Questions

### Resolved During Planning

- **Should we change the release trigger from push-to-main to tag-push?** No. Keep push-to-main because the CalVer
  version is computed from the date in CI. Tag-push would require a manual `git tag` + `git push --tags` step after
  merge, adding friction. The workflow creates the tag automatically.
- **Should we adapt generate-changelog.sh for CalVer?** No. Use `--tag` override. The script is shared across repos and
  modifying it for one repo's versioning scheme is the wrong approach.
- **What about the existing 2026.04.01 release with empty body?** The release body was already manually patched. The tag
  and CHANGELOG.md entries on main will be overwritten by the next release anyway — git-cliff regenerates the full file.

### Deferred to Implementation

- None — all planning questions resolved.

## Implementation Units

- [ ] **Unit 1: Update cliff.toml for CalVer and committed-artifact pattern**

**Goal:** Configure cliff.toml with CalVer tag pattern, remote.github section, and changelog skip rule.

**Requirements:** R6, R7

**Dependencies:** None

**Files:**

- Modify: `cliff.toml`

**Approach:**

- Add `[remote.github]` section with `owner = "brettdavies"` and `repo = "dotfiles"`
- Change `tag_pattern` from `"\\d+\\.\\d+\\.\\d+(?:\\.\\d+)?"` to `"\\d{4}\\.\\d{2}\\.\\d{2}.*"` for CalVer
- Add `{ message = "^docs: update CHANGELOG", skip = true }` to commit_parsers (matches bird pattern — prevents
  changelog commit from appearing in its own changelog)
- No footer or ignore_tags needed: generate-changelog.sh uses `--unreleased --prepend` which only adds new content and
  preserves existing CHANGELOG.md entries untouched

**Patterns to follow:**

- `~/dev/bird/cliff.toml` for remote.github structure and commit_parsers

**Test scenarios:**

- Happy path: `git cliff --unreleased --tag 2026.04.02` generates entries from development commits with PR links
- Happy path: existing CHANGELOG.md entries (2026.03.12-2026.04.01) are preserved by --prepend

**Verification:**

- `git cliff --tag 2026.04.02 -o /dev/stdout` produces a changelog with categorized entries and PR links, not empty
  sections

- [ ] **Unit 2: Rewrite release.yml to extract from committed CHANGELOG.md**

**Goal:** Replace git-cliff CI generation with awk extraction from committed CHANGELOG.md. Keep CalVer computation and
tag creation.

**Requirements:** R1, R3, R4

**Dependencies:** Unit 1

**Files:**

- Modify: `.github/workflows/release.yml`

**Approach:**

- Remove the two `orhun/git-cliff-action` steps (generate changelog and get release body)
- Remove the `git add CHANGELOG.md` + `git commit` step (no more bot changelog commits)
- Add a step to extract release notes from committed CHANGELOG.md using the awk pattern: `awk '/^## \[/{if(n++)exit}n'
  CHANGELOG.md`
- Add fallback: if awk extraction returns empty (missing section or empty CHANGELOG.md), use generic message `"Release
  $VERSION"` to prevent a release with blank body
- Keep the CalVer computation step unchanged
- Keep the tag creation step (compute version, create tag, push)
- Keep the GitHub Release creation step, but use the awk-extracted body instead of git-cliff output
- The workflow becomes: checkout → compute version → extract notes from CHANGELOG.md → tag → push tag → create release

**Patterns to follow:**

- `~/dev/dot-github/.github/workflows/rust-release.yml` release job for the awk extraction pattern

**Test scenarios:**

- Happy path: push to main with committed CHANGELOG.md produces a release with correct body
- Edge case: CHANGELOG.md has no matching version section — workflow falls back to generic release message
- Happy path: CalVer tag is created correctly (same-day suffix handling preserved)

**Verification:**

- The workflow YAML has no references to `orhun/git-cliff-action`
- The workflow has no `git commit` step (no more unsigned bot commits)

- [ ] **Unit 3: Create RELEASING.md with CalVer release branch procedure**

**Goal:** Document the complete release procedure adapted for CalVer and the dotfiles repo.

**Requirements:** R5

**Dependencies:** Units 1, 2

**Files:**

- Create: `RELEASING.md`

**Approach:**

- Document the release branch procedure: branch from main, merge development, run generate-changelog.sh with --tag,
  commit CHANGELOG.md, PR to main, squash merge
- Note the CalVer difference: use `--tag YYYY.MM.DD` (no `v` prefix), branch name `release/YYYY.MM.DD`
- Note that tagging happens automatically in CI (unlike bird where it's manual)
- Include the full command sequence
- Reference generate-changelog.sh location

**Patterns to follow:**

- `~/dev/bird/RELEASING.md` and `~/dev/xurl-rs/RELEASING.md` for structure

**Test scenarios:**

- Test expectation: none — documentation-only change

**Verification:**

- RELEASING.md contains complete step-by-step procedure with CalVer-specific commands

- [ ] **Unit 4: Regenerate CHANGELOG.md on a release branch and verify end-to-end**

**Goal:** Create a release branch, run generate-changelog.sh, commit the result, and verify the full pipeline works.

**Requirements:** R1, R2, R4

**Dependencies:** Units 1, 2, 3

**Files:**

- Modify: `CHANGELOG.md`

**Approach:**

- Create `release/2026.04.02` branch from `origin/main`
- Merge development into the release branch (to get all commits visible)
- Run `GITHUB_TOKEN=$(gh auth token) generate-changelog.sh --tag 2026.04.02`
- Review the generated CHANGELOG.md — verify it has categorized entries from individual commits
- Commit CHANGELOG.md
- PR to main, squash merge
- Verify the release workflow creates a release with the correct body

**Patterns to follow:**

- Bird RELEASING.md procedure

**Test scenarios:**

- Happy path: generate-changelog.sh produces changelog with Added/Changed/Fixed/Documentation sections from PR bodies
- Happy path: squash merge to main triggers release workflow that extracts notes correctly
- Edge case: same-day release (2026.04.01 already exists) — CalVer computation produces 2026.04.01.1 or next day tag

**Verification:**

- GitHub Release exists with categorized changelog content (not empty)
- CHANGELOG.md on main contains the new version section
- No unsigned bot commits on main (only the squash merge commit + tag)

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| generate-changelog.sh branch detection won't match CalVer | Always pass `--tag YYYY.MM.DD` explicitly |
| Merging development into release branch brings unsigned bot commits from prior main merges | The release branch is from main; development merge is only to get commits visible for git-cliff. The PR squash merge creates a clean signed commit on main |
| Existing releases (2026.03.12-2026.04.01) duplicated by git-cliff | `--unreleased --prepend` only adds new content, never touches existing sections |

## Sources & References

- Solution doc: `docs/solutions/architecture-patterns/changelog-as-committed-artifact-20260319.md`
- Solution doc:
  `docs/solutions/workflow-issues/deterministic-release-workflow-pr-provenance-generated-changelogs-20260325.md`
- Bird cliff.toml: `~/dev/bird/cliff.toml`
- Bird RELEASING.md: `~/dev/bird/RELEASING.md`
- generate-changelog.sh: `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh`
- Reusable release workflow: `~/dev/dot-github/.github/workflows/rust-release.yml`

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 2 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |

- **UNRESOLVED:** 0
- **VERDICT:** ENG CLEARED — ready to implement
