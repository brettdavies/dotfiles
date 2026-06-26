# Pre-release verification: `dotfiles`

Operational pre-flight checklist. Runs **before** step 1 of
[`RELEASES.md` § Releasing dev to main](./RELEASES.md#releasing-dev-to-main). It gates the cut of the
`release/YYYY.MM.DD` branch, not daily dev integration. Each box is an explicit go/no-go — any unchecked or red item
holds the release.

This repo is config-only: no binaries, no registry, no cross-compile. The checklist is correspondingly short. CI catches
mechanical regressions inside the repo (`shellcheck`, `bats`); this checklist covers what CI structurally can't —
release scope, changelog completeness, the cross-platform deploy that no single runner exercises, and the prose floor on
GitHub-bound text.

Post-tag verification is folded into [`RELEASES.md` § Tagging and publishing](./RELEASES.md#tagging-and-publishing).

## Establish the surface

Everything below assumes you know what's shipping. Run this first.

```bash
LAST_TAG=$(git describe --tags --abbrev=0 origin/main)
git log --first-parent --grep='(#[0-9]\+)$' --format='%h %s' "$LAST_TAG..origin/dev"   # PR squashes going out
git diff "$LAST_TAG..origin/dev" --stat                                                 # file-level scope
git log "$LAST_TAG..origin/dev" --grep '^[a-z]\+!:' --oneline                           # breaking-change markers
```

Every `!:` commit gets a `### Changed` (or breaking) bullet in the release changelog.

## Checklist

### Repo health (mirror CI locally)

The `.githooks/pre-push` hook runs the same `shellcheck` and `bats` suites as the `shellcheck.yml` and `bats.yml`
workflows. Run them explicitly before cutting the branch rather than discovering a failure mid-release.

- [ ] `shellcheck` clean and `bats tests/*.bats` fully green — the simplest trigger is a no-op `git push` on `dev`, or
  run the suites directly (`bats tests/`).
- [ ] `markdownlint-cli2` clean on any docs in the release (the auto-format hook keeps this green during editing;
  confirm nothing slipped).

### Changelog completeness

The single highest-value config-only gate: every shipping PR must carry the changelog content the release notes depend
on.

- [ ] Every PR merged to `dev` since `$LAST_TAG` either has a non-empty `## Changelog` section or is intentionally empty
  (pure refactor / test / CI). Spot-check the borderline ones: `gh pr view <num> --json body`.
- [ ] No shipping PR's title was mistyped `chore`/`style`/`test`/`ci`/`build` while carrying user-facing `## Changelog`
  content — `cliff.toml` silently drops those bullets. Fix the PR title and re-amend the cherry-pick subject before
  generating the changelog (see
  [`RELEASES-RATIONALE.md` § CHANGELOG generation](./RELEASES-RATIONALE.md#changelog-generation)).

### Cross-platform deploy sanity

No CI runner exercises a real deploy onto both host classes (macOS workstation, headless Ubuntu). When the release
touches `stow/`, `scripts/stow-deploy`, `config/shell/`, or the git hooks, confirm a clean re-stow on at least one
deployed host:

- [ ] `scripts/stow-deploy --all` (or `--headless --all`) re-stows idempotently with no conflicts or adopted-file
  surprises on a host where the repo is already deployed.
- [ ] If the release changes shell config, a fresh login shell still meets the startup budgets (the `shell-config.bats`
  timing tests cover this; re-run if shell fragments changed).

### Release mechanics sanity

These duplicate steps in `RELEASES.md` deliberately — easy to skip, expensive to recover from. Confirm explicitly on the
cut `release/YYYY.MM.DD` branch.

- [ ] Triple-diff agrees on scope: `git diff origin/main..HEAD` (ship surface), `git diff HEAD..origin/dev` (no non-doc
  paths missed), `git diff origin/dev..origin/main` (phantom-commit sanity).
- [ ] Leak check returns nothing: `git diff origin/main..HEAD --name-only | grep -E
  '^(docs/plans|docs/brainstorms|docs/ideation|docs/research|docs/reviews|docs/solutions|\.context)'`. If cherry-picks
  pulled guarded paths in via rename detection, resolve per `RELEASES.md` § Cherry-pick conflicts on guarded paths.
- [ ] `CHANGELOG.md` was regenerated with `scripts/generate-changelog.py` (not hand-edited) and its top section has no
  `[Unreleased]` placeholder.
- [ ] The branch date is today's, so CI's CalVer matches intent (CI recomputes from the date regardless, but a stale
  branch name is a smell worth catching).

### Prose floor

GitHub-bound text bypasses the in-repo formatter and needs a manual scrub before it ships.

- [ ] `CHANGELOG.md` and the release-PR body score `0` on `unslop`: `~/.claude/skills/unslop/scripts/score.py <file>`.
  Fix `CHANGELOG.md` findings at the source PR body, then regenerate — never hand-edit the changelog.

## Related docs

- [`RELEASES.md`](./RELEASES.md) — operational runbook this checklist gates; post-tag verification is folded into its
  Tagging section.
- [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md) — release-flow rationale.
- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure with changelog sections.
