# Releases rationale

Companion to [`RELEASES.md`](./RELEASES.md). RELEASES.md is the runbook (commands, paths, decision tables). This file
holds the WHY behind those rules: branching model, PR conventions, triple-diff verification, CHANGELOG generation,
release pipeline, prose-check scope, branch-protection pitfalls.

Read this when a rule in RELEASES.md doesn't make sense and you're tempted to change it, when a future you asks "why do
we do X this way," or when adding a new release-flow rule and you need to know where it fits.

## Branching model

### Forever `dev`, ephemeral release branches

`dev` is never deleted, even after a release. The next release cycle reuses the same `dev`. The repo's
`delete_branch_on_merge` setting can't touch `dev` as long as `dev` is never the head of a PR. Using a short-lived
`release/*` head is what keeps that setting compatible with a forever integration branch, and `guard-release-branch.yml`
rejects any PR to `main` whose head is not `release/*`, so the pattern is enforced rather than remembered.

Planning-only docs (`docs/plans/`, `docs/brainstorms/`, `docs/ideation/`, `docs/research/`, `docs/reviews/`,
`docs/solutions/`, `.context/`) live on `dev` only and never reach `main`. They are inert text that doesn't ship, so
they skip the feature-branch ceremony and commit directly to `dev`. The release recipe strips them from the release
branch, `guard-main-docs.yml` blocks them from any PR to `main`, and the leak check in RELEASES.md is the local
backstop. Consumer-facing markdown (README, AGENTS, CHANGELOG, the RELEASES trio) is not in that exception: it ships to
`main`, so it goes through the standard PR flow.

### Why the release branch is cut from `main`, never from `dev`

Every release squash-merges into `main`, so `main` and `dev` diverge in history even as their content converges; in this
repo the two share no common ancestor at all. Cutting the release branch from `dev`, or merging `dev` into `main`,
forces a three-way merge across that divergence: `add/add` collisions on files both sides changed, plus rename/delete
pairs git cannot auto-resolve. The conflict pile is an artifact of the lineage, not of the content shipping. A merge
also pulls every ancestor SHA on `dev` into `main`'s history, including commits already collapsed into earlier release
squashes, which is what made `git-cliff --unreleased` re-emit old entries in every new changelog.

Always cut the release branch from `origin/main` and bring `dev`'s content onto it as a forward diff, never by
reconciling histories. The construction is the whole-tree overlay (`git checkout origin/dev -- .`, remove the main-only
files `dev` deleted, then strip the guarded set): `main` ships `dev`'s tree minus a small, known exclusion set, so
asserting that end-state directly is simpler and safer than hand-resolving a merge or cherry-picking one PR at a time.
The overlay commit carries no per-PR history, so the changelog is built from the PRs merged into `dev` since the
previous release (`generate-changelog.py --from-dev-prs`) rather than from the branch's commits; the result is the same
per-PR section a cherry-picked branch would yield. Cherry-picking the dev squash-commits is kept only as an exception
for a release with a stated reason it cannot overlay, at the cost of guarded-path conflict handling.

Either way, the release must start from a `main` that `dev` fully contains. Security PRs, hotfixes, and config edits
land on `main` first, and the overlay takes `dev`'s content for every file it touches, so anything `main` holds that
`dev` never received is reverted by the release. `scripts/release/drift.sh` lists that set and the cut waits until it is
empty.

### Why direct-to-dev commits never need excluding

The overlay takes `dev`'s whole tree, so nothing is selected by commit. The direct-to-`dev` commits the dev-direct
exception allows only touch guarded paths, and the strip step removes those paths by name from the workflow's registered
set. A change that needs to ship comes in via its own PR, which is also what makes it appear in the changelog:
`--from-dev-prs` enumerates merged PRs, not commits.

### Version branch naming

`release/YYYY.MM.DD` (or `release/YYYY.MM.DD.N` for a same-day rerun) matches the tag CI will create, keeps release
branches sortable, and is what `generate-changelog.py` reads the version from. The generator also accepts
`release/vX.Y.Z` for SemVer repos; this repo tags without a prefix, so the branch carries none either.

## PR body conventions

### No explainer prose in the body

