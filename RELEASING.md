# Releasing

This repo uses CalVer (`YYYY.MM.DD`) with the changelog-as-committed-artifact pattern. CHANGELOG.md is generated locally
on a release branch, committed to the PR, and the CI workflow extracts it for the GitHub Release body.

## Release Procedure

### 1. Create release branch from main

```bash
git fetch origin main
git checkout -b release/$(date +%Y.%m.%d) origin/main
```

### 2. Merge development to make individual commits visible

```bash
git merge origin/development
```

This brings all conventional commit messages into the release branch so git-cliff can categorize them.

### 3. Generate changelog

```bash
GITHUB_TOKEN=$(gh auth token) ~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh --tag $(date +%Y.%m.%d)
```

The script runs git-cliff for base entries, then expands squash commits using `## Changelog` sections from PR bodies.

Review the generated CHANGELOG.md before committing.

### 4. Commit and push

```bash
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG.md"
git push -u origin release/$(date +%Y.%m.%d)
```

### 5. Create PR to main

```bash
gh pr create --base main --title "release: $(date +%Y.%m.%d)" --body "Release $(date +%Y.%m.%d)"
```

### 6. Squash merge the PR

Merge via GitHub UI (main requires human approval for merges).

### 7. CI handles the rest

The release workflow (`release.yml`) automatically:

- Computes the CalVer version (handles same-day suffix: `YYYY.MM.DD.N`)
- Extracts release notes from the committed CHANGELOG.md
- Creates a git tag
- Creates a GitHub Release with the changelog content

No manual tagging needed.

## Key Differences from Bird/XUrl-rs

| Aspect | Bird/XUrl-rs | Dotfiles |
|--------|-------------|----------|
| Versioning | SemVer (`vX.Y.Z`) | CalVer (`YYYY.MM.DD`) |
| Tag prefix | `v` | none |
| Release trigger | Tag push (manual `git tag`) | Push to main (CI creates tag) |
| Branch detection | Auto from `release/vN.N.N` | Manual `--tag` override |
| Version bump | Cargo.toml | N/A (date-based) |
| Shell completions | Generated per release | N/A |

## Troubleshooting

**generate-changelog.sh can't detect version:** Always pass `--tag YYYY.MM.DD` explicitly. The script's branch detection
expects `release/vN.N.N` format which doesn't match CalVer.

**Empty changelog sections:** Ensure `cliff.toml` has `[remote.github]` with `owner` and `repo` for PR link expansion.
Ensure `GITHUB_TOKEN` is set (the script falls back to `gh auth token`).

**Unsigned commit errors when pushing release branch:** Release branches aren't protected by the development branch
ruleset. If push fails, check that your SSH signing key is configured.
