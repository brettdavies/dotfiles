---
title: "docs: cut the 2026.08.10 release and bring every root CAPITAL document to present truth"
date: 2026-08-10
status: implementation-ready
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
plan_type: docs
---

# docs: cut the 2026.08.10 release and bring every root CAPITAL document to present truth

## Summary

Two joined deliverables, in order. First, cut `release/2026.08.10` per the procedure in `RELEASES.md` — from `main`, not
from `dev`, cherry-picking the shipping commits oldest-first, then triple-diff, leak check, and generated
`CHANGELOG.md`. Second, on that same branch, bring all nine root CAPITAL-letter documents to present truth as direct
commits, then prove the claim with `scripts/docs-audit.py` rather than asserting it.

The doc pass slots **after** cherry-pick verification and **after** `CHANGELOG.md` generation, and **before** the first
push. Rationale, alternatives, and the loss-prevention step are in § Decisions.

## Prerequisites

| Prerequisite                                                                                                                     | Why it blocks                                                                                       |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [`2026-08-10-030-feat-capital-docs-drift-audit-plan.md`](./2026-08-10-030-feat-capital-docs-drift-audit-plan.md) merged to `dev` | `scripts/docs-audit.py` is the acceptance instrument for "100% up to date"                          |
| Feature 1 (repo-wide tool-declaration extraction, macOS side, deprecation sweep) merged to `dev`                                 | changes `stow/brew/Brewfile` and possibly `stow/`, which changes what README and BOOTSTRAP must say |
| Feature 2 (Linux server parity and Linux-only surfaces) merged to `dev`                                                          | same surfaces                                                                                       |
| `dev` green: `shellcheck` and `bats` passing, working tree clean                                                                 | `RELEASES-PREFLIGHT.md` § Repo health                                                               |

"After we have a steady state" means all four rows are satisfied and no further PRs are in flight against `dev`.

## Decisions

### D1 — The doc pass runs after cherry-pick verification and after CHANGELOG generation, before the first push

The user's instruction is explicit and load-bearing: the CAPITAL-file fixes are direct commits on the release branch.
Three mechanical constraints fix *where* in the documented sequence they go.

