# Releasing `dotfiles`

Every change reaches `main` via this pipeline. Direct commits to `development` or `main` are not permitted — every
change has a PR number in its squash commit message, which keeps the history scannable, attributable, and
changelog-ready.

```text
feature branch → PR to development (squash merge)
              → release/YYYY.MM.DD branch (merge development in)
              → PR to main (squash merge)
              → push to main triggers CI: compute CalVer → tag → GitHub Release
```

## Branches

| Branch        | Role                              | Lifetime                       | Protection                                    |
| ------------- | --------------------------------- | ------------------------------ | --------------------------------------------- |
| `main`        | Production. Only release commits. | Forever.                       | `.github/rulesets/protect-main.json`          |
| `development` | Integration. All feature PRs land here. | Forever. Never delete.   | `.github/rulesets/protect-development.json`   |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Feature work. | One PR's worth. Delete after merge. | None — squash into development freely. |
| `release/*`   | Head of a development → main PR.  | One release's worth. Delete after merge. | None.                               |

`development` is a **forever branch**. Never delete it locally or remotely, even after a `release/* → main` merge. The
next release cycle reuses the same `development`. Using a short-lived `release/*` head is what lets `development` stay
around forever while still going through a PR into `main`.

## Daily development (feature → development)

```bash
git checkout development && git pull
git checkout -b feat/short-description
# ... work ...
git push -u origin feat/short-description
gh pr create --base development --title "feat(scope): what changed"
# Reviews pass → squash-merge (PR body becomes the development commit message)
```

- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/). See
  `~/.claude/templates/commit-message.md` for the full spec.
- **PR body**: follow `.github/pull_request_template.md`. The `## Changelog` section is the source of truth for
  user-facing release notes — `git-cliff` extracts these bullets verbatim into `CHANGELOG.md` during release prep.
- **Signing**: `development` requires signed commits per `protect-development.json`. The `pre-commit` hook verifies
  `commit.gpgsign = true` locally before push.

## Releasing development to main

Dotfiles uses CalVer — versions are `YYYY.MM.DD` (plus a `.N` suffix for same-day reruns). CI computes the version and
creates the tag on push to `main`, so local tagging is never needed. The release branch exists to carry a committed
`CHANGELOG.md` through the PR.

**Branch naming**: `release/YYYY.MM.DD`. The date is informational only — CI recomputes the version at push time from
today's date and any existing same-day tags.

```bash
# 1. Branch from main, NOT development. Branching from development causes add/add
#    conflicts whenever development and main have divergent histories (the
#    post-squash-merge norm).
git fetch origin
git checkout -b "release/$(date +%Y.%m.%d)" origin/main

# 2. Cherry-pick PR squash commits from development onto the release branch.
#    Each pick creates a new commit carrying the PR's conventional-commit
#    subject — exactly what git-cliff needs to categorize entries. Unlike
#    `git merge origin/development`, this does NOT drag in orphan SHAs from
#    prior releases, so the generated changelog covers only the true delta.
#    Direct commits on development are intentionally excluded; per the
#    branches table, direct commits to development are not permitted, and
#    any fix must come in via its own PR.
LAST_TAG=$(git describe --tags --abbrev=0 origin/main)
git log --first-parent --grep='(#[0-9]\+)$' --format='%H %s' \
  "$LAST_TAG..origin/development"
# Review the list, then cherry-pick in chronological order (oldest first):
git cherry-pick <oldest-sha> <next-sha> ... <newest-sha>

# 3. Generate CHANGELOG.md. Pass --tag explicitly: the script's branch detection
#    expects `release/vN.N.N` (SemVer) and does not parse CalVer branch names.
GITHUB_TOKEN=$(gh auth token) \
  ~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh --tag "$(date +%Y.%m.%d)"

# 4. Review CHANGELOG.md. The script runs git-cliff for base entries, then
#    expands squash commits by pulling `## Changelog` sections from each PR body
#    via the GitHub API.

# 5. Commit and push:
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG.md"
git push -u origin "release/$(date +%Y.%m.%d)"

# 6. Open the PR:
gh pr create --base main --title "release: $(date +%Y.%m.%d)" \
             --body "Release $(date +%Y.%m.%d)"
