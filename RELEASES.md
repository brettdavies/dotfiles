# Releasing `dotfiles`

Operational runbook. Rationale lives in [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md); the pre-cut go/no-go
checklist lives in [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md). Post-tag verification is short for a config-only
repo and is folded into [§ Tagging and publishing](#tagging-and-publishing) below.

Every change reaches `main` via this pipeline. Direct commits to `main` are not permitted; every change carries a PR
number in its squash commit message, which keeps the history scannable, attributable, and changelog-ready.

```text
feature branch → PR to dev (squash merge)
              → release/YYYY.MM.DD branch (dev's tree overlaid on origin/main, one commit)
              → PR to main (squash merge)
              → push to main triggers CI: compute CalVer → tag → GitHub Release
```

## Branches

| Branch                                 | Role                                    | Lifetime                                    | Protection                           |
| -------------------------------------- | --------------------------------------- | ------------------------------------------- | ------------------------------------ |
| `main`                                 | Production. Only release commits.       | Forever.                                    | `.github/rulesets/protect-main.json` |
| `dev`                                  | Integration. All feature PRs land here. | Forever. Never delete.                      | `.github/rulesets/protect-dev.json`  |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Feature work.                           | One PR's worth. Auto-deleted on merge.      | None. Squash into dev freely.        |
| `release/*`                            | Head of a dev → main PR.                | One release's worth. Auto-deleted on merge. | None.                                |

`dev` is a **forever branch**: never delete it locally or remotely, even after a `release/* → main` merge. Using a
short-lived `release/*` head is what lets `dev` stay around forever while still going through a PR into `main`, and
`guard-release-branch.yml` rejects any PR to `main` whose head is not `release/*`, so `dev` is never a PR head that
auto-delete could remove.

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
  user-facing release notes; `scripts/generate-changelog.py` extracts these bullets verbatim into `CHANGELOG.md` during
  release prep.
- **Signing**: `dev` requires signed commits per `protect-dev.json`. The `pre-commit` hook verifies `commit.gpgsign =
  true` locally before push.

### Dev-direct exception

Planning-only docs that live on `dev` and never ship to `main` can be committed directly to `dev` without a feature
branch or PR: `docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`, `docs/reviews/`,
`docs/solutions/`, and anything under `.context/`. `guard-main-docs.yml` blocks them from any PR to `main` regardless,
and the release recipe strips them from the release branch. The standard feature → PR → squash-merge flow stays required
for everything else, including consumer-facing markdown (README, AGENTS, CONTRIBUTING, CHANGELOG, in-repo runbooks such
as this file).

→ Rationale: [`RELEASES-RATIONALE.md` § Branching model](./RELEASES-RATIONALE.md#branching-model).

## PR body

Every PR (feature, fix, docs, release) uses `.github/pull_request_template.md` verbatim.

- **No explainer prose anywhere in the body.** User-facing substance only: what is changing for the consumer that was
  not already there. Do NOT recap the workflow (overlay, regenerate, pre-push gate, and CI behavior are documented in
  this file and `.github/`).
- **Summary describes the net diff only**: what merged `main` looks like vs the base branch. Not commit history,
  intermediate state, or how the release branch was assembled.
- **Zero verification artifacts in the body.** No diff stats, leak-check output, drift-gate output, pre-push gate
  results, CI status, or prose-scrub findings. Anomalies get fixed before push, not audit-trailed.
- **Changelog** subsections (`### Added` / `### Changed` / `### Fixed` / `### Documentation`): 1-5 bullets each, delete
  empty subsections, each bullet starts with a verb.
- **Related Issues/Stories** (`Story:` / `Issue:` / `Architecture:` / `Related PRs:`) and **Files Modified** (`Modified`
  / `Created` / `Renamed` / `Deleted`): every sub-label required even when empty; write `- None.` or `n/a`.
- **One logical line per paragraph or bullet; no hard wraps.** GitHub soft-wraps for display.
- **No AI attribution** in commits or PR bodies.

→ Rationale: [`RELEASES-RATIONALE.md` § PR body conventions](./RELEASES-RATIONALE.md#pr-body-conventions).

## Releasing dev to main

Before cutting a release branch, walk [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md) end-to-end. Any unchecked item
holds the release.

Dotfiles uses CalVer: versions are `YYYY.MM.DD` (plus a `.N` suffix for same-day reruns). CI computes the version and
creates the tag on push to `main`, so local tagging is never needed, and this repo carries no version file to bump. The
release branch exists to carry `dev`'s tree and a committed `CHANGELOG.md` through the PR.

**Branch naming**: `release/YYYY.MM.DD` (or `release/YYYY.MM.DD.N` for a same-day rerun). `generate-changelog.py` reads
the version from the branch name, so the date is the day the release lands. CI recomputes the tag from its own clock and
any existing same-day tags, so a stale branch name is a smell rather than an error.

`main` and `dev` share no common ancestor: every release squash-merges into `main`, so the two histories never converge
even as their content does. Reconciling them with a merge, or a branch cut from `dev`, produces a pile of add/add and
rename/delete conflicts that are artifacts of the lineage, not of the content shipping. The release branch is therefore
built as a **clean descendant of `main`** with `dev`'s tree overlaid on top, asserting the desired end-state directly:

```bash
# 0. Nothing on main that dev never received (security PRs, hotfixes, config). Exits 1
#    while drift exists. The anchor is the newest CalVer tag on main; gate 0 fails when
#    that release's CHANGELOG.md never reached dev, so run the backport step first.
scripts/release/drift.sh

# 1. Branch from main, NOT dev.
git fetch origin
git checkout -B "release/$(date +%Y.%m.%d)" origin/main

# 2. Overlay dev's entire tracked tree onto the main base. `checkout -- .` writes dev's
#    paths but does not delete files that exist on main and are absent on dev, so remove
#    those next (the 'D' rows are main-only files dev deleted).
git checkout origin/dev -- .
git diff --name-status origin/main origin/dev | grep '^D'
trash <each main-only file listed above>

# 3. Strip the paths guard-main-docs forbids on main. The set resolves from the workflow;
#    never restate it inline, because every hand-kept copy drifted from what CI enforces.
GUARDED="$(scripts/release/guarded-paths.sh)"
git ls-files | grep -E "$GUARDED" | xargs -r trash
git add -A                                                      # stages adds, mods, AND deletions

# 4. No version bump: CI derives the CalVer tag at push time. Build the changelog from the
#    PRs merged into dev since the previous release. The overlay commit carries no per-PR
#    history, so the section is built from dev's PRs, not from this branch's commits.
scripts/generate-changelog.py --from-dev-prs
git add -A

# 5. Verify before committing.
#    A: staged tree equals dev's minus the stripped guarded paths and the changelog.
#       Anything else printed here is a mistake.
git diff --cached --name-only origin/dev | grep -Ev "$GUARDED" \
  | grep -Ev '^CHANGELOG\.md$' \
  && echo "unexpected delta above; investigate" || echo "(clean: only intended deltas)"
#    B: no guarded path in the release tree.
git diff --cached --name-only origin/main | grep -E "$GUARDED" \
  && echo "LEAKED a guarded path: reset and redo" || echo "(no guarded paths)"
#    D: what this release ADDS to main. The leak check screens against the registered
#       set, so it is blind to a category nobody registered yet. Every docs/ entry and
#       every added markdown file needs a reason to ship, or it needs registering in the
#       workflow's extra_paths and removing from the branch.
git diff --cached --diff-filter=A --name-only origin/main | grep -E '(^docs/|\.md$)' | grep -Ev "$GUARDED" || echo "(none unguarded)"

# 6. Review CHANGELOG.md (cliff.toml chore-skip footgun: see RATIONALE § CHANGELOG
#    generation), then commit the overlay as one commit sitting directly on top of main
#    (subject "release: YYYY.MM.DD"; author the message in /tmp/ and pass --file). Re-run
#    the drift gate last, in case main moved while the branch was being built.
git commit --file /tmp/commit-msg.md
scripts/release/drift.sh

# 7. Push and open the PR (scrub the body in /tmp/ first).
git push -u origin "release/$(date +%Y.%m.%d)"
gh pr create --base main --head "release/$(date +%Y.%m.%d)" --title "release: $(date +%Y.%m.%d)" --body-file /tmp/body.md
```

The result is a single commit whose diff against `main` is the release, with `main` as an ancestor, so the PR merges
with zero conflicts. When it merges (squash-only, enforced by `protect-main.json`), the push to `main` triggers
`release.yml`. Verify it with [§ Tagging and publishing](#tagging-and-publishing) below. Auto-delete removes
`release/YYYY.MM.DD` from the remote on merge; `dev` is untouched. Once the tag and GitHub Release publish, bring the
release-only `CHANGELOG.md` back to `dev` with the backport step below.

→ Rationale (why overlay, not merge; why cut from `main`):
[`RELEASES-RATIONALE.md` § Branching model](./RELEASES-RATIONALE.md#branching-model). CHANGELOG mechanics:
[`RELEASES-RATIONALE.md` § CHANGELOG generation](./RELEASES-RATIONALE.md#changelog-generation).

### Exception: cherry-pick

The overlay is the release construction for this repo. Cherry-picking the dev squash-commits onto the `origin/main` base
is the exception, kept only for a release with a stated reason it cannot overlay (record it under
[Project specifics](#project-specifics)); the per-PR changelog is not such a reason, since `--from-dev-prs` builds it
from `dev` either way. When cherry-picking, list the PR squashes going out with the date-anchored `gh pr list` from
[`RELEASES-PREFLIGHT.md` § Establish the surface](./RELEASES-PREFLIGHT.md#establish-the-surface) (with no shared
ancestry, `$LAST_TAG..origin/dev` lists every PR ever merged to `dev`), pick them oldest first, then run the triple-diff
verification:

```bash
GUARDED="$(scripts/release/guarded-paths.sh)"

git diff origin/main..HEAD --stat                                              # A: ship surface
git diff HEAD..origin/dev --name-only | grep -Ev "$GUARDED" || echo "(none)"   # B: no missed picks
git diff origin/dev..origin/main --stat | tail -5                              # C: phantom-commits sanity

# Re-confirm no guarded paths leaked.
git diff origin/main..HEAD --name-only | grep -E "$GUARDED" \
  && echo "LEAKED: reset and redo" || echo "(clean)"

# D: what this release ADDS to main (see step 5 above for why).
git diff origin/main..HEAD --diff-filter=A --name-only | grep -E '(^docs/|\.md$)' | grep -Ev "$GUARDED" || echo "(none unguarded)"

# Patch-id cherry check (noisy in a squash-merge workflow; triage per-line).
git cherry HEAD origin/dev | grep '^+' || echo "(none)"
```

Cherry-picks of PRs that touched guarded paths hit modify/delete or rename/delete conflicts, since those paths live on
`dev` but are blocked from `main`; resolve them per the next section. Steps 4 to 7 of the overlay recipe then apply
unchanged.

→ Triple-diff false-positive triage:
[`RELEASES-RATIONALE.md` § Triple-diff verification](./RELEASES-RATIONALE.md#triple-diff-verification).

### Cherry-pick conflicts on guarded paths

Cherry-picks of feature PRs that also touched guarded paths hit modify/delete conflicts on the release branch, because
those paths exist on `dev` but never reach `main`. A PR that renames such a file also produces rename/delete conflicts
on the same paths. The standard `git rm` is denied by repo policy; use the plumbing form:

```bash
git update-index --remove $(git diff --name-only --diff-filter=U)   # mark guarded paths deleted
trash docs/plans/<leftover-paths>.md                                 # clear orphan worktree files
git cherry-pick --continue --no-edit
```

Repeat per conflicting commit. After all picks land, `git ls-files | grep -E "$(scripts/release/guarded-paths.sh)"`
should print nothing; drop any stray with the same pattern before the leak check.

## Tagging and publishing

The tag is **not** created locally. `release.yml` triggers on any push to `main` and runs:

| Step                     | What                                                                                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Compute CalVer version` | `YYYY.MM.DD` in America/Los_Angeles. If tags for today already exist, append `.N` (e.g. `2026.04.15.1`).                                                    |
| `Extract release notes`  | Read the topmost `## [version]` section from the committed `CHANGELOG.md`. Falls back to `"Release <version>"` if empty.                                    |
| `Tag and push`           | `git tag <version> && git push origin <version>`. Bare (non-annotated) because the workflow runs as `github-actions[bot]` without a signing key configured. |
| `Create GitHub Release`  | `softprops/action-gh-release` publishes a release with the extracted notes as the body.                                                                     |

No crates, no cross-compiled binaries, no Homebrew dispatch: this repo is config-only.

**Verify after merge** (the full post-tag pipeline for this repo is these checks):

- [ ] **Last-good identifier recorded before the merge.** Note the current tag on `main` (`git describe --tags
  --abbrev=0 origin/main`) somewhere reachable under incident pressure; it is the argument [§ Rollback](#rollback)
  needs.
- [ ] `release.yml` is green end-to-end. Watch it (`gh run watch <id>`), then confirm with `gh run view <id> --json
  conclusion --jq .conclusion` returning `success`; a completed watcher is not a green watcher.
- [ ] The CalVer tag exists: `git fetch --tags && git describe --tags --abbrev=0 origin/main` returns today's
  `YYYY.MM.DD` (or `.N`).
- [ ] The GitHub Release published with real notes: `gh release view "$(git describe --tags --abbrev=0 origin/main)"`
  shows the body extracted from `CHANGELOG.md`, not the `"Release <version>"` fallback (an empty body means the
  changelog section was empty).
- [ ] **Rollback path confirmed.** The previous tag re-stows cleanly on one deployed host (see [§ Rollback](#rollback));
  if this release is bad, roll back there first and fix forward through `dev`.
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

It discovers what to sync by comparing `origin/dev` against `origin/main` and excluding the guarded set, then lands the
result on a `chore/sync-dev-after-<version>` branch and opens a PR to `dev`. The set is computed, never hardcoded, so a
release-branch edit to any file is caught rather than only the ones someone thought to list.

Each candidate is classified against the **previous** release tag, the last point the two branches agreed:

| Class          | Condition                                                   | Action                                              |
| -------------- | ----------------------------------------------------------- | --------------------------------------------------- |
| `release-prep` | `dev`'s copy is byte-identical to its copy at the prior tag | Adopted: `main`'s version is pure release-prep      |
| `contested`    | Both branches moved the path since the prior tag            | Reported, not adopted, unless `--include-contested` |

The classification is what keeps the copy safe. `dev` is normally many commits ahead of `main`, so adopting `main`'s
version of a file `dev` has moved on would revert unreleased work; a contested path is surfaced for a human instead.
Guarded paths are excluded outright, because they live on `dev` by design and "syncing" them would delete them.

The script refuses to run on a dirty tree or before the GitHub Release is published, and the run is idempotent: if `dev`
already matches `main`, it exits without opening a PR. Use `--dry-run` to see the classification without creating
anything. Never merge `main` into `dev` and never push to `dev` directly: the two histories share no ancestry, so a
merge conflicts on every file both sides touched, and a direct push bypasses `dev`'s required checks.

After the backport PR merges, confirm the branches actually converged. This is the check that catches a contested path
nobody resolved:

```bash
git fetch origin
git diff --name-only origin/dev origin/main | grep -Ev "$(scripts/release/guarded-paths.sh)" || echo "(converged)"
```

Anything it lists is still `main`-only and will be reverted by the next release's overlay, which takes `dev`'s tree.

→ Rationale (why surgical copy, not `git merge main → dev`):
[`RELEASES-RATIONALE.md` § Release pipeline](./RELEASES-RATIONALE.md#release-pipeline).

### Emergency docs fix to main

Any push to `main` triggers a release. If you must push a docs-only commit directly to `main` (e.g. rewording a README),
include `[skip ci]` in the commit message to suppress the release workflow. Prefer the standard release-branch flow
whenever possible.

## Rollback

A bad release is rolled back at the surface users consume first, then repaired in git. For this repo that surface is
each deployed host's checkout: hosts track `main` and re-stow from it, so rolling back means re-stowing the previous tag
on the affected host. Rollback re-points what the host runs; it does not revert history.

```bash
PREV=<last-good tag recorded before the merge>        # e.g. 2026.06.26
git -C ~/dotfiles fetch --tags
git -C ~/dotfiles checkout "$PREV"
~/dotfiles/scripts/stow-deploy --all                    # or --headless --all on a server
```

Then land the `fix/*` or revert through the normal `dev` to `release/*` to `main` flow so `main` matches what is live,
and return the host to `main` (`git -C ~/dotfiles checkout main && git -C ~/dotfiles pull`) once that release publishes.

→ Rationale: [`RELEASES-RATIONALE.md` § Rollback](./RELEASES-RATIONALE.md#rollback).

## Prose scrubbing

Three release-flow artifacts ship text to GitHub outside any in-repo formatter and need a manual scrub first: PR bodies,
`CHANGELOG.md` (generated from upstream PR bodies), and the release-PR body (composed after `CHANGELOG.md` is
generated). Author each in `/tmp/`, scrub, then submit via `--body-file`:

```bash
~/.claude/skills/unslop/scripts/score.py /tmp/body.md   # em-dash density + AI-unique structural patterns; must score 0
```

This repo runs `unslop` as the minimum prose floor; the full Vale + LanguageTool stack is not wired up here. For a
`CHANGELOG.md` finding, fix the upstream PR body (which `generate-changelog.py` re-fetches every run) and regenerate;
never hand-edit `CHANGELOG.md`.

→ Rationale: [`RELEASES-RATIONALE.md` § Prose scrubbing scope](./RELEASES-RATIONALE.md#prose-scrubbing-scope).

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- `protect-main.json`: required signatures, linear history, squash-only merges via PR, creation/deletion blocked,
  non-fast-forward blocked, and five required checks: `shellcheck`, `bats`, and the three guard callers (`guard-docs /
  check-forbidden-docs`, `guard-provenance / check-provenance`, `guard-release / check-release-branch-name`).
- `protect-dev.json`: required signatures, deletion blocked, non-fast-forward blocked. `shellcheck` and `bats` are
  required status checks; the PR-only norm is convention, not ruleset-enforced.

```bash
# First apply (creating a ruleset):
gh api -X POST repos/brettdavies/dotfiles/rulesets --input .github/rulesets/protect-dev.json
# Subsequent updates (replace by ID; find it via `gh api repos/brettdavies/dotfiles/rulesets`):
gh api -X PUT repos/brettdavies/dotfiles/rulesets/<id> --input .github/rulesets/protect-main.json
```

→ Status-check context strings (inline vs reusable):
[`RELEASES-RATIONALE.md` § Branch protection](./RELEASES-RATIONALE.md#branch-protection).

## Project specifics

### Version and tags

- **CalVer, computed in CI.** The tag is `YYYY.MM.DD[.N]`, bare (no `v` prefix), created by `release.yml` on every push
  to `main`. There is no version file in the tree, so the release commit bumps nothing and the backport script copies
  `CHANGELOG.md` only.
- **`scripts/sync-dev-after-release.sh`** is this repo's CalVer, CHANGELOG-only variant of the fleet template. The
  template writes the released version into `Cargo.toml`, `package.json`, `pyproject.toml`, or `VERSION` and creates
  `VERSION` when none exist; this repo has no carrier and must not grow one, so the script stays a repo-owned fork.
- **`scripts/release/drift.sh` anchors on the newest CalVer tag reachable from `main`.** Gate 0 then checks that `dev`
  already carries that release's `CHANGELOG.md`; a failure there means the backport PR never merged, so run
  `scripts/sync-dev-after-release.sh <tag>` and merge it before cutting the release. `--since <ref>` overrides the
  anchor.
- **Stray or same-day tags.** `release.yml` derives `.N` from the tags already present for today, so a test tag created
  out of band shifts the next same-day suffix. Delete such tags and their GitHub Releases rather than working around
  them.

### Required secrets

| Secret             | Purpose                                                                                                                                                                         | Lifecycle         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| `CI_RELEASE_TOKEN` | Fine-grained PAT, Contents R+W. Used by `release.yml` to push the tag and create the GitHub Release; the default `GITHUB_TOKEN` cannot push to `main` past `protect-main.json`. | Rotated annually. |

Rotate via `op read "op://secrets-dev/dotfiles_RELEASE_TOKEN/credential" | gh secret set CI_RELEASE_TOKEN`.

## Troubleshooting

**`generate-changelog.py` errors with "could not detect version":** Run it from a `release/YYYY.MM.DD` branch, or pass
`--tag YYYY.MM.DD` explicitly. Confirm detection without a full run via `scripts/generate-changelog.py --print-tag`.

**`--from-dev-prs` lists PRs that already shipped, or misses recent ones:** The window starts at the earlier of the
previous release tag's commit time and the previous `release/*` PR's creation time, and PR numbers the changelog already
lists are dropped. Check `gh pr list --base dev --state merged --search "merged:>=<timestamp>"` against the section, and
fix the previous section on `main` (via a backport) if it is what is stale.

**Empty changelog sections:** Ensure `cliff.toml` has `[remote.github]` with `owner` and `repo` for PR-body expansion,
and that `gh auth status` succeeds (the script reads `GITHUB_TOKEN` when set and falls back to `gh auth token`).

**`drift.sh` reports dozens of files after a release that clearly shipped:** The anchor resolved to the wrong commit,
usually because the release tag is not present locally. Run `git fetch --tags` and rerun, or pass `--since <tag>`
explicitly; see [§ Project specifics](#project-specifics).

**`drift.sh` fails gate 0 (`origin/dev lacks the tag <tag> bookkeeping`):** The previous release's `CHANGELOG.md`
backport never merged into `dev`. Run `scripts/sync-dev-after-release.sh <tag>` (see § Backport to dev after release),
merge its PR, and rerun.

**Push to `release/*` rejected for unsigned commits:** Release branches aren't in `protect-dev.json`'s ref pattern, but
`gitconfig` sets `commit.gpgsign = true` globally and `.githooks/pre-commit` enforces it. Ensure your SSH signing key is
configured (1Password on macOS, ssh-keygen on headless Linux).

**Same-day re-release:** If today already has a `YYYY.MM.DD` tag, CI auto-bumps to `YYYY.MM.DD.1`, `YYYY.MM.DD.2`, etc.
No local action; just merge another `release/*` PR.

## Related docs

- [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md): pre-cut go/no-go checklist gating release-branch creation.
- [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md): release-flow rationale: branching, PR body, pipeline, CHANGELOG.
- [`.github/pull_request_template.md`](.github/pull_request_template.md): PR body structure with changelog sections.
- [`cliff.toml`](cliff.toml): git-cliff configuration: commit parsers, tag pattern, remote metadata.
