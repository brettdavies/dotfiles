# Releasing `dotfiles`

Every change reaches `main` via this pipeline. Direct commits to `dev` or `main` are not permitted — every change has a
PR number in its squash commit message, which keeps the history scannable, attributable, and changelog-ready.

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

`dev` is a **forever branch**. Never delete it locally or remotely, even after a `release/* → main` merge. The next
release cycle reuses the same `dev`. Using a short-lived `release/*` head is what lets `dev` stay around forever while
still going through a PR into `main`.

## Daily dev (feature → dev)

```bash
git checkout dev && git pull
git checkout -b feat/short-description
# ... work ...
git push -u origin feat/short-description
gh pr create --base dev --title "feat(scope): what changed"
# Reviews pass → squash-merge (PR body becomes the dev commit message)
```

- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/). See
  `~/.claude/templates/commit-message.md` for the full spec.
- **PR body**: follow `.github/pull_request_template.md`. The `## Changelog` section is the source of truth for
  user-facing release notes — `git-cliff` extracts these bullets verbatim into `CHANGELOG.md` during release prep.
- **Signing**: `dev` requires signed commits per `protect-dev.json`. The `pre-commit` hook verifies `commit.gpgsign =
  true` locally before push.

## Releasing dev to main

Dotfiles uses CalVer — versions are `YYYY.MM.DD` (plus a `.N` suffix for same-day reruns). CI computes the version and
creates the tag on push to `main`, so local tagging is never needed. The release branch exists to carry a committed
`CHANGELOG.md` through the PR.

**Branch naming**: `release/YYYY.MM.DD`. The date is informational only — CI recomputes the version at push time from
today's date and any existing same-day tags.

```bash
# 1. Branch from main, NOT dev. Branching from dev causes add/add
#    conflicts whenever dev and main have divergent histories (the
#    post-squash-merge norm).
git fetch origin
git checkout -b "release/$(date +%Y.%m.%d)" origin/main

# 2. Cherry-pick PR squash commits from dev onto the release branch.
#    Each pick creates a new commit carrying the PR's conventional-commit
#    subject — exactly what git-cliff needs to categorize entries. Unlike
#    `git merge origin/dev`, this does NOT drag in orphan SHAs from
#    prior releases, so the generated changelog covers only the true delta.
#    Direct commits on dev are intentionally excluded; per the
#    branches table, direct commits to dev are not permitted, and
#    any fix must come in via its own PR.
LAST_TAG=$(git describe --tags --abbrev=0 origin/main)
git log --first-parent --grep='(#[0-9]\+)$' --format='%H %s' \
  "$LAST_TAG..origin/dev"
# Review the list, then cherry-pick in chronological order (oldest first):
git cherry-pick <oldest-sha> <next-sha> ... <newest-sha>

# 3. Triple-diff verification — belt-and-suspenders sweep that catches both
#    directions of drift before the release tag goes out:
#
#    A. main → release  (what users will see; the intended ship surface)
#    B. release → dev   (should be empty for non-doc paths until the
#                        CHANGELOG commit lands, and even then should
#                        only list that release-prep file — anything else
#                        is a missed cherry-pick)
#    C. dev → main      (sanity: phantom commits dev "appears ahead" on
#                        because cherry-pick rewrites SHAs post-squash)
git diff origin/main..HEAD --stat                                                # A
git diff HEAD..origin/dev --name-only | grep -v '^docs/' || echo "(none)"        # B
git diff origin/dev..origin/main --stat | tail -5                                # C
#
# Re-confirm no guarded paths leaked (planning docs are dev-only and must
# never reach main per the branch-discipline exception in CLAUDE.md):
git diff origin/main..HEAD --name-only \
  | grep -E '^(docs/plans|docs/brainstorms|docs/ideation|docs/research|docs/reviews|docs/solutions|\.context)' \
  && echo "LEAKED — reset and redo" || echo "(clean — no guarded paths)"
#
# Patch-id cherry check — catches commits on dev that have NO patch-id
# equivalent on release. The file-level diff in B misses this class when
# the same content happens to land via a different commit.
#
# IMPORTANT: in a squash-merge workflow this output is noisy. Every '+'
# line needs human triage — it does NOT auto-block the release. Expected
# sources of '+' lines that are NOT real misses:
#
#   1. Historical commits squash-merged in prior releases. The squash
#      commit on main has a different patch-id than the dev commits it
#      consolidates, so old commits show as '+' forever. Anything older
#      than the previous release tag is almost always this.
#   2. Cherry-picks where conflict resolution stripped guarded paths
#      (docs/plans, docs/brainstorms, etc.) or otherwise altered the
#      tree. Same source-code intent, different patch-id.
#   3. Intentionally skipped commits — docs-only commits, release-prep
#      backports, revert-and-redo prep steps (see release 2026.05.02
#      where PR #57's revert was excluded because main had nothing to
#      revert).
#
# A real miss looks like: a recent feat/fix/chore commit on dev whose
# *file content* is not yet on main. To triage a '+' line:
#
#   git show <sha> --stat                       # what did it touch?
#   git diff origin/main..HEAD -- <those-files> # already on release?
#
# If every touched file is guarded (docs/plans/, docs/brainstorms/, etc.)
# OR the content is already on main via a prior squash, it's a false
# positive — no action. Otherwise cherry-pick the commit and re-run the
# triple-diff.
git cherry HEAD origin/dev | grep '^+' || echo "(none — release is patch-equivalent through dev)"
#
# If B lists any non-docs path you didn't expect, fetch dev, identify the
# commit (`git log dev --not origin/main`), cherry-pick it, re-run the
# triple-diff. Missed cherry-picks have shipped to main on sibling repos
# before — this step is the cheap way to catch them.

# 4. Generate CHANGELOG.md. On a release/YYYY.MM.DD branch the version is
#    detected automatically; --tag is only needed when run off such a branch.
GITHUB_TOKEN=$(gh auth token) scripts/generate-changelog.py

# 5. Review CHANGELOG.md. See the "CHANGELOG is generated, never hand-written"
#    subsection below for the cliff.toml chore-skip footgun and how to recover.

# 6. Commit and push:
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG.md"
git push -u origin "release/$(date +%Y.%m.%d)"

# 7. Open the PR:
gh pr create --base main --title "release: $(date +%Y.%m.%d)" \
             --body "Release $(date +%Y.%m.%d)"
```