1. **`RELEASES.md`'s triple-diff must run against a pure cherry-pick tree.** Diff B is `git diff HEAD..origin/dev
   --name-only | grep -v '^docs/'` and its job is to prove no cherry-pick was missed. Doc edits made on the release
   branch before that diff runs show up in it as differences and turn a real signal into noise the operator has to
   explain away. Verify first, then edit.
2. **Doc commits are changelog-invisible by construction, so they cannot perturb the changelog either way.**
   `scripts/generate-changelog.py` builds the version section from PR bodies: `pr_numbers_from_section()` scrapes
   `(#NNN)` out of the git-cliff output, `aggregate_pr_entries()` fetches each PR body, and `rewrite_version_section()`
   **replaces the whole section** with those aggregated bullets. A direct commit has no PR number, so its git-cliff
   bullet is discarded during the rewrite. Ordering relative to generation is therefore free, and we take the ordering
   that keeps step 1's signal clean.
3. **Doing all doc commits before the first push means CI runs exactly once.** `shellcheck.yml` and `bats.yml` trigger
   on `pull_request` only — pushes to a branch with no open PR trigger nothing. Once the release PR exists every
   subsequent push re-runs both. Landing the doc commits pre-PR collapses that to one run.

### D2 — The doc commits stay separate, not squashed

`shellcheck` and `bats` are cheap and cannot fail on markdown-only changes, so the "squash to avoid CI churn" argument
does not apply once D1 puts every doc commit before the PR opens. SRP wins: one commit per coherent document group, each
with its own message describing what became true. Six doc commits plus the generated-changelog commit.

Signing is unaffected: `commit.gpgsign = true` is set globally and `.githooks/pre-commit` enforces it, so every
release-branch commit is signed regardless of count. `required_signatures` on `main` is satisfied by the squash merge
that GitHub creates.

### D3 — The backport to `dev` is mandatory, not optional

A fix committed only to a release branch that merges to `main` is clobbered the next time `dev` diverges. `RELEASES.md`
§ Backport to dev after release already anticipates this and says to check `git diff origin/dev..origin/main --
README.md RELEASES.md ...` and fold real release-prep changes into the same backport PR by hand. This plan promotes that
from "check" to a required unit (U9) with a hard exit assertion: after the backport merges, `git diff
origin/dev..origin/main` restricted to the nine files must be **empty**. Without U9 the whole doc pass is a single
release's worth of work with a one-release half-life.

### D4 — Direct (non-PR) commits on `dev` get triaged, not blanket-excluded

`RELEASES.md` step 3 says "Direct (non-PR) commits on dev are intentionally excluded", and `RELEASES-RATIONALE.md` § Why
pick only PR squash commits justifies it: direct commits are the planning-doc exception, which must not reach `main`.
That premise does not hold for the current unreleased range. Of the 12 direct commits since the last release sync, only
3 are planning docs. The rest carry shipping content — a new CLI under `stow/local/dot-local/bin/`,
`scripts/playwright-browsers-deploy.sh`, `config/shell/python.sh` and `config/shell/caches.sh` policy exports,
`stow/claude/dot-claude/` payload, and a `README.md` edit. A blanket exclusion silently drops working code from the
release and leaves `main` describing features it does not carry.

U2 therefore builds an explicit **cherry-pick ledger** with a triage rule, and U5 rewrites `RELEASES.md`,
`RELEASES-PREFLIGHT.md`, and `RELEASES-RATIONALE.md` to describe the triage — in present tense, as the procedure, not as
a change note.

### D5 — The cherry-pick range anchor in `RELEASES.md` is wrong and gets fixed

`RELEASES.md` step 2 and `RELEASES-PREFLIGHT.md` § Establish the surface both anchor on `LAST_TAG=$(git describe --tags
--abbrev=0 origin/main)` and then range over `"$LAST_TAG..origin/dev"`. Because `main` is built by cherry-pick, the tag
is **not an ancestor of `dev`**, so that range is dev's entire history. Measured on the current tree:
`2026.06.26..origin/dev` is 196 commits and yields **148** PR squashes. The correct anchor is the last release-sync
commit on `dev`, which `scripts/sync-dev-after-release.sh` creates with the subject `chore(release): sync dev after
<version>`. Anchored there, the range is 27 commits and yields **15** PR squashes — the actual unreleased surface.

```bash
LAST_SYNC=$(git log --first-parent --format='%H' -n 1 \
  --grep='^chore(release): sync dev after ' origin/dev)
```

Fallback when no such commit exists (a repo state predating `sync-dev-after-release.sh`): fall back to the tag and
triage the list by hand, which is what the current text silently assumes.

### D6 — What "100% up to date" means, and where the boundary is

Two tiers, stated per file in U5. Being explicit about the boundary is the point; a single "verified" verdict over nine
documents is not checkable.

- **Mechanical.** `scripts/docs-audit.py` (Plan 030) covers table/filesystem set equality, layout-tree path existence
  and coverage, package-list agreement with `scripts/stow-deploy`, numeric count claims, relative-link resolution,
  privacy patterns, and changelog generator-faithfulness. Exit `0` is the gate. This tier is a command; it either passes
  or names a file and line.
- **Execution replay.** For `RELEASES.md` and `RELEASES-PREFLIGHT.md` the release itself is the test. Every command
  block in those two documents is run (or dry-run) during U1–U8. A command whose output contradicts the prose is a
  defect fixed in U5. This is the strongest available verification and it costs nothing extra, because the release is
  happening anyway.
- **Evidence ledger.** For prose that no script can check — `CONCEPTS.md` definitions, `PROJECT.md` philosophy and stack
  table, `AGENTS.md` framing, `RELEASES-RATIONALE.md` "why" narratives, README's per-subsystem paragraphs — each claim
  gets a named evidence pointer (a file path plus the command that confirms it) recorded in the working ledger at
  `.context/` (local-only, never committed). A claim with no evidence pointer is rewritten or deleted. This tier is
  agent/human judgment and the plan says so rather than pretending otherwise.

### D7 — `CONCEPTS.md` and `PROJECT.md` are patched and extended, not rewritten

Both were checked against the repository during planning. `CONCEPTS.md`'s existing entries (Deployed dotfiles host,
Headless host, gbrain thin client, Stow package and its visibility classes, Encrypted package, Cross-package symlink,
System-level unit, Per-host override, Shell config chain, Bare launcher, Supply-chain age gate, and the Claude Code
session-pipeline entries) describe structures that still exist; the file's shape and altitude are right. It is missing
vocabulary that recent work introduced, not carrying wrong vocabulary. `PROJECT.md`'s structure is sound and its drift
is numeric and enumerative (a package-class list missing `gogcli`, counts to re-verify). Patch and extend both. A
rewrite would churn correct text and lose the accreted definitions.

`AGENTS.md` is the one file needing section-level rewrites rather than line edits — four of its sections assert things
that are no longer how the repo works. Still not a whole-file rewrite: its Stow, shell-chain, git-auth, and signing
sections check out.

---

## Guardrails

- **Present truth only.** These nine files are git-tracked documentation. Rewrite stale content into present tense; do
  not append change notes about it. No "previously", "legacy", "now uses", "we switched from", "this supersedes", no
  dated `Update:` notes. The one carve-out: `CHANGELOG.md`, and the release-history parts of `RELEASES.md`, are the
  designated homes for supersession language.
- **Never hand-edit `CHANGELOG.md`.** It is generated. Fix inputs — PR bodies, commit subjects, `cliff.toml` — and
  regenerate.
- Repo-relative paths only. No `/Users/<name>/`, no `/home/<name>/` (except the literal `/home/linuxbrew` prefix), no
  machine hostnames in any of the nine files. `BOOTSTRAP.md` currently violates this in its Linux server setup section;
  U5.2 fixes it.
- Every commit message and every GitHub body is authored in a `/tmp/` file, scrubbed with `/unslop`, and submitted via
  `git commit --file` / `--body-file`. Never inline `-m`, never a heredoc — a PreToolUse hook rejects it. Delete the tmp
  file with `trash` on success.
- Conventional Commits. Prefer `feat`/`fix` over `chore` for anything user-observable: `cliff.toml` drops `chore`,
  `style`, `test`, `ci`, and `build` entirely.
- No AI attribution in any commit message or PR body.
- Never `git add` any `TODO*.md` / `*todo*.md` variant or anything under `.context/`. The working ledger lives in
  `.context/` and stays there.
- `trash`, never `rm` / `git rm`. Guarded-path cherry-pick conflicts use the plumbing form documented in `RELEASES.md` §
  Cherry-pick conflicts on guarded paths: `git update-index --remove $(git diff --name-only --diff-filter=U)`.
