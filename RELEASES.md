# Releasing `dotfiles`

Operational runbook. Rationale lives in [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md); the pre-cut go/no-go
checklist lives in [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md). Post-tag verification is short for a config-only
repo and is folded into [§ Tagging and publishing](#tagging-and-publishing) below.

Every change reaches `main` via this pipeline. Direct commits to `main` are not permitted; every change carries a PR
number in its squash commit message, which keeps the history scannable, attributable, and changelog-ready.

```text
feature branch → PR to dev (squash merge)
              → release/YYYY.MM.DD branch (cherry-pick PR squashes from dev onto main)
              → PR to main (squash merge)
              → push to main triggers CI: compute CalVer → tag → GitHub Release
```

## Branches

| Branch                                 | Role                                    | Lifetime                                 | Protection                           |
| -------------------------------------- | --------------------------------------- | ---------------------------------------- | ------------------------------------ |
| `main`                                 | Production. Only release commits.       | Forever.                                 | `.github/rulesets/protect-main.json` |
| `dev`                                  | Integration. All feature PRs land here. | Forever. Never delete.                   | `.github/rulesets/protect-dev.json`  |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Feature work.                           | One PR's worth. Delete after merge.      | None — squash into dev freely.       |
| `release/*`                            | Head of a dev → main PR.                | One release's worth. Delete after merge. | None.                                |

`dev` is a **forever branch** — never delete it locally or remotely, even after a `release/* → main` merge. Using a
short-lived `release/*` head is what lets `dev` stay around forever while still going through a PR into `main`.

→ Rationale: [`RELEASES-RATIONALE.md` § Branching model](./RELEASES-RATIONALE.md#branching-model).

## Daily development (feature → dev)

```bash
git checkout dev && git pull
git checkout -b feat/short-description
# ... work ...
git push -u origin feat/short-description
gh pr create --base dev --title "feat(scope): what changed"
# Checks pass → squash-merge (PR body becomes the dev commit message)
```

- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/). See
  `~/.claude/templates/commit-message.md` for the full spec.
- **PR body**: follow `.github/pull_request_template.md`. The `## Changelog` section is the source of truth for
  user-facing release notes — `git-cliff` extracts these bullets verbatim into `CHANGELOG.md` during release prep.
- **Signing**: `dev` requires signed commits per `protect-dev.json`. The `pre-commit` hook verifies `commit.gpgsign =
  true` locally before push.

### Dev-direct exception

Planning-only docs that live on `dev` and never ship to `main` can be committed directly to `dev` without a feature
branch or PR: `docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`, `docs/reviews/`,
`docs/solutions/`, and anything under `.context/`. The standard feature → PR → squash-merge flow stays required for
everything else, including consumer-facing markdown (README, AGENTS, CONTRIBUTING, CHANGELOG, in-repo runbooks such as
this file).

→ Rationale: [`RELEASES-RATIONALE.md` § Branching model](./RELEASES-RATIONALE.md#branching-model).

## PR body

Every PR (feature, fix, docs, release) uses `.github/pull_request_template.md` verbatim.

- **No explainer prose anywhere in the body.** User-facing substance only — what is changing for the consumer that was
  not already there. Do NOT recap the workflow (cherry-pick / regenerate / pre-push gate / CI behavior is documented in
  this file and `.github/`).
- **Summary describes the net diff only** — what merged `main` looks like vs the base branch. Not commit history,
  intermediate state, or cherry-pick mechanics.
- **Zero verification artifacts in the body.** No triple-diff stats, leak-check output, patch-id cherry-check counts,
  pre-push gate results, CI status, or prose-scrub findings. Anomalies get fixed before push, not audit-trailed.
- **Changelog** subsections (`### Added` / `### Changed` / `### Fixed` / `### Documentation`): 1-5 bullets each, delete
  empty subsections, each bullet starts with a verb.
- **Related Issues/Stories** (`Story:` / `Issue:` / `Architecture:` / `Related PRs:`) and **Files Modified** (`Modified`
  / `Created` / `Renamed` / `Deleted`): every sub-label required even when empty — write `- None.` or `n/a`.
- **One logical line per paragraph or bullet; no hard wraps.** GitHub soft-wraps for display.
- **No AI attribution** in commits or PR bodies.

→ Rationale: [`RELEASES-RATIONALE.md` § PR body conventions](./RELEASES-RATIONALE.md#pr-body-conventions).

## Releasing dev to main

Before cutting a release branch, walk [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md) end-to-end. Any unchecked item
holds the release.

Dotfiles uses CalVer — versions are `YYYY.MM.DD` (plus a `.N` suffix for same-day reruns). CI computes the version and
creates the tag on push to `main`, so local tagging is never needed. The release branch exists to carry a committed
`CHANGELOG.md` through the PR.

**Branch naming**: `release/YYYY.MM.DD`. The date is informational only — CI recomputes the version at push time from
today's date and any existing same-day tags.

```bash
# 1. Branch from main, NOT dev. Branching from dev causes add/add conflicts
#    whenever dev and main have divergent histories (the post-squash-merge norm).
git fetch origin
git checkout -b "release/$(date +%Y.%m.%d)" origin/main

# 2. List the PR squash commits on dev since the last tag.
LAST_TAG=$(git describe --tags --abbrev=0 origin/main)
git log --first-parent --grep='(#[0-9]\+)$' --format='%H %s' "$LAST_TAG..origin/dev"

# 3. Cherry-pick in chronological order (oldest first). Each pick carries the
#    PR's conventional-commit subject — exactly what git-cliff categorizes on.
#    Direct (non-PR) commits on dev are intentionally excluded.
git cherry-pick <oldest-sha> <next-sha> ... <newest-sha>

# 4. Triple-diff verification.
git diff origin/main..HEAD --stat                                              # A: ship surface
git diff HEAD..origin/dev --name-only | grep -v '^docs/' || echo "(none)"      # B: no missed picks
git diff origin/dev..origin/main --stat | tail -5                              # C: phantom-commits sanity

# Re-confirm no guarded (dev-only) paths leaked to main.
git diff origin/main..HEAD --name-only \
  | grep -E '^(docs/plans|docs/brainstorms|docs/ideation|docs/research|docs/reviews|docs/solutions|\.context)' \
  && echo "LEAKED — reset and redo" || echo "(clean — no guarded paths)"

# Patch-id cherry check (noisy in a squash-merge workflow; triage per-line).
git cherry HEAD origin/dev | grep '^+' || echo "(none — release is patch-equivalent through dev)"

# 5. Generate CHANGELOG.md. On a release/YYYY.MM.DD branch the version is
#    detected automatically; --tag is only needed when run off such a branch.
GITHUB_TOKEN=$(gh auth token) scripts/generate-changelog.py

# 6. Review CHANGELOG.md (cliff.toml chore-skip footgun: see RATIONALE § CHANGELOG generation).

# 7. Commit and push.
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG.md"
git push -u origin "release/$(date +%Y.%m.%d)"

# 8. Open the PR (scrub the body in /tmp/ first).
gh pr create --base main --title "release: $(date +%Y.%m.%d)" --body-file /tmp/body.md
```

When the PR merges (squash-only, enforced by `protect-main.json`), the push to `main` triggers `release.yml`. Verify it
with [§ Tagging and publishing](#tagging-and-publishing) below. Once the tag and GitHub Release publish, bring the
release-only `CHANGELOG.md` back to `dev` with the backport step below.

→ Rationale (why branch from main and cherry-pick, triple-diff false-positive triage):
[`RELEASES-RATIONALE.md` § Triple-diff verification](./RELEASES-RATIONALE.md#triple-diff-verification).

### Cherry-pick conflicts on guarded paths

Cherry-picks of feature PRs that also touched `docs/plans/` / `docs/brainstorms/` / `docs/ideation/` / `docs/research/`
/ `docs/reviews/` / `docs/solutions/` / `.context/` files hit modify/delete conflicts on the release branch — those
paths exist on `dev` but never reach `main`. The standard `git rm` is denied by repo policy; use the plumbing form:

```bash
git update-index --remove $(git diff --name-only --diff-filter=U)   # mark guarded paths deleted
trash docs/plans/<leftover-paths>.md                                 # clear orphan worktree files
git cherry-pick --continue --no-edit
```

Repeat per conflicting commit. After all picks land, `git ls-files docs/plans/ docs/brainstorms/` should be empty; drop
any stray with the same pattern before the leak check.

## Tagging and publishing

The tag is **not** created locally. `release.yml` triggers on any push to `main` and runs:

| Step                     | What                                                                                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Compute CalVer version` | `YYYY.MM.DD` in America/Los_Angeles. If tags for today already exist, append `.N` (e.g. `2026.04.15.1`).                                                    |
| `Extract release notes`  | Read the topmost `## [version]` section from the committed `CHANGELOG.md`. Falls back to `"Release <version>"` if empty.                                    |
| `Tag and push`           | `git tag <version> && git push origin <version>`. Bare (non-annotated) because the workflow runs as `github-actions[bot]` without a signing key configured. |
| `Create GitHub Release`  | `softprops/action-gh-release` publishes a release with the extracted notes as the body.                                                                     |

No crates, no cross-compiled binaries, no Homebrew dispatch — this repo is config-only.

**Verify after merge** (the full post-tag pipeline for this repo is these four checks):

- [ ] `release.yml` is green end-to-end. Watch it (`gh run watch <id>`), then confirm with `gh run view <id> --json
  conclusion --jq .conclusion` returning `success` — a completed watcher is not a green watcher.
- [ ] The CalVer tag exists: `git fetch --tags && git describe --tags --abbrev=0 origin/main` returns today's
  `YYYY.MM.DD` (or `.N`).
- [ ] The GitHub Release published with real notes: `gh release view "$(git describe --tags --abbrev=0 origin/main)"`
  shows the body extracted from `CHANGELOG.md`, not the `"Release <version>"` fallback (an empty body means the
  changelog section was empty).
- [ ] The `CHANGELOG.md` backport PR to `dev` merged (see § Backport to dev after release).

→ Rationale (CI-side CalVer tagging, why no local tag):
[`RELEASES-RATIONALE.md` § Release pipeline](./RELEASES-RATIONALE.md#release-pipeline).

### Backport to dev after release

`release/*` is cut from `origin/main` and regenerates `CHANGELOG.md` there. That commit never round-trips to `dev`, so
without a deliberate backport `dev`'s `CHANGELOG.md` freezes at the last release it saw while `main` marches on. Once
the release tag and GitHub Release have published, run:

```bash
scripts/sync-dev-after-release.sh "$(git describe --tags --abbrev=0 origin/main)"
```

It copies `CHANGELOG.md` verbatim from `origin/main` onto a `chore/sync-dev-after-<version>` branch and opens a PR to
`dev`. The copy is **surgical** — only `CHANGELOG.md` moves, only `main → dev`. `dev` is normally many commits ahead of
`main`, so a branch merge would revert unreleased work; the script never does that, and refuses to run on a dirty tree
or before the GitHub Release is published. Confirm the PR's only changed file is `CHANGELOG.md`, then squash-merge it.
The run is idempotent — if `dev` already matches `main`, it exits without opening a PR.

If a release also polished `README.md` or `RELEASES*.md` on `main`, check `git diff origin/dev..origin/main -- README.md
RELEASES.md RELEASES-RATIONALE.md RELEASES-PREFLIGHT.md` and fold any real release-prep changes into the same backport
PR by hand.

→ Rationale (why surgical copy, not `git merge main → dev`):
[`RELEASES-RATIONALE.md` § Release pipeline](./RELEASES-RATIONALE.md#release-pipeline).

### Emergency docs fix to main

Any push to `main` triggers a release. If you must push a docs-only commit directly to `main` (e.g. rewording a README),
include `[skip ci]` in the commit message to suppress the release workflow. Prefer the standard release-branch flow
whenever possible.

## Prose scrubbing

Three release-flow artifacts ship text to GitHub outside any in-repo formatter and need a manual scrub first: PR bodies,
`CHANGELOG.md` (generated from upstream PR bodies), and the release-PR body (composed after `CHANGELOG.md` is
generated). Author each in `/tmp/`, scrub, then submit via `--body-file`:

```bash
~/.claude/skills/unslop/scripts/score.py /tmp/body.md   # em-dash density + AI-unique structural patterns; must score 0
```

This repo runs `unslop` as the minimum prose floor; the full Vale + LanguageTool stack is not wired up here. For a
`CHANGELOG.md` finding, fix the upstream PR body (which `generate-changelog.py` re-fetches every run) and regenerate —
never hand-edit `CHANGELOG.md`.

→ Rationale: [`RELEASES-RATIONALE.md` § Prose scrubbing scope](./RELEASES-RATIONALE.md#prose-scrubbing-scope).

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- `protect-main.json` — required signatures, linear history, squash-only merges via PR, creation/deletion blocked,
  non-fast-forward blocked. No required status checks (shellcheck/bats are advisory on main; `release.yml` runs
  post-merge).
- `protect-dev.json` — required signatures, deletion blocked, non-fast-forward blocked. `shellcheck` and `bats` are
  required status checks; the PR-only norm is convention, not ruleset-enforced.

```bash
# First apply (creating a ruleset):
gh api -X POST repos/brettdavies/dotfiles/rulesets --input .github/rulesets/protect-dev.json
# Subsequent updates (replace by ID — find via `gh api repos/brettdavies/dotfiles/rulesets`):
gh api -X PUT repos/brettdavies/dotfiles/rulesets/<id> --input .github/rulesets/protect-main.json
```

→ Status-check context strings (inline vs reusable):
[`RELEASES-RATIONALE.md` § Branch protection](./RELEASES-RATIONALE.md#branch-protection).

## Required secrets

| Secret             | Purpose                                                                                                                                                                         | Lifecycle         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| `CI_RELEASE_TOKEN` | Fine-grained PAT, Contents R+W. Used by `release.yml` to push the tag and create the GitHub Release; the default `GITHUB_TOKEN` cannot push to `main` past `protect-main.json`. | Rotated annually. |

Rotate via `op read "op://secrets-dev/dotfiles_RELEASE_TOKEN/credential" | gh secret set CI_RELEASE_TOKEN`.

## Troubleshooting

**`generate-changelog.py` errors with "could not detect version":** Run it from a `release/YYYY.MM.DD` branch, or pass
`--tag YYYY.MM.DD` explicitly. Confirm detection without a full run via `scripts/generate-changelog.py --print-tag`.

**Empty changelog sections:** Ensure `cliff.toml` has `[remote.github]` with `owner` and `repo` for PR-body expansion,
and that `GITHUB_TOKEN` is exported (the command above falls back to `gh auth token`).

**Push to `release/*` rejected for unsigned commits:** Release branches aren't in `protect-dev.json`'s ref pattern, but
`gitconfig` sets `commit.gpgsign = true` globally and `.githooks/pre-commit` enforces it. Ensure your SSH signing key is
configured (1Password on macOS, ssh-keygen on headless Linux).

**Same-day re-release:** If today already has a `YYYY.MM.DD` tag, CI auto-bumps to `YYYY.MM.DD.1`, `YYYY.MM.DD.2`, etc.
No local action — just merge another `release/*` PR.

## Related docs

- [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md) — pre-cut go/no-go checklist gating release-branch creation.
- [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md) — release-flow rationale: branching, PR body, pipeline, CHANGELOG.
- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure with changelog sections.
- [`cliff.toml`](cliff.toml) — git-cliff configuration: commit parsers, tag pattern, remote metadata.
