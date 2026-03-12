# Brainstorm: CalVer Changelog Automation

**Date:** 2026-03-12
**Status:** Complete

## What We're Building

An automated changelog and versioning system for the dotfiles repo that:

- Generates a `CHANGELOG.md` from conventional commit messages using **git-cliff**
- Uses **CalVer** versioning: `YYYY.MM.DD` (with `.N` suffix for same-day releases)
- Triggers automatically via **GitHub Action** on every squash merge to `main`
- Creates a **GitHub Release** with release notes extracted from the changelog
- Commits the updated `CHANGELOG.md` and git tag back to `main`

## Why This Approach

**git-cliff over manual keep-a-changelog:** The repo already uses
Conventional Commits for all commit messages. git-cliff reads these
natively and outputs keep-a-changelog-compatible format, giving us
automation for free. Manual curation would add friction to every
release with no real benefit for a dotfiles repo.

**CalVer over SemVer:** Dotfiles don't have a public API, so
major/minor/patch semantics don't apply. Date-based versions
(`YYYY.MM.DD`) are immediately meaningful -- you know when a config
was last updated. The `.N` suffix handles the rare case of multiple
same-day releases.

**GitHub Action over git hooks:** The automation must be centralized
and reliable. A local post-merge hook would only run on the machine
performing the merge and wouldn't create GitHub Releases. A GitHub
Action runs consistently regardless of who or what triggers the merge.

**Bypass actor for branch protection:** Adding `github-actions[bot]`
as a bypass actor in the main ruleset is the simplest way to let the
Action commit the changelog and tag. The alternative (auto-PRs or
release-only) adds complexity for minimal security benefit in a
personal dotfiles repo.

## Key Decisions

| Decision | Choice | Alternatives Rejected |
|----------|--------|-----------------------|
| Changelog tool | git-cliff | Manual keep-a-changelog (too much friction), conventional-changelog (Node.js, heavier) |
| Versioning scheme | CalVer `YYYY.MM.DD[.N]` | SemVer (no public API), plain `YYYYMMDD` (less readable) |
| Automation trigger | GitHub Action on push to main | Git hook (local-only), manual script (defeats the purpose) |
| Release artifacts | CHANGELOG.md + git tag + GitHub Release | Tag-only (no readable changelog), release-only (no in-repo record) |
| Branch protection | Bypass actor for github-actions[bot] | Auto-PR (complex), no commit (loses in-repo changelog) |
| History seeding | Start fresh with 1-3 summary entries | Full history (noisy, pre-convention commits) |

## Components

1. **`cliff.toml`** -- git-cliff configuration at repo root. Maps
   conventional commit types to changelog sections (Added, Changed,
   Fixed, etc.). Configures CalVer tag pattern.

2. **`.github/workflows/release.yml`** -- GitHub Action triggered on
   push to main. Runs git-cliff, determines next CalVer version,
   commits CHANGELOG.md, creates tag, creates GitHub Release.

3. **`.github/rulesets/protect-main.json`** -- Updated to add
   `github-actions[bot]` as a bypass actor so the Action can push
   to main.

4. **`CHANGELOG.md`** -- Seed file with 1-3 summary entries for the repo's pre-automation history.

## Open Questions

None -- all key decisions resolved through brainstorming dialogue.