- `rg` not `grep`, `fd` not `find`, `jaq` not `jq`.
- **`git log` output truncates in this environment.** Every enumeration command in U2 must pass an explicit `-n 500` or
  use `git rev-list`. A silently truncated list is a silently short release.
- The `gh` package tracks a git-crypt encrypted blob. Cherry-pick commits touching it without inspecting plaintext, and
  never reproduce any decrypted value in a commit message, PR body, or this plan.

---

## Unit 0 — Preflight

**Reads:** `RELEASES-PREFLIGHT.md`. **Writes:** nothing.

Walk `RELEASES-PREFLIGHT.md` end to end. Any unchecked item holds the release. While walking, record every instruction
that cannot be evaluated as written — those become U5.7/U5.8 defects.

### Verification

1. `bats tests/` fully green and `shellcheck` clean locally (the `.githooks/pre-push` hook mirrors both).
2. `markdownlint-cli2` clean across the repo.
3. `scripts/docs-audit.py` runs (it will report findings; that is expected and is the U5 work list).
4. Every PR merged to `dev` in the unreleased range has a non-empty `## Changelog` section or is intentionally empty.
   Spot-check with `gh pr view <num> --json body`.
5. No shipping PR title was mistyped `chore`/`style`/`test`/`ci`/`build` while carrying user-facing changelog content.
   Any that were: fix the PR title on GitHub **now**, before U2, so the cherry-picked subject can be amended to match.
6. `scripts/stow-deploy --all` (or `--headless --all`) re-stows idempotently on a deployed host.
7. Recorded: the list of preflight instructions that did not evaluate as written.

---

## Unit 1 — Cut the release branch

```bash
git fetch origin --tags
git checkout -b "release/$(date +%Y.%m.%d)" origin/main
```

Branch from `origin/main`, **not** `dev`. Branching from `dev` produces `add/add` conflicts whenever the two have
diverged, which is the post-squash-merge norm, and dragging `dev`'s history in via merge re-emits every previously
released commit into the changelog.

### Verification

1. `git rev-parse HEAD` equals `git rev-parse origin/main`.
2. `git rev-parse --abbrev-ref HEAD` is `release/2026.08.10` (or today's date if the cut slips; CI recomputes CalVer
   from the push date regardless, so the branch name is informational).
3. `scripts/generate-changelog.py --print-tag` prints `2026.08.10` — proves the branch name parses for the generator.
4. `git status --short` is empty.

---

## Unit 2 — Build the cherry-pick ledger and pick

**Writes:** `.context/release-2026.08.10-ledger.md` (local-only, never committed).

### Step 1 — Anchor the range

```bash
LAST_SYNC=$(git log --first-parent --format='%H' -n 1 \
  --grep='^chore(release): sync dev after ' origin/dev)
git rev-list --count "$LAST_SYNC..origin/dev"
```

### Step 2 — Enumerate both classes

```bash
git log --first-parent --grep='(#[0-9]\+)$' --format='%H %s' -n 500 "$LAST_SYNC..origin/dev"   # PR squashes
git log --format='%H %s' -n 500 "$LAST_SYNC..origin/dev"                                        # everything
```

The set difference is the direct-commit class.

### Step 3 — Triage every direct commit

Rule, applied per commit via `git show --stat <sha>`:

| Touches                                                                                                                      | Disposition                                                           |
| ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| only `docs/plans/`, `docs/brainstorms/`, `docs/ideation/`, `docs/research/`, `docs/reviews/`, `docs/solutions/`, `.context/` | exclude                                                               |
| any of `stow/`, `scripts/`, `config/`, `tests/`, `.github/`, `cliff.toml`, or a root CAPITAL document                        | include                                                               |
| a mix of both                                                                                                                | include, and resolve the guarded paths at pick time per `RELEASES.md` |

Record each commit, its disposition, and the reason in the ledger. Baseline measured during planning — re-derive at
execution time, because Features 1 and 2 land more commits before the cut:

- 27 commits in range, 15 PR squashes, 12 direct.
- Of the 12 direct: 3 are planning-doc-only (exclude); 9 carry shipping content (include), covering the Playwright
  browser-provisioning scripts and their `config/shell/caches.sh` exports, the Python cache-hygiene exports in
  `config/shell/python.sh`, a new CLI under `stow/local/dot-local/bin/`, several `stow/claude/dot-claude/` payload
  edits, an encrypted blob refresh under `stow/gh/`, and one `README.md` edit.

### Step 4 — Pick

Merge both classes into one chronological (oldest-first) list and cherry-pick. Each pick carries its conventional-commit
subject, which is what `git-cliff` categorizes on.

### Verification

1. The ledger accounts for **every** commit in `$LAST_SYNC..origin/dev` — `git rev-list --count` equals (included +
   excluded). No commit is unclassified.
2. `git log --oneline -n 500 origin/main..HEAD | wc -l` equals the included count.
3. `git ls-files docs/plans/ docs/brainstorms/` on the release branch lists nothing beyond what `origin/main` already
   carried (`git ls-tree -r --name-only origin/main docs/plans docs/brainstorms` is the baseline — historical files
   predating the guard are present on `main` and are out of scope for this release).
4. Every cherry-picked subject that arrived mistyped as `chore`/`style`/`test`/`ci`/`build` while carrying user-facing
   changelog content has been amended to `feat`/`fix`, matching the corrected PR title from U0 step 5.
