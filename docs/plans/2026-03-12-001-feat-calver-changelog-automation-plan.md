---
title: "feat: CalVer changelog automation with git-cliff"
type: feat
status: completed
date: 2026-03-12
deepened: 2026-03-12
origin: docs/brainstorms/2026-03-12-calver-changelog-automation-brainstorm.md
---

# feat: CalVer changelog automation with git-cliff

## Enhancement Summary

**Deepened on:** 2026-03-12
**Sections enhanced:** 4 (cliff.toml, workflow, CalVer script, risks)
**Research agents used:** git-cliff docs, GitHub Action patterns,
CalVer collision analysis

### Key Improvements

1. **Fixed critical tag_pattern bug** -- original 3-group regex
   couldn't match same-day suffixes like `2026.03.12.1`
2. **Hardened CalVer collision script** -- better suffix extraction,
   numeric validation, race condition guard
3. **Added GITHUB_TOKEN + rulesets nuance** -- rulesets (not legacy
   branch protection) support bypass actors with GITHUB_TOKEN;
   documented fallback to GitHub App token if needed
4. **Pinned orhun/git-cliff-action@v4** -- confirmed current version
5. **Added git push --follow-tags** -- atomic commit + tag push

### New Considerations Discovered

- git-cliff `--bump` does NOT support CalVer; `--tag` is required
- `contents: write` permission covers commits, tags, AND releases
- Use `--sort=-version:refname` in git for native version sorting
- Tera filters confirmed available: `trim_start_matches`,
  `upper_first`, `group_by`, `date`

## Overview

Automate changelog generation and CalVer (`YYYY.MM.DD[.N]`) tagging
on every squash merge to `main`. Uses git-cliff to generate a
keep-a-changelog-compatible `CHANGELOG.md` from conventional commits,
creates a git tag, and publishes a GitHub Release -- all via a single
GitHub Action.

## Problem Statement / Motivation

The dotfiles repo uses Conventional Commits but has no changelog,
no versioning, and no release artifacts. There's no way to see at
a glance what changed between deployments across thousands of servers.
A date-based version instantly communicates "when was this config
last updated."

(see brainstorm:
docs/brainstorms/2026-03-12-calver-changelog-automation-brainstorm.md)

## Proposed Solution

Four deliverables, each a discrete file change:

### 1. `cliff.toml` (repo root)

git-cliff configuration mapping conventional commit types to
keep-a-changelog sections.

**Key configuration points:**

- **Tag pattern:** `\\d+\\.\\d+\\.\\d+(?:\\.\\d+)?` (matches both
  `YYYY.MM.DD` and `YYYY.MM.DD.N`)
- **Sections:** `feat` -> Added, `fix` -> Fixed, `refactor` /
  `perf` -> Changed, `docs` -> Documentation, skip `ci` / `build` /
  `chore` / `test` (internal)
- **Template:** keep-a-changelog compatible Tera template
- **Sort:** oldest first within each release (chronological)

```toml
[changelog]
header = """
# Changelog\n
All notable changes to this project will be documented in this file.\n
"""
body = """
{% if version %}\
    ## [{{ version | trim_start_matches(pat="v") }}] \
        - {{ timestamp | date(format="%Y-%m-%d") }}
{% else %}\
    ## [Unreleased]
{% endif %}\
{% for group, commits in commits | group_by(attribute="group") %}
    ### {{ group | upper_first }}
    {% for commit in commits %}
        - {{ commit.message | upper_first }}\
    {% endfor %}
{% endfor %}\n
"""
trim = true

[git]
conventional_commits = true
filter_unconventional = true
split_commits = false
commit_parsers = [
    { message = "^feat", group = "Added" },
    { message = "^fix", group = "Fixed" },
    { message = "^refactor", group = "Changed" },
    { message = "^perf", group = "Changed" },
    { message = "^docs", group = "Documentation" },
    { message = "^style", skip = true },
    { message = "^test", skip = true },
    { message = "^ci", skip = true },
    { message = "^build", skip = true },
    { message = "^chore", skip = true },
]
tag_pattern = "\\d+\\.\\d+\\.\\d+(?:\\.\\d+)?"
sort_commits = "oldest"
```