Every section is user-facing substance only: the **net diff**, what changes for the consumer that wasn't there before,
not the commit history or intermediate state that produced it. Workflow mechanics (overlay, regenerate, pre-push gate,
CI behavior) are documented in RELEASES.md and `.github/`, not in the PR body. Verification artifacts (diff output,
leak-check narration, drift-gate output, CI status) stay local; anomalies get fixed before push, not audit-trailed.

### Why `feat`/`fix` are preferred over `chore`

`cliff.toml` drops commits whose subject starts with `chore`, `style`, `test`, `ci`, or `build`, regardless of body
content, and `--from-dev-prs` applies the same rule to a PR title when the body carries no `## Changelog` content.
Mistyping a user-facing change as `chore` silently strips it from release notes. Prefer `feat` / `fix` for anything
user-observable: config defaults, env vars, shell aliases, templates, default behaviors.

### Why required-when-empty sub-headers

`Related Issues/Stories` has four labels and `Files Modified` has four sub-headers. All must appear in every PR even
when empty; write `- None.` or `n/a` rather than deleting them. Scanners and humans both rely on a known section shape;
conditionally-absent sections force every reader to check "did the author skip this or does it not apply?"

### Why no AI attribution and no hard wraps

`Co-Authored-By: Claude ...`, "Generated with" trailers, or any AI-attribution trailer is banned from commits and PR
bodies; they are noise and age poorly. Author each paragraph and bullet as one logical line; GitHub soft-wraps for
display, and hard wraps produce mid-sentence breaks in some renderers and interfere with the `unslop` line-anchored
scan.

## Triple-diff verification

The overlay recipe runs two staged diffs (A: what the release tree differs from `dev` in, B: no guarded path against
`main`) plus the enumeration in D. The cherry-pick exception runs the fuller triple-diff (A: main to release, B: release
to dev filtered by the guarded set, C: dev to main) plus a patch-id cherry check, because missed cherry-picks have
shipped to `main` on sibling repos before, and the file-level diff in B alone doesn't catch the patch-id false-negative
class.

### Why the guarded set resolves from the workflow

`guard-main-docs` is what CI enforces on a PR to `main`: the reusable workflow's hardcoded base list plus this repo's
`extra_paths`. Every hand-kept copy of that union (runbook, checklist, release script) drifted from it, and a copy that
omits a guarded path reports a real leak as clean while CI turns red after the push. `scripts/release/guarded-paths.sh`
reads `extra_paths` out of the caller workflow and adds the base list, so registering a path in the workflow is the only
edit a new guarded path needs. The base list is the one copy that still needs a manual edit when the reusable changes,
because it lives in another repo. Entries are globs with one rule set shared by the reusable and the script (`**/` any
depth, `*` and `?` within a segment, trailing slash guards the subtree), so the two never disagree about what is
guarded.

### Why the release enumerates what it adds

The leak check screens the diff against the registered set, so it says nothing about a category nobody registered. A new
engineering directory or a stray note under `docs/` passes the local check and `guard-main-docs` alike. Step D lists
every `docs/` file and every markdown file the release adds to `main` outside the guarded set and puts them in front of
a human; each one needs a reason to ship, or it gets registered in `extra_paths` and dropped from the branch. Root-level
markdown is in scope because an agent-facing glossary at the repo root is exactly the kind of addition a `docs/`-only
listing misses.

### Why the patch-id cherry-check output is noisy

In a squash-merge workflow, `git cherry HEAD origin/dev` emits many `+` lines that need human triage. They do NOT
auto-block the release. Expected false positives:

1. **Historical commits squash-merged in prior releases.** The squash commit on `main` has a different patch-id than the
   `dev` commits it consolidates, so old commits show as `+` forever. Anything older than the previous tag is almost
   always this.
2. **Cherry-picks where conflict resolution stripped guarded paths** or otherwise altered the tree. Same intent,
   different patch-id.
3. **Intentionally skipped commits**: direct-to-dev planning-doc commits, prior release-prep backports.

A real miss looks like a recent `feat`/`fix` commit on `dev` whose *file content* is not yet on `main`. Triage a `+`
line with `git show <sha> --stat` then `git diff origin/main..HEAD -- <those-files>`. If every touched file is guarded
or already on `main` via a prior squash, it's a false positive.