5. `git status --short` is empty (no unresolved conflicts, no orphan worktree files).

---

## Unit 3 — Triple-diff and leak check

Run exactly as `RELEASES.md` § Releasing dev to main step 4 prescribes. Run it **before** any doc edit, so diff B is
uncontaminated.

```bash
git diff origin/main..HEAD --stat                                          # A: ship surface
git diff HEAD..origin/dev --name-only | rg -v '^docs/' || echo "(none)"    # B: no missed picks
git diff origin/dev..origin/main --stat | tail -5                          # C: phantom-commits sanity

git diff origin/main..HEAD --name-only \
  | rg '^(docs/plans|docs/brainstorms|docs/ideation|docs/research|docs/reviews|docs/solutions|\.context)' \
  && echo "LEAKED — reset and redo" || echo "(clean — no guarded paths)"

git cherry HEAD origin/dev | rg '^\+' || echo "(none — patch-equivalent through dev)"
```

### Verification

1. Diff A's file list matches the union of the ledger's included commits' file lists.
2. **Diff B is empty** apart from `docs/` paths. Under D4's triage this is a stronger assertion than the current
   `RELEASES.md` text supports: with direct commits included, there is no non-doc content on `dev` that is not on the
   release branch. A non-empty diff B is a missed pick — go back to U2.
3. The leak check prints `(clean — no guarded paths)`.
4. Every `+` line from `git cherry` is triaged per `RELEASES-RATIONALE.md` § Why the patch-id cherry-check output is
   noisy: `git show <sha> --stat`, then `git diff origin/main..HEAD -- <those files>`. Record each verdict in the
   ledger. A recent `feat`/`fix` whose file content is not on `main` is a real miss.
5. The whole of U3 is executed with the document open; any command that does not run as written, or whose output
   contradicts the surrounding prose, is written down as a U5.7 defect.

---

## Unit 4 — Generate `CHANGELOG.md`

```bash
GITHUB_TOKEN=$(gh auth token) scripts/generate-changelog.py
```

Review the generated top section against `gh pr view <num> --json body` for each cherry-picked PR. Then commit:

- Message file `/tmp/commit-msg-$(uuidv7).md`, subject `docs: update CHANGELOG.md`. That exact subject is skipped by
  `cliff.toml`'s first commit parser, which is why it must not be reworded.

### Verification

1. The top section is `## [2026.08.10]`, with no `[Unreleased]` placeholder.
2. Every cherry-picked PR with non-empty `## Changelog` content appears. Any that is missing is the `cliff.toml`
   chore-skip footgun: fix the PR title on GitHub, re-amend the cherry-picked subject, and regenerate. Do not edit
   `CHANGELOG.md`.
3. `~/.claude/skills/unslop/scripts/score.py CHANGELOG.md` scores `0`. A finding is fixed at the source PR body, then
   regenerated.
4. `GITHUB_TOKEN=$(gh auth token) scripts/generate-changelog.py --dry-run` exits `0` — regeneration is idempotent, which
   is the mechanical proof the file was not hand-edited.
5. `git diff --name-only HEAD~1..HEAD` is exactly `CHANGELOG.md`.
6. **Known and accepted:** the included direct commits contribute no changelog bullets, because
   `rewrite_version_section()` rebuilds the section from PR bodies and they have no PR. See Open Question 3.

---

## Unit 5 — The CAPITAL document pass

Nine sub-units, direct commits on the release branch, grouped into six commits. Each sub-unit states its verification
tier per D6. Run `scripts/docs-audit.py --json` first and treat its findings as the machine-generated work list; the
per-file notes below are the human-judgment additions the audit cannot produce.

Every message is authored in `/tmp/commit-msg-$(uuidv7).md`, `/unslop`-scrubbed, and committed with `git commit --file`.

### U5.1 — `README.md`

**Commit:** `fix(docs): align README with the repository as built`

**Mechanical:** rules `stow-table`, `stow-deploy-coverage`, `shell-fragments`, `layout-paths-exist`, `layout-coverage`,
`hooks-table`, `workflows-table`, `systemd-units`, `apparmor-profiles`, `local-bin`, `counts`, `links`, `privacy`. All
must report zero errors for `README.md`.

**Known drift (re-derive; Features 1 and 2 may add more):**

- Stow-package table is missing the `shell` row (33 rows against 34 packages).
- The outside-`--all` paragraph names `caddy` and `ollama` but omits `rust`, which is also absent from both
  `SHARED_PACKAGES` and `DESKTOP_PACKAGES`.
- The `local` row names 4 of 14 binaries in `stow/local/dot-local/bin/`. Nine user-facing CLIs are undocumented.
- The `claude` row omits `agents/`, `guides/`, and `CLAUDE.md` under `stow/claude/dot-claude/`.
- The `qmd` row's "Linux only" qualifier is wrong for `qmd-serve`, which also runs on macOS via
  `stow/launchagent/Library/LaunchAgents/com.user.qmd-serve.plist`.
- The `launchagent` row names no plists.
- The repo-layout tree omits `scripts/nightly-autocommit.sh`, `scripts/qmd-llama-rebuild.sh`,
  `scripts/rectangle-defaults.sh`, `scripts/setup_gogcli.sh`, `scripts/sync-dev-after-release.sh`, `scripts/tmux/`,
  `scripts/qmd-launchd/`, `snapshots/`, `cliff.toml`, `.markdownlint-cli2.yaml`, and
  `docs/progressive-disclosure-evals.md`.
