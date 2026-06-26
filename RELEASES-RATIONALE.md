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
`release/*` head is what keeps that setting compatible with a forever integration branch.

Planning-only docs (`docs/plans/`, `docs/brainstorms/`, `docs/ideation/`, `docs/research/`, `docs/reviews/`,
`docs/solutions/`, `.context/`) live on `dev` only and never reach `main`. They are inert text that doesn't ship, so
they skip the feature-branch ceremony and commit directly to `dev`. The release flow drops them at cherry-pick time, and
the leak check in RELEASES.md is the backstop. Consumer-facing markdown (README, AGENTS, CHANGELOG, the RELEASES quad)
is not in that exception — it ships to `main`, so it goes through the standard PR flow.

### Why cherry-pick from `main`, not branch from `dev`

Two compounding problems broke the earlier "branch from `dev`, merge into the release branch" flow on every release:

1. **`add/add` conflicts.** Branching from `dev` produces `add/add` merge conflicts whenever `dev` and `main` have
   diverged, which they always do after the first squash merge. The same file appears "added" on both sides with
   different content.
2. **Orphan history leaking into the changelog.** `git merge origin/dev` pulls in every ancestor SHA on `dev` —
   including individual commits collapsed into prior release squashes on `main`. Those SHAs aren't reachable from the
   last tag, so `git-cliff --unreleased` re-emits them in every new release's changelog.

Cherry-picking solves both: branching from `origin/main` avoids the conflicts, and picking only PR squash commits
creates fresh SHAs on the release branch that represent exactly the delta being shipped — no prior-release noise.

### Why pick only PR squash commits

The cherry-pick list filters on `--grep='(#[0-9]\+)$'` (the squash-merge `(#NNN)` suffix). Direct commits to `dev` are
intentionally excluded: they are the planning-doc exception above, which must not reach `main`. Anything that needs to
ship comes in via its own PR and carries a PR number, so the filter is also a correctness gate, not just a convenience.

## PR body conventions

### No explainer prose in the body

Every section is user-facing substance only: the **net diff**, what changes for the consumer that wasn't there before —
not the commit history or intermediate state that produced it. Workflow mechanics (cherry-pick, regenerate, pre-push
gate, CI behavior) are documented in RELEASES.md and `.github/`, not in the PR body. Verification artifacts (triple-diff
output, leak-check narration, patch-id counts, CI status) stay local; anomalies get fixed before push, not
audit-trailed.

### Why `feat`/`fix` are preferred over `chore`

`cliff.toml` drops commits whose subject starts with `chore`, `style`, `test`, `ci`, or `build`, regardless of body
content. Mistyping a user-facing change as `chore` silently strips it from release notes. Prefer `feat` / `fix` for
anything user-observable: config defaults, env vars, shell aliases, templates, default behaviors.

### Why required-when-empty sub-headers

`Related Issues/Stories` has four labels and `Files Modified` has four sub-headers. All must appear in every PR even
when empty — write `- None.` or `n/a` rather than deleting them. Scanners and humans both rely on a known section shape;
conditionally-absent sections force every reader to check "did the author skip this or does it not apply?"

### Why no AI attribution and no hard wraps

`Co-Authored-By: Claude …`, "Generated with" trailers, or any AI-attribution trailer is banned from commits and PR
bodies — they are noise and age poorly. Author each paragraph and bullet as one logical line; GitHub soft-wraps for
display, and hard wraps produce mid-sentence breaks in some renderers and interfere with the `unslop` line-anchored
scan.

## Triple-diff verification

The release-PR procedure runs three diffs (A: main→release, B: release→dev for non-doc paths, C: dev→main) plus a
patch-id cherry check. It's belt-and-suspenders because missed cherry-picks have shipped to `main` on sibling repos
before, and the file-level diff in B alone doesn't catch the patch-id false-negative class.

### Why the patch-id cherry-check output is noisy

In a squash-merge workflow, `git cherry HEAD origin/dev` emits many `+` lines that need human triage. They do NOT
auto-block the release. Expected false positives:

1. **Historical commits squash-merged in prior releases.** The squash commit on `main` has a different patch-id than the
   `dev` commits it consolidates, so old commits show as `+` forever. Anything older than the previous tag is almost
   always this.
2. **Cherry-picks where conflict resolution stripped guarded paths** (`docs/plans/`, etc.) or otherwise altered the
   tree. Same intent, different patch-id.
3. **Intentionally skipped commits** — direct-to-dev planning-doc commits, prior release-prep backports.

A real miss looks like a recent `feat`/`fix` commit on `dev` whose *file content* is not yet on `main`. Triage a `+`
line with `git show <sha> --stat` then `git diff origin/main..HEAD -- <those-files>`. If every touched file is guarded
or already on `main` via a prior squash, it's a false positive.

## CHANGELOG generation

### Generated, never hand-written

`scripts/generate-changelog.py` (with the repo-local `cliff.toml`) is the only sanctioned way to update `CHANGELOG.md`.
It runs `git-cliff` to prepend a versioned entry for commits since the last tag, then walks each squash-merged PR's body
to extract the `## Changelog → ### Added / Changed / Fixed / Documentation` subsections, replacing the auto-generated
bullets with the curated PR-body content (with author and PR-link attribution).

