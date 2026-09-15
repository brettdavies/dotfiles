# Pre-release verification: `dotfiles`

Operational pre-flight checklist. Runs **before** step 0 of
[`RELEASES.md` § Releasing dev to main](./RELEASES.md#releasing-dev-to-main). It gates the cut of the
`release/YYYY.MM.DD` branch, not daily dev integration. Each box is an explicit go/no-go; any unchecked or red item
holds the release.

This repo is config-only: no binaries, no registry, no cross-compile. The checklist is correspondingly short. CI catches
mechanical regressions inside the repo (`shellcheck`, `bats`); this checklist covers what CI structurally can't: branch
drift, release scope, changelog completeness, the cross-platform deploy that no single runner exercises, and the prose
floor on GitHub-bound text.

Post-tag verification is folded into [`RELEASES.md` § Tagging and publishing](./RELEASES.md#tagging-and-publishing).

## Establish the surface

Everything below assumes you know what's shipping. Run this first.

`main` and `dev` share no common ancestor (every release squash-merges into `main`), so no tag is reachable from `dev`
and `git log $LAST_TAG..origin/dev` lists every PR ever merged, not the ones going out. The surface is date-anchored on
the previous tag instead, which is the same window `generate-changelog.py --from-dev-prs` uses; the file-level scope is
the whole-tree delta from `main` to `dev`.

```bash
LAST_TAG=$(git describe --tags --abbrev=0 origin/main)
SINCE=$(git log -1 --format=%cI "$LAST_TAG")
gh pr list --base dev --state merged --search "merged:>=$SINCE" --limit 200 \
  --json number,title --jq '.[] | "#\(.number)\t\(.title)"'                  # PRs going out
git diff origin/main origin/dev --stat | tail -1                             # file-level scope
gh pr list --base dev --state merged --search "merged:>=$SINCE" --limit 200 \
  --json title --jq '.[].title' | grep -E '^[a-z]+(\([^)]*\))?!:' || echo "(none)"   # breaking markers, scoped or not
```

Every `!:` PR gets a `### Breaking changes` (or `### Changed`) bullet in the release changelog.

## Checklist

### Branch drift (main ahead of dev)

Driven by `scripts/release/drift.sh`. Security PRs, hotfixes, and config edits land on `main` first. The release branch
is cut from `main` and then takes `dev`'s tree, so anything `main` holds that `dev` never received is reverted by the
release, and Dependabot raises the same fix again.

```bash
scripts/release/drift.sh
```

The anchor is the newest CalVer tag reachable from `origin/main`; `--since <ref>` overrides it.

- [ ] Gate 0 passes: `dev` already carries the previous release's `CHANGELOG.md`. Gate 0 fails when the previous
  release's bookkeeping never reached `dev`; run `scripts/sync-dev-after-release.sh <tag>`, merge its PR, and rerun.
- [ ] Every commit on `main` since the last tag has its changes on `dev` (gate 1 lists the ones that do not, as
  `differs` or `missing`). Backport them by PR into `dev` first, merge, and rerun.
- [ ] `.github/` is identical on both branches, or differs only by changes `dev` is about to ship (gate 2). Workflow and
  ruleset edits land through `dev` here, so a `dev`-ahead diff is the routine pre-release state; a `main`-ahead diff is
  a config change that reached only one branch and needs a decision.
- [ ] Gate 3 (lockfile resolution) SKIPs: this repo carries no `package-lock.json`, `bun.lock`, or `Cargo.lock`.

### Repo health (mirror CI locally)

The `.githooks/pre-push` hook runs the same `shellcheck`, `actionlint`, and `bats` suites as the `shellcheck.yml` and
`bats.yml` workflows. Run them explicitly before cutting the branch rather than discovering a failure mid-release.

- [ ] `scripts/lint-shell --all`, `scripts/lint-workflows --all`, and `scripts/run-tests --all` are clean; the simplest
  trigger is a no-op `git push` on `dev`.
- [ ] `markdownlint-cli2` clean on any prose docs in the release (the auto-format hook keeps this green during editing;
  confirm nothing slipped). `CHANGELOG.md` is the standing exception: the generator emits one logical line per bullet so
  GitHub soft-wraps it, which trips `MD013` on every section including the released ones. Hand-wrapping it to satisfy
  the linter would contradict "never hand-edit `CHANGELOG.md`", so the violations stay.

### Changelog completeness

The single highest-value config-only gate: every shipping PR must carry the changelog content the release notes depend
on.

- [ ] Every PR merged to `dev` since `$LAST_TAG` either has a non-empty `## Changelog` section or is intentionally empty
  (pure refactor / test / CI). Spot-check the borderline ones: `gh pr view <num> --json body`. A PR with no changelog
  content contributes its title as a `Changed` bullet unless the title is a `chore` / `ci` / `build` / `style` / `test`
  type.
- [ ] No shipping PR combines an *empty* `## Changelog` with a `chore`/`style`/`test`/`ci`/`build` title while actually
  shipping something user-facing. That pair is the only one `--from-dev-prs` drops: a body with changelog content is
  extracted whatever the title says, and the title is consulted only as the no-body fallback. Fix it by adding the
  bullets to the PR body (`gh pr edit <num> --body-file`), which is what the generator re-reads. A cherry-picked release
  is stricter — `git-cliff` drops those types before any body is fetched, so there the title itself has to be corrected
  (see [`RELEASES-RATIONALE.md` § CHANGELOG generation](./RELEASES-RATIONALE.md#changelog-generation)).

### Cross-platform deploy sanity

No CI runner exercises a real deploy onto both host classes (macOS workstation, headless Ubuntu). When the release
touches `stow/`, `scripts/stow-deploy`, `config/shell/`, or the git hooks, confirm a clean re-stow on at least one
deployed host:

- [ ] `scripts/stow-deploy --all` (or `--headless --all`) re-stows idempotently with no conflicts or adopted-file
  surprises on a host where the repo is already deployed.
- [ ] If the release changes shell config, a fresh login shell still meets the startup budgets (the `shell-config.bats`
  timing tests cover this; re-run if shell fragments changed).

### Release mechanics sanity

These duplicate steps in `RELEASES.md` deliberately: easy to skip, expensive to recover from. Confirm explicitly on the
cut `release/YYYY.MM.DD` branch, after the overlay is staged.

- [ ] Verification A agrees on scope: `git diff --cached --name-only origin/dev` filtered by the guarded set and
  `CHANGELOG.md` prints nothing. The filter is the guarded set, not all of `docs/`, since a directory that ships to
  `main` (`docs/runbooks/`) would hide a missed path.
- [ ] **Leak check before pushing the release branch.** No guarded path may surface in the diff vs `origin/main`. The
  set resolves from `.github/workflows/guard-main-docs.yml` via `scripts/release/guarded-paths.sh`; never restate the
  pattern inline.

  ```bash
  GUARDED="$(scripts/release/guarded-paths.sh)"
  git diff --cached --name-only origin/main | grep -E "$GUARDED" && echo "LEAKED: reset and redo" || echo "(clean)"
  ```

- [ ] **Every doc this release adds to `main` is meant to ship.** The leak check is blind to a category nobody
  registered. `git diff --cached --diff-filter=A --name-only origin/main | grep -E '(^docs/|\.md$)' | grep -Ev
  "$GUARDED"` lists the unguarded additions; each one needs a reason to ship, or it gets registered in the workflow's
  `extra_paths` and removed from the branch.
- [ ] `CHANGELOG.md` was regenerated with `scripts/generate-changelog.py --from-dev-prs` (not hand-edited), its top
  section is the branch's version, and it has no `[Unreleased]` placeholder.
- [ ] The branch date is today's, so CI's CalVer matches intent (CI recomputes from the date regardless, but a stale
  branch name is a smell worth catching).

### Prose floor

GitHub-bound text bypasses the in-repo formatter and needs a manual scrub before it ships.

- [ ] `CHANGELOG.md` and the release-PR body score `0` on `unslop`: `~/.claude/skills/unslop/scripts/score.py <file>`.
  Fix `CHANGELOG.md` findings at the source PR body, then regenerate; never hand-edit the changelog.

## Related docs

- [`RELEASES.md`](./RELEASES.md): operational runbook this checklist gates; post-tag verification is folded into its
  Tagging section.
- [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md): release-flow rationale.
- [`.github/pull_request_template.md`](.github/pull_request_template.md): PR body structure with changelog sections.