- The test-suite prose in § CI and Testing does not reflect all 15 suites.
- The layout tree lists `docs/plans/` and `docs/brainstorms/`. Add a present-tense clause noting those directories are
  `dev`-side working areas that the release flow does not carry forward. Do not narrate that this changed.

**Judgment:** the per-subsystem prose (Playwright provisioning, tmuxinator, secrets, cross-platform notes, release
automation) is read against the code it describes; each claim gets an evidence pointer in the ledger.

### U5.2 — `BOOTSTRAP.md`

**Commit:** `fix(docs): correct bootstrap package lists and add missing setup prerequisites`

**Mechanical:** rules `bootstrap-stow-lists`, `links`, `privacy`.

**Known drift:**

- **Privacy violation.** The Linux server setup section embeds a machine hostname literal in two places. Replace with a
  role descriptor ("the Linux server"). The functional gate lives in `scripts/tailscale-serve-setup.sh` and keeps the
  literal — the rule is about written artifacts, not code. The `privacy` audit rule reads that literal out of the script
  at runtime, so this is machine-checkable.
- The two manual `stow --dotfiles ...` package lists diverge from `SHARED_PACKAGES` / `DESKTOP_PACKAGES`. Both lines
  omit `gbrain` and `codex-proxy`; the macOS line additionally omits `rclone`, `qmd`, `obsidian`, and
  `opendataloader-pdf`.
- No Playwright section. With `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` exported from `config/shell/caches.sh`, a fresh Linux
  machine that skips `scripts/playwright-browsers-deploy.sh` gets zero browsers. This is a hard new bootstrap
  requirement documented only in `README.md`.
- No step for the `unslop` wrapper's dependency: `stow/local/dot-local/bin/unslop` exits `127` unless the unslop skill's
  scoring script is installed and executable.
- No step for `transcribe-diarize` prerequisites (`ffmpeg`, a first-run model download, a token read from the password
  manager). Name the 1Password item by **location**, never the value.
- The QMD LaunchAgents table lists three agents; a fourth plist ships in the `launchagent` package and appears in
  neither the table nor `scripts/qmd-launchd-enable.sh`'s agent array. See Open Question 4 — the doc must describe the
  script's real behavior, so if the gap is not closed in code, the table stays at three and stops implying completeness.

**Judgment:** the `gem install bundler` step, the oh-my-zsh plugin discussion, and the Ghostty/Cursor/Rectangle sections
are re-read against the files they reference.

### U5.3 — `AGENTS.md`

**Commit:** `fix(docs): align AGENTS.md with the repository as built`

**Mechanical:** rules `hooks-table`, `systemd-units`, `apparmor-profiles`, `links`, `privacy`.

**Known drift:**

- The `pre-push` row says "Chains Git LFS pre-push". `.githooks/pre-push` mirrors CI (shellcheck plus bats) and skips
  markdown-only pushes. `README.md` states this correctly; `AGENTS.md` contradicts it.
- "Current units" omits `config/systemd/system/apparmor-playwright.service`.
- The GitHub Actions section prescribes syncing `main` into `dev` via a UI merge or hand-picked commits, and never names
  `scripts/sync-dev-after-release.sh`, which is the script that performs it.
- The Branch Workflow section says `dev` is merged to `main` when ready. The flow is `dev` → `release/*` cherry-pick
  branch → PR to `main`. Rewrite to match `RELEASES.md`; keep it short and link rather than duplicate.
- Shell Script Conventions covers error prefixes only. The repo is normalized to `shfmt -i 2 -ci -bn` and `shfmt` is
  declared in `stow/brew/Brewfile` for the auto-format hook. State the standard.
- The Reference section omits `PROJECT.md` and the three release documents.
- The deployment-context framing says "thousands of headless Ubuntu servers". The fleet is one headless Ubuntu server
  plus the macOS workstation. See Open Question 5 — recommendation is to state the real shape and keep the fleet-grade
  automation requirements, which stand on their own.
- `scripts/stow-deploy` performs post-restow systemd `--user` timer recovery; the "add a new package" section should say
  so, because it is behavior a contributor adding a timer-bearing package depends on.

### U5.4 — `CONCEPTS.md` and `PROJECT.md`

**Commit:** `docs: refresh PROJECT and CONCEPTS against the current repository shape`

**Mechanical:** rules `counts`, `links`, `privacy`.

**`PROJECT.md` known drift:**

- The package-class enumeration omits `gogcli` and must be re-derived from `stow/` after Features 1 and 2 land.
- "34 stow packages" and "21 shell environment fragments" are re-verified by the `counts` rule rather than by eye.
- The Technical Stack and Engineering Practices tables are read against the repo; every row needs a pointer.

**`CONCEPTS.md`:** patched and extended per D7. Verify each existing entry against the code it describes, then add
vocabulary that recent work introduced and that other documents already lean on. Candidates, each added only if it has
project-specific meaning that a dictionary would not give:

- **Release branch** and **guarded path** — used throughout the release trio, defined nowhere.
- **Shared browser cache** — the single `PLAYWRIGHT_BROWSERS_PATH` that makes per-repo browser installs a no-op.
- **Shared-clone commit** — the isolated-worktree commit path that keeps concurrent agents off one shared index.
- **Prose gate** — the deterministic score-then-recast step every GitHub-bound body passes.

Write each as a definition in present tense. Do not add an entry that merely restates a filename.

