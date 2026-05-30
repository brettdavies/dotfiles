# Supply-Chain Pinning: SHA pins, never version/tag pins

Detail behind the **Supply-chain pinning** rule in `~/.claude/CLAUDE.md`. The hard rule lives inline; this file holds
the full where-it-applies list, the tag→SHA resolution commands, and the audit script. Open it when editing GitHub
Actions workflows, Dockerfiles, submodules, or any place a mutable ref could substitute for a SHA.

Always pin to immutable commit SHAs wherever a SHA can substitute for a mutable tag or version. This is a hard rule, not
a preference. Mutable refs (`@v4`, `@main`, `@latest`) can be force-moved to point at different code — a live
supply-chain attack surface (`tj-actions/changed-files`, March 2025).

## Where it applies

- **GitHub Actions `uses:`** — `uses: actions/checkout@<40-char-sha> # v4.2.2`. Trailing comment names the version so
  humans can read it at a glance; the pin itself is the SHA.
- **Reusable workflows** — `uses: owner/repo/.github/workflows/x.yml@<sha>`.
- **Docker images** — `FROM node@sha256:<digest>`, not `FROM node:20`.
- **Git submodules / subtrees** — full commit SHA.
- Anywhere else a mutable tag is normally accepted — choose the SHA.

## Exception — package managers with lockfiles

npm / bun / cargo / pip version constraints in manifest files are fine when a lockfile (`bun.lock`, `package-lock.json`,
`Cargo.lock`, `uv.lock`) captures the integrity hash. The lockfile IS the SHA. Do NOT try to replace `"react": "^18"`
with a commit SHA — that breaks package managers.

## How to resolve a tag to a SHA

```bash
gh api repos/<owner>/<repo>/git/refs/tags/<tag> --jq '.object.sha'
# if the ref points at a tag object (annotated tag), dereference:
gh api repos/<owner>/<repo>/git/tags/<tag-object-sha> --jq '.object.sha'
# or simpler, resolve commit directly:
gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
```

**How to apply when updating:** resolve the new SHA explicitly rather than bumping the tag. Update the trailing comment
to match.

## Audit + auto-fix script

`~/.claude/skills/github-repo-setup/scripts/pin-actions.sh` — run in any repo to audit every workflow for unpinned
actions and (optionally) fix them to canonical SHAs shared across brettdavies repos. Also supports cross-repo alignment
mode (`--align dir1 dir2 …`) to catch drift when the same action is pinned to different SHAs across projects. The script
holds the authoritative pinned-SHA table — update there when bumping versions, then re-run across all repos.
