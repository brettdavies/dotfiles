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

## Exception — first-party reusable workflows

brettdavies-owned reusable workflows under `brettdavies/.github/.github/workflows/`, called from other brettdavies
repos, may pin to `@main` instead of a SHA. The threat the SHA pin defends against (someone with write access moves a
mutable ref to point at compromised code) doesn't apply when both the source repository and the consumer repository are
under the same control. Trust the source.

```yaml
# Acceptable for first-party reusables:
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main

# Required for third-party reusables and all GitHub Actions:
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
- uses: dtolnay/rust-toolchain@stable
```

`dtolnay/rust-toolchain@stable` is a separate documented exception in the `rust-tool-release` skill (trusted maintainer,
SHA pinning impractical because `stable` advances), not the same carve-out as first-party.

Third-party reusable workflows (anything not under `brettdavies/...`) still require SHA pins.

## Resolution-time aging window (cooldown)

Lockfiles protect a version *after* it has been resolved, not at the moment of resolution itself. The classic
supply-chain attack (compromise a maintainer's account, publish a malicious version, wait for any `bundle install` /
`npm install` / `uv add` that resolves a fresh dep to pick it up) slips in during that gap; the lockfile integrity hash
then pins the compromised artifact in place.

The mitigation is a minimum-age filter that refuses to resolve to a version until it has been public for N days
(brettdavies-fleet default: **7 days**, set centrally by `~/dotfiles/config/shell/supply-chain.sh` which exports the
right env var for every tool that has native support).

Native tool support (current as of the shell sourcing this file):

- **Bundler 4.0.13+ (RubyGems)** — `BUNDLE_COOLDOWN=7` (env) or `bundle config set cooldown 7` (persisted) or `source
  "https://rubygems.org", cooldown: 7` (in-Gemfile). Enforced during resolution (`bundle install` without a lockfile,
  `bundle update`); existing `Gemfile.lock` entries are honored as-is. `bundle outdated` annotates in-window versions
  with the days remaining before they become resolvable. Reference:
  <https://blog.rubygems.org/2026/06/03/cooldown-let-new-gems-be-vetted.html>.
- **uv 0.9.17+ (Python)** — `UV_EXCLUDE_NEWER="7 days"` (relative duration) or `tool.uv.exclude-newer = "<RFC3339>"` in
  `pyproject.toml`. Date-based rather than days-based; same intent.
- **pip 26.0+ (Python)** — `PIP_UPLOADED_PRIOR_TO="<RFC3339 timestamp>"`. No relative-duration support; the shell
  computes the timestamp dynamically (`date -u -d "7 days ago"`) so the env stays current per session.
- **npm 11.10.0+ (JS)** — `npm_config_min_release_age=7` (note key: `min-release-age`, days). Gated on version in the
  shell config because older npm warns ("Unknown env config 'min-release-age'") and npm 12 will hard-fail on unknown env
  configs.
- **pnpm 10.16.0+ (JS)** — `npm_config_minimum_release_age=<minutes>` (note key: `minimum-release-age`, minutes — *not*
  an alias for npm's days-based key, both are current). Same `npm_config_*` env namespace as npm, different leaf key.
- **yarn 4.6+ (JS)** — `YARN_NPM_MINIMAL_AGE_GATE=168h` (time-string form).
- **bun (JS)** — no env-var support. Configured via `~/.bunfig.toml` (`minimumReleaseAge`); the dotfiles repo stows the
  file at `stow/bun/dot-bunfig.toml`.

**No native cooldown support** for these tools — supply-chain risk is unmitigated at resolve time, and lockfile-level
pinning is the only defense:

- **cargo (Rust)** — no `min-release-age` analog. `cargo install --locked` honors `Cargo.lock` integrity, but a fresh
  `cargo add` resolves against the live crates.io index with no time gate.
- **Homebrew** — no formula cooldown. `brew install` fetches whatever the formula's `url`/`sha256` references at the
  moment of resolution.
- **Go modules** — no equivalent. `GOPROXY` + `go.sum` pin once resolved; no resolve-time delay.

**Emergency override** for actively-exploited 0-days where the freshest release IS the patch: each tool accepts a
one-off bypass — Bundler `--cooldown 0`, uv `--no-exclude-newer`, npm `--no-min-release-age`, pnpm
`--config.minimum-release-age=0`, yarn `YARN_NPM_MINIMAL_AGE_GATE=0`, pip `--ignore-uploaded-prior-to`. Use sparingly;
the policy should stay in place for the rest of the team.

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