### U5.5 — `RELEASES.md`

**Commit:** `fix(docs): correct the release cherry-pick range anchor and direct-commit triage` (shared with U5.6 and
U5.7)

**Verification tier:** execution replay. Every command block in this document is executed during U1–U8.

**Known drift:**

- The step-2 range anchor is wrong (D5). Replace `LAST_TAG` with the `LAST_SYNC` derivation, keep the tag fallback, and
  say why the tag is not an ancestor of `dev`.
- Step 3's "Direct (non-PR) commits on dev are intentionally excluded" is false as a blanket rule (D4). Replace with the
  triage table from U2 step 3.
- § Branch protection says `protect-main.json` has "No required status checks (shellcheck/bats are advisory on main)".
  `.github/rulesets/protect-main.json` contains a `required_status_checks` rule with `shellcheck` and `bats` contexts
  and `strict_required_status_checks_policy: true`. Correct the text and add the consequence: the release branch must be
  current with `main` before the PR can merge.
- Any command in the document that did not run as written during U1–U4 or U7–U9.

### U5.6 — `RELEASES-RATIONALE.md`

**Same commit as U5.5.**

**Verification tier:** every "why" must correspond to a rule that still exists in `RELEASES.md` after U5.5, and every
rule in `RELEASES.md` that a reader could reasonably want to change must have a "why" here. Walk it as a two-way
mapping.

**Known drift:**

- § Branch protection repeats the false "advisory on main" claim.
- § Why pick only PR squash commits needs the D4 rationale: the filter is a correctness gate only while direct commits
  are confined to planning docs, so the triage exists to catch the case where they are not.
- § CHANGELOG generation should state that direct commits contribute no bullets, since `rewrite_version_section()`
  rebuilds the section from PR bodies. That is the mechanism behind Open Question 3 and readers hit it blind today.
- This file's declared purpose is rationale, not change history. The supersession carve-out does **not** apply here;
  write the rules as they stand.

### U5.7 — `RELEASES-PREFLIGHT.md`

**Same commit as U5.5.**

**Verification tier:** execution replay. This checklist is walked in U0 and again where U3/U4 duplicate it.

**Known drift:**

- § Establish the surface carries the same wrong `$LAST_TAG..origin/dev` anchor (D5).
- No checkbox for the direct-commit triage (D4).
- Every instruction recorded in U0 step 7 as not evaluating as written.
- The § Documentation accuracy gate from Plan 030 arrives by cherry-pick; confirm it survived and reads correctly in
  context.

### U5.8 — `CHANGELOG.md`

**No commit in U5.** Handled entirely by U4. Listed here so the nine-file surface is complete and so the "do not
hand-edit" rule is explicit at the point where a doc pass would be tempted to touch it.

**Verification:** `scripts/generate-changelog.py --dry-run` exits `0` at the end of U5, proving no doc-pass commit
touched it. `git log --format='%H %s' -n 50 origin/main..HEAD -- CHANGELOG.md` shows exactly one commit, U4's.

### Verification for Unit 5 as a whole

1. `scripts/docs-audit.py` exits `0` on the release branch HEAD. This is the acceptance instrument.
2. `markdownlint-cli2` clean on all nine files.
3. `rg -n '/Users/|/home/(?!linuxbrew)' AGENTS.md BOOTSTRAP.md CHANGELOG.md CONCEPTS.md PROJECT.md README.md RELEASES.md
   RELEASES-PREFLIGHT.md RELEASES-RATIONALE.md` returns nothing.
4. The host literal read from `scripts/tailscale-serve-setup.sh` appears in none of the nine files (the `privacy` rule
   covers this; run it standalone as a second check).
5. `scripts/docs-audit.py --strict` reports no `temporal` findings outside `CHANGELOG.md` and `RELEASES.md`'s
   release-history sections — the present-truth rule, mechanically.
6. `git log --format='%s' -n 20 origin/main..HEAD` shows six doc commits plus U4's changelog commit, every subject
   Conventional Commits shaped, none carrying an AI-attribution trailer (`git log --format='%b' -n 20 origin/main..HEAD
   | rg -i 'co-authored-by: claude|generated with'` returns nothing).
7. The evidence ledger in `.context/` has a pointer for every judgment-tier claim. Claims without one were rewritten or
   removed.
8. `git status --short` is empty; nothing under `.context/` or `todos/` is staged.

---

## Unit 6 — Re-verify the ship surface after the doc pass

Re-run U3's diffs now that the doc commits exist, so the final surface is understood before it is pushed.

### Verification

1. `git diff origin/main..HEAD --name-only` is exactly: the ledger's included file set, plus `CHANGELOG.md`, plus the
   nine CAPITAL files that changed. Nothing else.
2. The leak check still prints `(clean — no guarded paths)`.
3. `git diff HEAD..origin/dev --name-only | rg -v '^docs/'` now lists the changed CAPITAL files and nothing more. Those
   are the U9 backport payload — confirm the list matches what U9 will copy back.
4. `scripts/generate-changelog.py --dry-run` exits `0`.

---

## Unit 7 — Push and open the release PR

```bash
git push -u origin "release/$(date +%Y.%m.%d)"
```

The `.githooks/pre-push` hook runs `shellcheck` and `bats`; the push carries cherry-picked non-markdown content, so the
markdown-only skip does not apply and the full local suite runs. That is the intent.