If a PR's `## Changelog` section is empty, that PR's entry is omitted (empty section = no user-facing change). To fix a
wrong entry, fix the input — edit the squash-merged PR body, then re-run the script. Never hand-edit `CHANGELOG.md`; the
next regeneration overwrites it.

### Why `cliff.toml` skips chore/style/test/ci/build

These types don't produce user-facing content. The footgun: if a cherry-picked PR has user-facing `## Changelog` content
but its commit subject starts with one of those types, its bullets are silently dropped. After running the script,
cross-check the generated section against `gh pr view <num> --json body` for each cherry-picked PR; correct mistyped PR
titles (e.g. `chore` → `feat`) and re-amend the cherry-pick subject before re-running.

## Release pipeline

### Why the tag is created in CI, not locally

`release.yml` computes the CalVer version (`YYYY.MM.DD` in America/Los_Angeles, with a `.N` suffix when today already
has tags) and creates the tag on push to `main`. Doing this in CI rather than locally makes the date and
same-day-collision logic a single source of truth — no local clock or timezone drift, and same-day re-releases auto-bump
without any local action. The workflow uses `CI_RELEASE_TOKEN` (a fine-grained PAT) because the default `GITHUB_TOKEN`
can't push past `protect-main.json`.

The tag is **bare** (non-annotated): the workflow runs as `github-actions[bot]`, which has no signing key, and
`tag.gpgsign = true` globally would make a local annotated tag the only signed option. The release commit is already
attributable through its squash-merge PR; the tag is just a pointer.

### Why backport with a surgical CHANGELOG copy, not `git merge main → dev`

`release/*` is cut from `origin/main` and regenerates `CHANGELOG.md` there against `main`'s base. That CHANGELOG commit
never round-trips to `dev`, so `dev`'s `CHANGELOG.md` freezes behind every release without a deliberate backport.

The backport copies only `CHANGELOG.md`, only `main → dev`, via `scripts/sync-dev-after-release.sh`. A full `git merge
origin/main into dev` is wrong here: `dev` is normally many commits ahead of `main`, and `main` carries only the release
squash plus the regenerated changelog, so a merge drags `main`'s release-branch tree state across `dev`'s unreleased
work and risks reverting it. `CHANGELOG.md` is the one file that legitimately diverges, so it's the only file that
moves. The script refuses to run on a dirty tree or before the GitHub Release is published, and is idempotent (no-op
when `dev` already matches `main`).

### Why `[skip ci]` exists for emergency main pushes

Any push to `main` triggers `release.yml` and therefore a release. A docs-only fix pushed straight to `main` (a README
typo) would cut a spurious release, so `[skip ci]` in the commit message suppresses the workflow. This is the escape
hatch, not the norm — the standard release-branch flow is preferred whenever there's time for it.

## Prose scrubbing scope

Three release-flow artifacts ship text to GitHub outside any in-repo formatter and need a manual scrub: PR bodies (`gh
pr create`/`edit` send body text straight to GitHub), `CHANGELOG.md` (generated from upstream PR bodies, so it inherits
their prose), and the release-PR body (composed after `CHANGELOG.md` is generated).

This repo runs `unslop` (`~/.claude/skills/unslop/scripts/score.py`) as the minimum prose floor — em-dash density plus
AI-unique structural patterns. The full Vale + LanguageTool stack is not wired up here; `unslop` is the floor every
brettdavies repo gets regardless. Author each artifact in `/tmp/`, scrub there, and submit via `--body-file`, so the
public PR only ever sees clean text. For a `CHANGELOG.md` finding, fix the upstream PR body (which
`generate-changelog.py` re-fetches every run) and regenerate.

## Branch protection

### Status-check context strings

The `required_status_checks[].context` strings in the rulesets must match exactly what GitHub publishes for each check.
An inline job (with a `name:` field) publishes as just `<job-name>`; a reusable-workflow caller (`uses:
.../foo.yml@ref`) publishes as `<caller-job-id> / <reusable-job-id-or-name>`. Mixing these produces a stuck-but-green PR
— every actual check reports green, but the ruleset waits forever on a context that never appears. This repo's checks
(`shellcheck`, `bats`) are inline jobs, so the contexts are the bare job names. Confirm the real contexts after a CI run
with `gh api repos/brettdavies/dotfiles/commits/<sha>/check-runs --jq '.check_runs[].name'`.

`shellcheck` and `bats` are required on `dev` (where feature PRs land) but advisory on `main`: by the time a `release/*`
PR reaches `main` the same commits already passed those checks on `dev`, and `release.yml` runs post-merge regardless.

### Why rulesets live in-repo

Committing the JSON under `.github/rulesets/` means ruleset changes land via the same review process as workflow changes
— a `chore(ci): tighten protect-main` change goes through `dev → release/* → main` like anything else.

## Related docs

- [`RELEASES.md`](./RELEASES.md) — operational runbook (commands, paths, decision tables).
- [`RELEASES-PREFLIGHT.md`](./RELEASES-PREFLIGHT.md) — pre-cut checklist gating the release-branch cut.
- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure with changelog sections.
- [`cliff.toml`](cliff.toml) — git-cliff configuration: commit parsers, tag pattern, remote metadata.