When the PR merges (squash-only, enforced by `protect-main.json`), the push to `main` triggers `release.yml`. The
release branch can be deleted from the GitHub UI after merge. Once the release tag and GitHub Release publish, bring the
release-only files back to `dev` with the backport step below — skip it and `dev`'s `CHANGELOG.md` drifts behind every
release.

### Why branch from main and cherry-pick, not merge dev

Two compounding problems made the earlier "branch from main, merge dev" flow break on every release:

1. **`add/add` conflicts.** Branching from `dev` produces `add/add` merge conflicts whenever `dev` and `main` have
   diverged (which they always do after the first squash merge). The same file appears "added" on both sides with
   different content.
2. **Orphan history leaking into the changelog.** `git merge origin/dev` pulls in every ancestor SHA on dev — including
   individual commits that were collapsed into prior release squashes on `main`. Those SHAs aren't reachable from the
   last tag, so `git-cliff --unreleased` re-emits them in every new release's changelog.

Cherry-picking solves both: branching from `origin/main` avoids the conflicts, and picking only PR squash commits
creates fresh SHAs on the release branch that represent exactly the delta being shipped — no prior-release noise.

### CHANGELOG is generated, never hand-written

`scripts/generate-changelog.py` (with `cliff.toml`) is the only sanctioned way to update `CHANGELOG.md`. The script runs
`git-cliff` to prepend a versioned entry for commits since the last tag, then walks each squash-merged PR's body to
extract the `## Changelog` section's `### Added` / `### Changed` / `### Fixed` / `### Documentation` subsections,
replacing the auto-generated bullets with the curated PR-body content (with author and PR-link attribution).

If a PR's `## Changelog` section is empty, that PR's entry is omitted from the changelog (the convention in
[`.github/pull_request_template.md`](.github/pull_request_template.md): empty section = no user-facing change). To fix a
wrong CHANGELOG entry, fix the input — edit the squash-merged PR body, then re-run the script. Do **not** edit
`CHANGELOG.md` directly.

**`cliff.toml` skips `chore`/`style`/`test`/`ci`/`build` commits regardless of PR-body content.** If a cherry-picked PR
has user-facing `## Changelog` content but its commit subject starts with one of those types, its bullets get silently
dropped. After running the script, cross-check the generated section against `gh pr view <num> --json body` for each
cherry-picked PR; correct mistyped PR titles (e.g. `chore` → `feat`) and re-amend the cherry-pick subject before
re-running. See "Prefer `feat`/`fix` over `chore`" in global CLAUDE.md for prevention.

## Tagging and publishing

The tag is **not** created locally. `release.yml` triggers on any push to `main` and runs:

| Step                     | What                                                                                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Compute CalVer version` | `YYYY.MM.DD` in America/Los_Angeles. If tags for today already exist, append `.N` (e.g. `2026.04.15.1`).                                                    |
| `Extract release notes`  | Read the topmost `## [version]` section from the committed `CHANGELOG.md`. Falls back to `"Release <version>"` if empty.                                    |
| `Tag and push`           | `git tag <version> && git push origin <version>`. Bare (non-annotated) because the workflow runs as `github-actions[bot]` without a signing key configured. |
| `Create GitHub Release`  | `softprops/action-gh-release` publishes a release with the extracted notes as the body.                                                                     |

No crates, no cross-compiled binaries, no Homebrew dispatch — this repo is config-only.

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

If a release also polished `README.md` or `RELEASES.md` on `main`, those edits drift the same way. Check `git diff
origin/dev..origin/main -- README.md RELEASES.md` and fold any real release-prep changes into the same backport PR by
hand. Background:
[`docs/solutions/workflow-issues/post-release-backport-prevents-diff-b-false-positives-2026-05-07.md`](docs/solutions/workflow-issues/post-release-backport-prevents-diff-b-false-positives-2026-05-07.md).