PR body: `/tmp/pr-body-dotfiles.release-2026.08.10.md`, filled from `.github/pull_request_template.md`, `/unslop`-ed to
score `0`, submitted with `--body-file`, then `trash`ed.

```bash
gh pr create --base main --title "release: 2026.08.10" --body-file /tmp/pr-body-dotfiles.release-2026.08.10.md
```

Body constraints from `RELEASES.md` § PR body: no explainer prose, no workflow recap, **zero verification artifacts** —
no triple-diff stats, no leak-check output, no patch-id counts, no CI status. Summary describes the net diff only.
`Related Issues/Stories` and `Files Modified` keep all four sub-labels even when empty (`- None.`). Changelog
subsections carry 1–5 bullets each and empty ones are deleted.

### Verification

1. The push succeeded and the local pre-push suite was green.
2. `gh pr checks <pr> --watch` run in the background. A completed watcher is not a green watcher.
3. `gh pr view <num> --json statusCheckRollup,mergeStateStatus --jq '{merge: .mergeStateStatus, checks:
   [.statusCheckRollup[] | {name, conclusion}]}'` — every conclusion is `SUCCESS`, `mergeStateStatus` is not `BEHIND`.
   `strict_required_status_checks_policy` is true on `main`, so `BEHIND` means rebase onto `origin/main` and re-push.
4. `~/.claude/skills/unslop/scripts/score.py` on the PR body scored `0` before submission.
5. The tmp body file was deleted with `trash` after a successful `gh pr create`.
6. `gh pr view <num> --json body --jq .body | rg -i 'co-authored-by: claude|generated with'` returns nothing.

---

## Unit 8 — Merge, tag, publish

Squash-merge (the only method `protect-main.json` allows). The push to `main` triggers `release.yml`, which computes the
CalVer version, extracts release notes from the topmost `## [version]` section of the committed `CHANGELOG.md`, tags,
and publishes.

### Verification

`RELEASES.md` § Tagging and publishing is the checklist:

1. `release.yml` green end to end. `gh run watch <id> --exit-status`, then `gh run view <id> --json conclusion --jq
   .conclusion` returns `success`.
2. `git fetch --tags && git describe --tags --abbrev=0 origin/main` returns `2026.08.10` (or a `.N` suffix if today
   already had a tag).
3. `gh release view "$(git describe --tags --abbrev=0 origin/main)"` shows the extracted notes, not the `"Release
   <version>"` fallback. An empty body means the changelog section was empty.
4. Re-enumerate for chained runs: `gh run list --branch main`. Never proceed past a red run on any link.
5. `git diff origin/main -- <the nine files>` from the release branch is empty — `main` carries the corrected docs.

---

## Unit 9 — Mandatory backport to `dev`

Without this the doc pass is lost the next time `dev` diverges (D3).

```bash
scripts/sync-dev-after-release.sh "$(git describe --tags --abbrev=0 origin/main)"
```

The script copies `CHANGELOG.md` verbatim from `origin/main` onto `chore/sync-dev-after-<version>` and opens a PR to
`dev`. It refuses to run on a dirty tree or before the GitHub Release is published, and is idempotent.

Then fold the nine files into that same PR, which is what `RELEASES.md` § Backport already prescribes for release-prep
doc polish:

```bash
git checkout chore/sync-dev-after-<version>
git checkout origin/main -- AGENTS.md BOOTSTRAP.md CONCEPTS.md PROJECT.md README.md \
  RELEASES.md RELEASES-PREFLIGHT.md RELEASES-RATIONALE.md
git diff --cached --stat            # review before committing
```

Commit with `git commit --file /tmp/commit-msg-$(uuidv7).md`, subject `fix(docs): backport the 2026.08.10 documentation
pass to dev`. Push, then squash-merge.

**Safety note.** The straight `git checkout origin/main -- <files>` is only safe because D4's triage put every shipping
direct commit onto the release branch, so `main`'s copy of each file is a superset of `dev`'s. Verify that before
committing: `git diff origin/dev origin/main -- <the nine files>` must show only the U5 corrections, never a
disappearance of content that exists on `dev` and not on `main`. If it shows a disappearance, a direct commit was missed
in U2 — stop and reconcile file by file instead.

### Verification

1. The backport PR's changed files are exactly `CHANGELOG.md` plus the CAPITAL files that changed. Nothing else.
2. `gh pr checks <pr>` green; confirmed via `statusCheckRollup`, not via watcher completion.
3. After merge: `git fetch origin` then `git diff origin/dev..origin/main -- AGENTS.md BOOTSTRAP.md CHANGELOG.md
   CONCEPTS.md PROJECT.md README.md RELEASES.md RELEASES-PREFLIGHT.md RELEASES-RATIONALE.md` is **empty**. This is the
   exit assertion for the whole plan.
4. `scripts/docs-audit.py` exits `0` on `origin/dev`. That is the precondition for Plan 030's Open Question 1 follow-up
   (flipping the bats test to enforcing).
5. `git log --format='%b' -n 10 origin/dev | rg -i 'co-authored-by: claude|generated with'` returns nothing.

---

## Sequencing

```text
Plan 030 merged to dev ─┐
Feature 1 merged to dev ─┼─→ U0 preflight → U1 cut → U2 ledger + pick → U3 verify
Feature 2 merged to dev ─┘                                                  ↓
                                        U9 backport ← U8 merge/tag ← U7 push/PR ← U6 re-verify ← U5 doc pass ← U4 changelog
```