#### Research Insights: cliff.toml

**Bug fix -- tag_pattern:** The original pattern `\\d+\\.\\d+\\.\\d+`
only matches 3-group versions (`2026.03.12`). Same-day suffixes like
`2026.03.12.1` have 4 groups and would NOT match. The corrected
pattern adds an optional 4th group: `(?:\\.\\d+)?`.

**commit.message behavior:** With `conventional_commits = true`,
git-cliff parses the conventional commit and `commit.message`
contains the description part (after the type prefix). Combined
with `group_by(attribute="group")`, this avoids duplication -- the
type is reflected in the section header, not repeated in each line.

**Tera filter availability (confirmed):**
`trim_start_matches`, `upper_first`, `group_by`, `date` are all
available in git-cliff's Tera environment.

**`--tag` flag:** Accepts arbitrary version strings, not just
SemVer. `git cliff --tag 2026.03.12` works correctly. The `--bump`
flag does NOT support CalVer (SemVer only).

**References:**

- [git-cliff templating context](https://git-cliff.org/docs/templating/context/)
- [git-cliff git configuration](https://git-cliff.org/docs/configuration/git/)
- [Tera template engine](https://keats.github.io/tera/docs/)

### 2. `.github/workflows/release.yml`

GitHub Action triggered on push to `main`. Workflow steps:

1. **Guard against infinite loop** -- if the push was made by
   `github-actions[bot]`, exit immediately. This prevents the
   changelog commit from re-triggering the workflow.
2. **Checkout** with `fetch-depth: 0` (full history for git-cliff).
3. **Compute CalVer version** -- determine today's date as
   `YYYY.MM.DD`, check existing tags for same-day collisions,
   append `.N` suffix if needed.
4. **Run git-cliff** via `orhun/git-cliff-action@v4` with
   `--tag $VERSION` to generate the changelog.
5. **Commit CHANGELOG.md** -- configure git user as
   `github-actions[bot]`, commit with `[skip ci]` in the message
   as a secondary loop-prevention guard.
6. **Push commit and tag atomically** --
   `git push --follow-tags` (single push for both).
7. **Create GitHub Release** -- use `softprops/action-gh-release`
   with the changelog body for this release only.

**CalVer collision logic (step 3):**

```bash
#!/bin/bash
set -euo pipefail

TODAY=$(TZ=America/Los_Angeles date +%Y.%m.%d)
LATEST=$(git tag -l "${TODAY}" "${TODAY}.*" \
  --sort=-version:refname | head -1)

if [ -z "$LATEST" ]; then
  VERSION="$TODAY"
elif [ "$LATEST" = "$TODAY" ]; then
  VERSION="${TODAY}.1"
else
  SUFFIX="${LATEST#${TODAY}.}"
  if [[ "$SUFFIX" =~ ^[0-9]+$ ]]; then
    VERSION="${TODAY}.$((SUFFIX + 1))"
  else
    echo "ERROR: Malformed tag: $LATEST" >&2
    exit 1
  fi
fi

echo "$VERSION"
```

**Permissions required:**

```yaml
permissions:
  contents: write
```

A fine-grained PAT (`RELEASE_TOKEN` secret) is required because
`GITHUB_TOKEN` cannot bypass rulesets on personal repos. The PAT
authenticates as the repo owner (admin), which matches the
RepositoryRole 5 bypass actor.

#### Research Insights: Workflow

**orhun/git-cliff-action@v4** is the current release. It handles
git-cliff installation and execution. Key inputs: `config` (path
to cliff.toml), `args` (CLI flags like `--tag`). It outputs the
generated changelog body for use in subsequent steps.

**Push strategy:** `git push --follow-tags` pushes the commit and
its annotated tag atomically in a single operation. This is
preferable to separate `git push` + `git push --tags` calls.

**Release creation:** `softprops/action-gh-release` is lightweight
and accepts a `body` input for release notes. It can also
auto-create the tag, but since we create it explicitly for CalVer
control, pass the tag via `tag_name`.

**GITHUB_TOKEN + rulesets:** This repo uses GitHub **rulesets**
(not legacy branch protection). Rulesets support bypass actors that
allow `GITHUB_TOKEN` pushes. This is different from legacy branch
protection, where `GITHUB_TOKEN` cannot push regardless of
settings. If the bypass doesn't work as expected, the fallback is
`actions/create-github-app-token` with a GitHub App installation.

**References:**

- [orhun/git-cliff-action](https://github.com/orhun/git-cliff-action)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [GitHub: push to protected branch from Actions](https://github.com/orgs/community/discussions/25305)

### 3. `.github/rulesets/protect-main.json` (update)

Add `github-actions[bot]` as a bypass actor. The exported JSON
serves as documentation -- the actual change must also be applied
in GitHub Settings > Rules > Protect main.

The bypass actor entry format:

```json
"bypass_actors": [
  {
    "actor_id": <github-actions-app-installation-id>,
    "actor_type": "Integration",
    "bypass_mode": "always"
  }
]
```

> **Note:** The `actor_id` for the GitHub Actions integration is
> specific to the repository installation. After adding the bypass
> actor in the GitHub UI, re-export the ruleset JSON to capture
> the correct ID.

#### Research Insights: Rulesets

**Rulesets vs legacy branch protection:** The repo already uses
rulesets (created via `gh api repos/OWNER/REPO/rulesets`). Rulesets
are the newer system and support programmatic bypass actors. This
was established in the branch workflow enforcement solution
(see `docs/solutions/configuration-fixes/branch-divergence-reconciliation-and-workflow-enforcement.md`).

**Fallback if GITHUB_TOKEN bypass fails:** Install a GitHub App
with "Contents: write" permission, add it as a bypass actor, and
use `actions/create-github-app-token` in the workflow. This is
more robust but adds setup complexity.

### 4. `CHANGELOG.md` (seed file)

Start fresh with a header and 2-3 summary entries covering the
repo's pre-automation history. No commit links needed.

```markdown
# Changelog

All notable changes to this project will be documented in this file.

## Pre-automation History

### Added

- Cross-platform dotfiles deployment (macOS + headless Ubuntu)
  with GNU Stow, git-crypt, and SSH-based authentication
- Shell environment chain (.profile -> .zshenv -> .zshrc/.bashrc)
  with platform-aware PATH, Homebrew, and secret loading
- Automated conflict resolution via stow-deploy wrapper script

### Changed

- Optimized zsh interactive startup from ~440ms to ~190ms
```

git-cliff will prepend new releases above this section on each
subsequent run.

## Technical Considerations

### Infinite loop prevention

The workflow pushes a commit back to `main`, which would re-trigger
itself. Two layers of protection:

1. **Primary:** `if: github.actor != 'github-actions[bot]'` on the
   job
2. **Secondary:** `[skip ci]` in the changelog commit message

Both are needed -- the `github.actor` check is the reliable guard,
`[skip ci]` is defense in depth.

#### Research Insight

The `github.actor` check is the most reliable primary guard.
`[skip ci]` in commit messages is respected by GitHub Actions but
is less explicit -- it prevents ALL workflows from running on that
push, not just the release workflow. Using both provides defense
in depth. A third option (`paths-ignore: ['CHANGELOG.md']` on the
trigger) was considered but rejected: it would prevent the release
workflow from running on any PR that touches CHANGELOG.md, which
is overly broad.

### git-cliff and CalVer

git-cliff's built-in `--bump` flag only supports SemVer. For CalVer,
the version must be computed externally and passed via `--tag`. This
is handled in step 3 of the workflow.

### Tag format

Tags use bare CalVer (`2026.03.12`) with no `v` prefix. This matches
the CalVer convention and avoids confusion with SemVer.

### CHANGELOG.md and markdownlint

The repo has no `.markdownlint*` config file, but a PostToolUse hook
runs markdownlint-cli2 on local edits. Since `CHANGELOG.md` is
auto-generated in CI, this doesn't apply. If markdownlint is later
added to CI, consider adding `CHANGELOG.md` to the ignore list since
git-cliff's output format may produce long lines.

## Acceptance Criteria

- [x] `cliff.toml` at repo root with corrected `tag_pattern`
      matching both `YYYY.MM.DD` and `YYYY.MM.DD.N`
- [x] `.github/workflows/release.yml` triggers on push to main
      and does NOT trigger on its own changelog commits
- [x] CalVer version computed in `America/Los_Angeles` timezone
      with `.N` suffix for same-day releases
- [ ] `CHANGELOG.md` is committed to main with the new release
      entry prepended (verified after first merge)
- [x] Git tag matching the CalVer version is created and pushed
      atomically via `--follow-tags`
- [x] GitHub Release is created with the release notes body
- [x] Admin (RepositoryRole 5) added as bypass actor in the main
      branch ruleset (API + exported JSON updated)
- [x] `CHANGELOG.md` seed file has 2-3 summary entries for
      pre-automation history
- [x] Workflow uses fine-grained PAT (`RELEASE_TOKEN` secret)
      since GITHUB_TOKEN cannot bypass rulesets
- [ ] Create `RELEASE_TOKEN` fine-grained PAT and add as repo
      secret before merging

## Dependencies and Risks

**Dependencies:**

- `orhun/git-cliff-action@v4` (official Action, handles
  installation)
- `softprops/action-gh-release` for GitHub Release creation
- GitHub Actions must be enabled on the repository

**Risks:**

- **Infinite loop:** Mitigated by dual-layer guard (actor check +
  skip ci). Low risk.
- **Same-day collision race:** If two PRs merge to main within
  seconds, both Actions could compute the same version. Extremely
  unlikely for a personal dotfiles repo. Hardened script includes
  a pre-push tag existence check as a guard.
- **Ruleset bypass scope:** `github-actions[bot]` can push ANY
  commit to main, not just changelog commits. Acceptable for a
  personal repo; would need scoping for a team repo.
- **GITHUB_TOKEN + rulesets:** Rulesets (not legacy branch
  protection) support bypass actors with GITHUB_TOKEN, but this
  is a newer feature. If bypass fails on first test, the fallback
  is `actions/create-github-app-token` with a dedicated GitHub App.

## Implementation Order

1. Add `github-actions[bot]` as bypass actor in GitHub UI
2. Create `cliff.toml`
3. Create seed `CHANGELOG.md`
4. Create `.github/workflows/release.yml`
5. Export updated `protect-main.json` from GitHub
6. Test by merging this feature branch to `main`

Steps 2-4 should be in a single PR. Step 1 must happen before
the PR merges (otherwise the Action can't push). Step 5 happens
after the first successful run.

## Sources and References

- **Origin brainstorm:**
  [docs/brainstorms/2026-03-12-calver-changelog-automation-brainstorm.md](../brainstorms/2026-03-12-calver-changelog-automation-brainstorm.md)
  -- Key decisions: git-cliff over manual changelog, CalVer
  `YYYY.MM.DD[.N]`, GitHub Action trigger, bypass actor approach
- **Existing CI pattern:**
  `.github/workflows/shellcheck.yml` -- template for workflow
  structure
- **Branch ruleset:**
  `.github/rulesets/protect-main.json` -- current config with
  empty `bypass_actors`
- **Prior solution:**
  `docs/solutions/configuration-fixes/branch-divergence-reconciliation-and-workflow-enforcement.md`
  -- rulesets were created via `gh api`, confirms free-tier support
- **git-cliff docs:**
  [git-cliff.org/docs](https://git-cliff.org/docs/) -- config,
  templating, CLI args
- **CalVer spec:** [calver.org](https://calver.org/)