## CHANGELOG generation

### Generated, never hand-written

`scripts/generate-changelog.py` (vendored from the `github-repo-setup` skill, with the repo-local `cliff.toml`) is the
only sanctioned way to update `CHANGELOG.md`. On the overlay-built release branch it runs as `--from-dev-prs`: the PRs
merged into `dev` since the previous release are the entries, and each PR's body supplies its `## Changelog → ###
Breaking changes / Added / Changed / Fixed / Documentation` subsections (with author and PR-link attribution). The
window starts at the earlier of the previous tag's commit time and the previous `release/*` PR's creation time, and PR
numbers the changelog already lists are dropped, so a PR merged between the previous cut and its tag is neither lost nor
doubled. On a cherry-picked branch it runs `git-cliff` first to prepend a versioned entry from the branch's commits,
then expands the same way.

If a PR's body carries no changelog content, its title becomes a `Changed` bullet, except for `chore`, `ci`, `build`,
`style`, and `test` PRs, which stay out unless they carry a `## Changelog` of their own. To fix a wrong entry, fix the
input: edit the squash-merged PR body or title on GitHub, then re-run the script. Never hand-edit `CHANGELOG.md`; the
next regeneration overwrites it.

### Why `cliff.toml` skips chore/style/test/ci/build

These types don't produce user-facing content. The footgun: if a shipping PR has user-facing `## Changelog` content but
its title starts with one of those types, its bullets are silently dropped. After running the script, cross-check the
generated section against `gh pr view <num> --json body` for each PR in the window; correct mistyped PR titles (e.g.
`chore` → `feat`) with `gh pr edit` and re-run. `cliff.toml` also anchors releases on the bare CalVer tag pattern
(`YYYY.MM.DD` with an optional suffix), so a `v`-prefixed tag would not be a release boundary here.

## Release pipeline

### Why the tag is created in CI, not locally

`release.yml` computes the CalVer version (`YYYY.MM.DD` in America/Los_Angeles, with a `.N` suffix when today already
has tags) and creates the tag on push to `main`. Doing this in CI rather than locally makes the date and
same-day-collision logic a single source of truth: no local clock or timezone drift, and same-day re-releases auto-bump
without any local action. The workflow uses `CI_RELEASE_TOKEN` (a fine-grained PAT) because the default `GITHUB_TOKEN`
can't push past `protect-main.json`.

The tag is **bare** (non-annotated): the workflow runs as `github-actions[bot]`, which has no signing key, and
`tag.gpgsign = true` globally would make a local annotated tag the only signed option. The release commit is already
attributable through its squash-merge PR; the tag is just a pointer.

### Why the synced set is discovered, not listed

`release/*` is cut from `origin/main` and regenerates `CHANGELOG.md` there against `main`'s base. That commit never
round-trips to `dev`, so `dev`'s `CHANGELOG.md` freezes behind every release without a deliberate backport, and the same
is true of anything else the release branch edits.

The backport copied a hardcoded `CHANGELOG.md` for its first several releases, on the assumption that the changelog was
the only thing a release branch ever produced. That assumption is wrong the moment anyone edits the release branch for
any other reason, and it failed silently rather than loudly: the `2026.09.14` release reverted a stow payload and
deleted three tmuxinator configs on the branch, the backport copied the changelog alone, and those four paths stayed on
`main` with nothing reporting the gap. The next release's overlay takes `dev`'s tree, so it would have restored every
one of them.

A fixed list only ever catches what its author predicted, and the failure mode is invisible. The set is therefore
computed from the branches themselves, which is the only description that stays true as the release process changes. The
risk this introduces is the opposite one, clobbering `dev`'s unreleased work, and the previous release tag is what
bounds it: a path `dev` has not touched since that tag can only have been changed on the release branch, so adopting
`main`'s copy is safe. A path both sides moved is genuinely ambiguous and gets a human, not a default.

### Why backport with a surgical copy, by PR

The backport is a PR opened by `scripts/sync-dev-after-release.sh`, never a merge of `main` into `dev` and never a
direct push. `dev` is normally many commits ahead of `main`, the two histories share no ancestry, and `main` carries
only the release squash plus the regenerated changelog, so a merge conflicts on every file both sides touched and drags
`main`'s tree state across `dev`'s unreleased work; a direct push bypasses `dev`'s required checks. Only the paths that
legitimately diverged move, one file at a time, which is what keeps this a copy rather than a merge. The fleet template
of this script builds its synced set by probing for version carriers (`Cargo.toml`, `package.json`, `pyproject.toml`,
`VERSION`) and writing the released number into each; this repo has no version carrier, since CI derives the tag from
the date, so its copy discovers the set from the branch comparison instead and never grows a `VERSION` file that nothing
reads. The script refuses to run on a dirty tree or before the GitHub Release is published, and is idempotent (no-op
when `dev` already matches `main`).

### Rollback

Rollback happens at the surface users consume, not in git. For a config repo that surface is each deployed host's
checkout: re-stowing the previous tag on a host is fast and reversible, while rewriting `main` is neither, and the
release flow exists so that `main` only ever moves forward through a PR. After the rollback, the fix or revert lands
through `dev`, a release branch, and `main` like any other change, so the branch reconverges with what hosts run.
Recording the last-good tag before the release is what makes the rollback a single command under incident pressure.

### Why `[skip ci]` exists for emergency main pushes

Any push to `main` triggers `release.yml` and therefore a release. A docs-only fix pushed straight to `main` (a README
typo) would cut a spurious release, so `[skip ci]` in the commit message suppresses the workflow. This is the escape
hatch, not the norm; the standard release-branch flow is preferred whenever there's time for it.

## Prose scrubbing scope

Three release-flow artifacts ship text to GitHub outside any in-repo formatter and need a manual scrub: PR bodies (`gh
pr create`/`edit` send body text straight to GitHub), `CHANGELOG.md` (generated from upstream PR bodies, so it inherits
their prose), and the release-PR body (composed after `CHANGELOG.md` is generated).

This repo runs `unslop` (`~/.claude/skills/unslop/scripts/score.py`) as the minimum prose floor: em-dash density plus
AI-unique structural patterns. The full Vale + LanguageTool stack is not wired up here; `unslop` is the floor every
brettdavies repo gets regardless. Author each artifact in `/tmp/`, scrub there, and submit via `--body-file`, so the
public PR only ever sees clean text. For a `CHANGELOG.md` finding, fix the upstream PR body (which
`generate-changelog.py` re-fetches every run) and regenerate.

## Branch protection

### Status-check context strings

The `required_status_checks[].context` strings in the rulesets must match exactly what GitHub publishes for each check.
An inline job (with a `name:` field) publishes as just `<job-name>`; a reusable-workflow caller (`uses:
.../foo.yml@ref`) publishes as `<caller-job-id> / <reusable-job-id-or-name>`. Mixing these produces a stuck-but-green
PR: every actual check reports green, but the ruleset waits forever on a context that never appears. This repo's own
checks (`shellcheck`, `bats`) are inline jobs, so their contexts are the bare job names; the guard callers are
reusable-workflow callers, so theirs are `guard-docs / check-forbidden-docs`, `guard-provenance / check-provenance`, and
`guard-release / check-release-branch-name`. Confirm the real contexts after a CI run with `gh api
repos/brettdavies/dotfiles/commits/<sha>/check-runs --jq '.check_runs[].name'`.

`shellcheck` and `bats` are required on both `dev` (where feature PRs land) and `main`; by the time a `release/*` PR
reaches `main` the same commits already passed those checks on `dev`, and `release.yml` runs post-merge regardless.

### Why rulesets live in-repo

Committing the JSON under `.github/rulesets/` means ruleset changes land via the same review process as workflow
changes: a `chore(ci): tighten protect-main` change goes through `dev → release/* → main` like anything else.

## Related docs

- [`RELEASES.md`](./RELEASES.md): operational runbook (commands, paths, decision tables).
- [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md): pre-cut checklist gating the release-branch cut.
- [`.github/pull_request_template.md`](.github/pull_request_template.md): PR body structure with changelog sections.
- [`cliff.toml`](cliff.toml): git-cliff configuration: commit parsers, tag pattern, remote metadata.