U5 must not start before U3 completes (D1, constraint 1). U7 must not start before U5 completes (D1, constraint 3). U9
must not start before U8 verifies the GitHub Release published — the script refuses otherwise.

## Cross-feature dependencies

Features 1 and 2 land before U0 and change surfaces this plan documents. Do not hardcode today's content as the target.
Reconcile at execution time:

| Their change                                                | What it moves here                                                                                                                                                                                                          |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stow/brew/Brewfile` entries added or removed               | `BOOTSTRAP.md` § Install Packages from Brewfile prose; any CAPITAL doc naming a specific tool                                                                                                                               |
| a new or removed `stow/` package                            | `README.md` Stow-package table and layout tree; `BOOTSTRAP.md` manual stow lists; `PROJECT.md` count and class list — all four are covered by audit rules `stow-table`, `layout-coverage`, `bootstrap-stow-lists`, `counts` |
| a new or removed `config/shell/` fragment                   | `README.md` § Shell Environment table (`shell-fragments` rule); `PROJECT.md` fragment count (`counts` rule)                                                                                                                 |
| a new `scripts/` entry                                      | `README.md` layout tree (`layout-coverage` rule)                                                                                                                                                                            |
| a **deprecation sweep** removing a tool a CAPITAL doc names | **not** covered by any audit rule — a removed brew formula is not a repo path. Manual reconciliation: `rg -n '<tool>' <the nine files>` for every tool their sweep removes                                                  |
| their PRs' `## Changelog` sections                          | flow into `CHANGELOG.md` through U4; U0 step 5's chore-mistype check applies to their PR titles                                                                                                                             |

The last row is the only real gap and it is called out so it is not discovered late.

## Acceptance criteria

- [ ] `release/2026.08.10` was cut from `origin/main`, verified by `git rev-parse` against `origin/main` at cut time.
- [ ] Every commit in `$LAST_SYNC..origin/dev` is classified in the ledger as included or excluded, with a reason.
- [ ] Triple-diff and leak check ran on a pure cherry-pick tree and were clean; diff B was empty of non-doc paths.
- [ ] `CHANGELOG.md` was produced by `scripts/generate-changelog.py`, was never hand-edited, and `--dry-run` exits `0`
  both immediately after generation and after the doc pass.
- [ ] All nine CAPITAL files verified, each with the stated tier: mechanical (`docs-audit.py`), execution replay
  (release trio), or evidence ledger (prose).
- [ ] `scripts/docs-audit.py` exits `0` on the release branch HEAD **and** on `origin/dev` after the backport.
- [ ] No `/Users/`, `/home/<name>/`, or machine hostname in any of the nine files.
- [ ] No temporal narration outside `CHANGELOG.md` and `RELEASES.md`'s release-history sections.
- [ ] Release PR merged with every check `SUCCESS`; `release.yml` `success`; tag and GitHub Release published with real
  notes.
- [ ] `git diff origin/dev..origin/main` over the nine files is **empty** after the backport merges.
- [ ] No AI-attribution trailer in any commit or PR body produced by this plan.

## Open questions (recorded, not blocking)

1. **Should the "dev-direct exception" be tightened?** Twelve direct commits in one cycle, nine of them shipping code,
   is what made D4's triage necessary. Recommendation: a follow-up PR narrowing `RELEASES.md` § Dev-direct exception to
   planning docs only and adding a `.githooks/pre-commit` guard that refuses a direct `dev` commit touching `stow/`,
   `scripts/`, `config/`, or `tests/`. Out of scope here — it is a policy plus code change and belongs in its own PR.
2. **Should `.claude/settings.local.json` be removed from `main`?** It is tracked on `main` and untracked on `dev`. The
   cherry-pick that untracked it is in the unreleased range, so the release should carry the deletion through. Verify in
   U6 that `git ls-tree origin/main .claude` and the post-merge equivalent agree with intent.
3. **Direct-commit work is invisible to `CHANGELOG.md`.** `rewrite_version_section()` rebuilds the version section from
   PR bodies, so the Playwright provisioning, the Python cache-hygiene exports, and the new CLI ship without release
   notes. Options: (a) accept and note it — recommended, since fabricating a PR reference or attributing bullets to an
   unrelated PR is worse; (b) extend the generator to keep git-cliff bullets for commits with no PR. Option (b) is a
   real improvement and a separate PR.
4. **macOS `qmd serve` has no enable path.** A plist ships in the `launchagent` package but is absent from
   `scripts/qmd-launchd-enable.sh`'s agent array and from `BOOTSTRAP.md`. This is a code gap, not a doc gap — the doc
   must describe the script as it behaves. Recommendation: fix the script in its own PR before the cut so `BOOTSTRAP.md`
   can document four agents; otherwise document three and drop any implication of completeness.
5. **`AGENTS.md`'s "thousands of headless Ubuntu servers".** The real fleet is one headless Ubuntu server plus the macOS
   workstation. Recommendation: state the real shape and keep every automation requirement, which is justified by the
   headless constraint rather than by count. If the number is deliberate aspiration, say so as a design constraint in
   present tense rather than as a fact about the fleet. Flagged rather than decided because it is the author's framing
   to set.
6. **Historical guarded-path files on `main`.** `main` carries `docs/plans/` and `docs/brainstorms/` files from before
   the guard existed, one of whose filenames embeds a machine hostname. The leak check only inspects the incoming diff,
   so they persist. Cleaning them up is a separate PR to `main` and is out of scope for this release.