```

When the PR merges (squash-only, enforced by `protect-main.json`), the push to `main` triggers `release.yml`. The
release branch can be deleted from the GitHub UI after merge; `development` is untouched.

### Why branch from main and cherry-pick, not merge development

Two compounding problems made the earlier "branch from main, merge development" flow break on every release:

1. **`add/add` conflicts.** Branching from `development` produces `add/add` merge conflicts whenever `development` and
   `main` have diverged (which they always do after the first squash merge). The same file appears "added" on both sides
   with different content.
2. **Orphan history leaking into the changelog.** `git merge origin/development` pulls in every ancestor SHA on dev —
   including individual commits that were collapsed into prior release squashes on `main`. Those SHAs aren't reachable
   from the last tag, so `git-cliff --unreleased` re-emits them in every new release's changelog.

Cherry-picking solves both: branching from `origin/main` avoids the conflicts, and picking only PR squash commits
creates fresh SHAs on the release branch that represent exactly the delta being shipped — no prior-release noise.

## Tagging and publishing

The tag is **not** created locally. `release.yml` triggers on any push to `main` and runs:

| Step | What |
|------|------|
| `Compute CalVer version` | `YYYY.MM.DD` in America/Los_Angeles. If tags for today already exist, append `.N` (e.g. `2026.04.15.1`). |
| `Extract release notes` | Read the topmost `## [version]` section from the committed `CHANGELOG.md`. Falls back to `"Release <version>"` if empty. |
| `Tag and push` | `git tag <version> && git push origin <version>`. Bare (non-annotated) because the workflow runs as `github-actions[bot]` without a signing key configured. |
| `Create GitHub Release` | `softprops/action-gh-release` publishes a release with the extracted notes as the body. |

No crates, no cross-compiled binaries, no Homebrew dispatch — this repo is config-only.

### Emergency docs fix to main

Any push to `main` triggers a release. If you must push a docs-only commit directly to `main` (e.g. rewording a README),
include `[skip ci]` in the commit message to suppress the release workflow. Prefer the standard release-branch flow
whenever possible.

## PRs and changelog generation

Every PR **must** follow `.github/pull_request_template.md`. The template has a `## Changelog` section that is the
single source of truth for user-facing release notes.

`generate-changelog.sh` (which wraps `git-cliff` per `cliff.toml`) reads:

1. The individual conventional-commit messages on the release branch (merged from `development`), categorized per
   `cliff.toml`'s `commit_parsers` (`feat` → Added, `fix` → Fixed, `refactor`/`perf` → Changed, `docs` → Documentation,
   everything else skipped).
2. The `## Changelog` section of each squash-merged PR body, pulled via the GitHub API and used to expand bullets past
   the single-line commit summary.

A PR that lands with an empty or missing `## Changelog` section silently drops its user-facing notes from the next
release. **Never manually edit `CHANGELOG.md`** — it is a generated artifact. Fix the inputs (commit messages, PR
bodies, `cliff.toml`), not the output.

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- `protect-main.json` — required signatures, linear history, squash-only merges via PR, creation/deletion blocked,
  non-fast-forward blocked. No required status checks (shellcheck is advisory; `release.yml` runs post-merge).
- `protect-development.json` — required signatures, deletion blocked, non-fast-forward blocked. No PR requirement at the
  ruleset level; the PR-only norm is enforced by convention.

### Applying changes

Edit the JSON locally, then sync to the remote:

```bash
# First apply (creating a ruleset):
gh api -X POST repos/brettdavies/dotfiles/rulesets --input .github/rulesets/protect-development.json

# Subsequent updates (replace by ID — find via `gh api repos/brettdavies/dotfiles/rulesets`):
gh api -X PUT repos/brettdavies/dotfiles/rulesets/<id> --input .github/rulesets/protect-main.json
```

Committing the JSON alongside config means ruleset changes land via the same review process as workflow changes — a
`chore(ci): tighten protect-main` change goes through development → release/* → main like anything else.

## Required secrets

| Secret | Purpose | Lifecycle |
|--------|---------|-----------|
| `CI_RELEASE_TOKEN` | Fine-grained PAT, Contents R+W. Used by `release.yml` to push the tag and create the GitHub Release. The default `GITHUB_TOKEN` cannot push to `main` because `protect-main.json` blocks non-PR writes. | Rotated annually. |

## Troubleshooting

**`generate-changelog.sh` errors with "could not detect version":** Always pass `--tag YYYY.MM.DD` explicitly. The
script's branch detection expects `release/vN.N.N` (SemVer) and does not parse CalVer branch names.

**Empty changelog sections:** Ensure `cliff.toml` has `[remote.github]` with `owner` and `repo` for PR body expansion,
and that `GITHUB_TOKEN` is exported (the command above falls back to `gh auth token`).

**Push to `release/*` rejected for unsigned commits:** Release branches aren't listed in `protect-development.json`'s
ref pattern, but `gitconfig` sets `commit.gpgsign = true` globally and `.githooks/pre-commit` enforces it. Ensure your
SSH signing key is configured (1Password on macOS, ssh-keygen on headless Linux — see
`docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`).

**Same-day re-release:** If today already has a `YYYY.MM.DD` tag, CI auto-bumps to `YYYY.MM.DD.1`, `YYYY.MM.DD.2`, etc.
No local action required — just merge another `release/*` PR.

**Duplicate release avoidance:** The release workflow triggers on every push to `main`. To push a non-release commit
(emergency docs fix, README typo) without creating a release, include `[skip ci]` in the commit message.

## Related docs

- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure with changelog sections
- [`CLAUDE.md`](CLAUDE.md) — project conventions, stow packages, shell config chain
- [`README.md`](README.md) — bootstrap, stow deploy, cross-platform notes
- [`cliff.toml`](cliff.toml) — git-cliff configuration: commit parsers, tag pattern, remote metadata