### Emergency docs fix to main

Any push to `main` triggers a release. If you must push a docs-only commit directly to `main` (e.g. rewording a README),
include `[skip ci]` in the commit message to suppress the release workflow. Prefer the standard release-branch flow
whenever possible.

## PRs and changelog generation

- **No explainer prose anywhere in the body.** User-facing substance only — what is changing for the consumer that was
  not already there. Do NOT recap the workflow (cherry-pick / regenerate / pre-push gate / CI behavior is documented in
  this file and `.github/`).
- **Summary describes the net diff only** — what merged `main` looks like vs the base branch. One short paragraph; not
  commit history, intermediate state, or cherry-pick mechanics.
- **Zero verification artifacts in the body.** No triple-diff stats, leak-check output ("`guard-main-docs` runs clean"),
  patch-id cherry-check counts, pre-push gate results, CI status, prose-scrub findings, or exclusion rationale. Those
  stay local; anomalies get fixed before push, not audit-trailed.
- **One logical line per bullet and paragraph; no hard wraps.** GitHub soft-wraps for display. When release PR bodies
  reuse bullets from `CHANGELOG.md`, the bullets arrive pre-wrapped at the repo's MD013 limit (120 chars) — unwrap the
  continuation lines before pasting. `auto-format.sh`'s `/tmp/*` skip exempts the body file itself, so the unwrapped
  form survives the round-trip to `gh pr {create,edit} --body-file`.

Every PR **must** follow `.github/pull_request_template.md`. The template's `## Changelog` section has these
subsections:

- `### Added` — new user-visible features or capabilities.
- `### Changed` — changes to existing behavior.
- `### Fixed` — bug fixes.
- `### Documentation` — documentation-only updates.

A PR that has no user-facing impact (pure refactor, test-only, CI-only) should leave the `## Changelog` section empty or
omit it — the PR still appears in git history but won't clutter the changelog. See "CHANGELOG is generated, never
hand-written" above for how the script consumes these sections at release time and the cliff.toml chore-skip footgun.

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- `protect-main.json` — required signatures, linear history, squash-only merges via PR, creation/deletion blocked,
  non-fast-forward blocked. No required status checks (shellcheck is advisory; `release.yml` runs post-merge).
- `protect-dev.json` — required signatures, deletion blocked, non-fast-forward blocked. No PR requirement at the ruleset
  level; the PR-only norm is enforced by convention.

### Applying changes

Edit the JSON locally, then sync to the remote:

```bash
# First apply (creating a ruleset):
gh api -X POST repos/brettdavies/dotfiles/rulesets --input .github/rulesets/protect-dev.json

# Subsequent updates (replace by ID — find via `gh api repos/brettdavies/dotfiles/rulesets`):
gh api -X PUT repos/brettdavies/dotfiles/rulesets/<id> --input .github/rulesets/protect-main.json
```

Committing the JSON alongside config means ruleset changes land via the same review process as workflow changes — a
`chore(ci): tighten protect-main` change goes through dev → release/* → main like anything else.

## Required secrets

| Secret             | Purpose                                                                                                                                                                                                 | Lifecycle         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| `CI_RELEASE_TOKEN` | Fine-grained PAT, Contents R+W. Used by `release.yml` to push the tag and create the GitHub Release. The default `GITHUB_TOKEN` cannot push to `main` because `protect-main.json` blocks non-PR writes. | Rotated annually. |

## Troubleshooting

**`generate-changelog.py` errors with "could not detect version":** Run it from a `release/YYYY.MM.DD` branch, where the
version is detected automatically, or pass `--tag YYYY.MM.DD` explicitly when running off such a branch. Confirm
detection without a full run via `scripts/generate-changelog.py --print-tag`.

**Empty changelog sections:** Ensure `cliff.toml` has `[remote.github]` with `owner` and `repo` for PR body expansion,
and that `GITHUB_TOKEN` is exported (the command above falls back to `gh auth token`).

**Push to `release/*` rejected for unsigned commits:** Release branches aren't listed in `protect-dev.json`'s ref
pattern, but `gitconfig` sets `commit.gpgsign = true` globally and `.githooks/pre-commit` enforces it. Ensure your SSH
signing key is configured (1Password on macOS, ssh-keygen on headless Linux — see
`docs/solutions/deployment-issues/headless-linux-git-signing-and-hook-guards.md`).

**Same-day re-release:** If today already has a `YYYY.MM.DD` tag, CI auto-bumps to `YYYY.MM.DD.1`, `YYYY.MM.DD.2`, etc.
No local action required — just merge another `release/*` PR.

**Duplicate release avoidance:** The release workflow triggers on every push to `main`. To push a non-release commit
(emergency docs fix, README typo) without creating a release, include `[skip ci]` in the commit message.

## Related docs

- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure with changelog sections
- [`AGENTS.md`](AGENTS.md) — project conventions, stow packages, shell config chain
- [`README.md`](README.md) — bootstrap, stow deploy, cross-platform notes
- [`cliff.toml`](cliff.toml) — git-cliff configuration: commit parsers, tag pattern, remote metadata
