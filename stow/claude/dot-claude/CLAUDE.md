# Global User Instructions

## Development Workflow: gstack + compound-engineering

Two skill sets are installed. gstack owns ideation, planning, shipping, and operations. compound-engineering (CE) owns
the code loop. Use both, in this order:

```text
IDEATION + PLANNING (gstack)
  /office-hours        — brainstorm, validate the idea
  /autoplan            — CEO + eng + design review pipeline
    or: /plan-ceo-review, /plan-eng-review, /plan-design-review

IMPLEMENTATION (compound-engineering)
  /ce-plan             — implementation plan from repo patterns
  /ce-work             — execute with quality gates
  /ce-review           — 14+ persona agent code review
  /ce-compound         — document in docs/solutions/

SHIPPING + OPERATIONS (gstack)
  /ship                — PR, changelog, release
  /investigate         — root cause debugging
  /learn               — persist learnings across sessions
  /retro               — weekly retrospective
  /cso                 — security audit
```

For the full routing table and decision guide, see `~/.claude/skills/docs/workflow-routing.md`.

When the user's request matches an available skill, ALWAYS invoke it using the Skill tool as your FIRST action. Do NOT
answer directly, do NOT use other tools first. The skill has specialized workflows that produce better results than
ad-hoc answers.

Key routing rules:

- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review

**$100 Rule:** When prevention was missed and a bug or regression slips through, invest in the permanent fix — add a
test, a guard, a lint rule, or a docs/solutions entry. The cost of fixing later always exceeds the cost of fixing now.

**Trivial work exemption:** Single-file fixes, config tweaks, typo corrections, and similar changes that touch fewer
than ~20 lines may skip the full loop. Use judgment.

**Query solutions first:** Before answering questions, diagnosing issues, researching options, or proposing changes, run
`qmd query "<topic>" --collection solutions` to surface existing decisions and patterns. Solutions contain hard-won
decisions that cannot be inferred from the file layout alone. This applies to all interactions — questions, debugging,
code review, and architecture discussions — not just implementation.

---

## Shared Solutions Repo

`docs/solutions/` in every repo is a symlink to `~/dev/solutions-docs` — a separate private git repo
(`brettdavies/solutions-docs`). This centralizes all compounded solutions so the learnings-researcher agent can search
across all repos from any working directory.

**After writing to `docs/solutions/`** (e.g., via `/compound`), you MUST commit and push in the shared repo:

```bash
cd ~/dev/solutions-docs && git add -A && git commit -m "docs: <description>" && git push
```

The consuming repo's `git status` will show nothing for `docs/solutions/` because the symlink target is gitignored. If
the symlink is missing, recreate it: `ln -s ~/dev/solutions-docs docs/solutions`

---

## Core Coding Principles

- **DRY (Don't Repeat Yourself):** Avoid duplicating logic or data; abstract and reuse code where possible.
- **STAR (Single Truth, Authoritative Record):** Ensure shared types, constants, and config live in a single place;
  always import, never duplicate.
- **SRP (Single Responsibility Principle):** Each module, class, or function should have exactly one responsibility or
  reason to change.
- **KISS (Keep It Simple, Stupid):** Prioritize simplicity in code and design; avoid unnecessary complexity.
- **YAGNI (You Aren't Gonna Need It):** Don't add features or abstractions until they are necessary.
- **Fail Fast:** Catch missing environment variables or invalid states at startup whenever possible.
- **Explicit is Better:** Prefer clear, type-safe code and explicit imports over magic or implicit behaviors.
- **200-Line Refactor Trigger:** Any single file exceeding 200 lines of code (excluding comments) should trigger a
  refactor review to evaluate splitting responsibilities into smaller, focused modules. Files containing uniform
  functions (e.g., API shortcuts) or pure declarations (e.g., clap derives) may exceed this threshold and remain
  idiomatic — evaluate by SRP, trigger by line count.

---

## Supply-Chain Pinning: SHA pins, never version/tag pins

Always pin to immutable commit SHAs wherever a SHA can substitute for a mutable tag or version. This is a hard rule,
not a preference. Mutable refs (`@v4`, `@main`, `@latest`) can be force-moved to point at different code — a live
supply-chain attack surface (`tj-actions/changed-files`, March 2025).

**Where it applies:**

- **GitHub Actions `uses:`** — `uses: actions/checkout@<40-char-sha> # v4.2.2`. Trailing comment names the version so
  humans can read it at a glance; the pin itself is the SHA.
- **Reusable workflows** — `uses: owner/repo/.github/workflows/x.yml@<sha>`.
- **Docker images** — `FROM node@sha256:<digest>`, not `FROM node:20`.
- **Git submodules / subtrees** — full commit SHA.
- Anywhere else a mutable tag is normally accepted — choose the SHA.

**Exception — package managers with lockfiles:** npm / bun / cargo / pip version constraints in manifest files are
fine when a lockfile (`bun.lock`, `package-lock.json`, `Cargo.lock`, `uv.lock`) captures the integrity hash. The
lockfile IS the SHA. Do NOT try to replace `"react": "^18"` with a commit SHA — that breaks package managers.

**How to resolve a tag to a SHA:**

```bash
gh api repos/<owner>/<repo>/git/refs/tags/<tag> --jq '.object.sha'
# if the ref points at a tag object (annotated tag), dereference:
gh api repos/<owner>/<repo>/git/tags/<tag-object-sha> --jq '.object.sha'
# or simpler, resolve commit directly:
gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
```

**How to apply when updating:** resolve the new SHA explicitly rather than bumping the tag. Update the trailing comment
to match.

**Audit + auto-fix script:** `~/.claude/skills/github-repo-setup/scripts/pin-actions.sh` — run in any repo to audit
every workflow for unpinned actions and (optionally) fix them to canonical SHAs shared across brettdavies repos. Also
supports cross-repo alignment mode (`--align dir1 dir2 …`) to catch drift when the same action is pinned to different
SHAs across projects. The script holds the authoritative pinned-SHA table — update there when bumping versions, then
re-run across all repos.

---

## Secrets and identifiers: never echo, refer by location

When handling any value pulled from a secret store (`op`, `gh secret`, `printenv`, `aws ssm`, etc.), refer to it by
**location** or **name** — never reproduce the literal value in chat, commit messages, PR descriptions, summaries, or
retrospectives.

This applies uniformly to formal secrets (API tokens, passwords, keys) AND to identifiers the user took any step to keep
private (account IDs, tenant IDs, internal URLs). The "not formally a secret" carve-out does not exist at the echo
boundary — if the user routed it through `op` or a GitHub secret, they have a reason, and reproducing the value defeats
the intent regardless of formal classification.

Examples:

- ✅ "the `account_id` field in `Cloudflare API Token - Wrangler (bigdaddy)`"
- ✅ "piped from 1Password to `gh secret set CF_ACCOUNT_ID`"
- ❌ "set `CF_ACCOUNT_ID` to `<the literal value>`"
- ❌ in a retrospective: "I echoed `<literal>` in my summary" — repeats the leak

**The retrospective trap:** when acknowledging a prior leak, the reflex is to quote the leaked value to show what
happened. Don't. Name the field, describe the location, or use `<the value>` / `<the ID>` as a placeholder. Quoting a
leak while owning it re-leaks it.

**How to apply:**

- Before echoing any value returned by `op`, `gh secret`, `printenv`, `scripts/read_field.sh`, or similar, ask: would I
  be comfortable with this in a public gist or training transcript? If not, use the name.
- In commit / PR bodies, describe the change referentially: "rotated `CF_ACCOUNT_ID`", not "set `CF_ACCOUNT_ID` to X".
- In retrospectives or debug logs that discuss a leaked value, never re-quote it. Reference it by name.
- Reflex rule, no exceptions. The chat transcript is not the trust boundary you think it is.

---

## CLI Tool Preferences

- **Priority order for installing CLI tools:** brew > bunx/uvx > python3/node (last resorts only).
- **ALWAYS use CLI tools via Bash over built-in tools.** This overrides Claude Code's default preference for
  Read/Edit/Grep/Glob. The built-in tools are fallbacks, not defaults. Concrete rules:
- **Searching code:** `rg` (via Bash), not Grep. `ast-grep` for structural matches.
- **Searching files:** `find` or `fd` (via Bash), not Glob.
- **Reading files:** `cat`, `head`, `tail`, `bat` (via Bash), not Read. Exception: Read for images/PDFs.
- **Editing files:** `sed`, `awk`, or in-place CLI utilities (via Bash), not Edit. Exception: Edit for surgical
  single-line replacements where `sed` addressing would be fragile.
- **Writing files:** heredoc with `cat` or `tee` (via Bash), not Write. Exception: Write for new files where the entire
  content is being generated.
- **JSON processing:** `jaq` (via Bash), not manual parsing.
- **Refactoring:** `ast-grep` or `sed` with find, not Edit with replace_all.
- CLI tools produce better output for review, compose with pipes, and match how this user works. When in doubt, reach
  for Bash.
- **File deletion:** `trash` (via Bash), never `rm` or `git rm` (both denied in `settings.json`).
- **Knowledge base search:** use [`qmd`](https://github.com/tobi/qmd) to search the Obsidian vault, solutions-docs, and
  skills collections. Always use `qmd query` (hybrid, ~10s) as the default — it combines BM25 + vector + LLM re-ranking
  and produces significantly better results than `qmd search` alone. Prefer multiple focused queries with 2-3 terms each
  over one query with many terms. Always search qmd before researching from scratch — check solutions and vault for
  prior art.
- **Auto-format hook:** A PostToolUse hook wraps markdown prose to 120 characters (`md-wrap.py`) then runs
  `markdownlint-cli2 --fix`. Do NOT manually wrap markdown lines — the hook handles it. Do NOT use `mdformat`, `pandoc`,
  or `prettier` for markdown formatting.
- **GitHub CLI auth:** `gh` uses OAuth (not a fine-grained PAT) for interactive use. This allows creating issues, PRs,
  and forks on any public repo. Do NOT run `gh auth login --with-token` — use the default `gh auth login` OAuth flow.
  Fine-grained PATs are only for CI/CD (`CI_RELEASE_TOKEN` in GitHub Actions).
- When uncertain what CLI tools are available, you can enumerate installed tools with the following commands:
- `brew list` to list installed Homebrew CLI tools
- `pipx list` to list Python-based CLI utilities
- `bun pm ls -g` to list globally installed Bun packages
- If a needed tool is missing, ask the user to install it.
- **Rust pre-push checks:** Every Rust repo has `scripts/hooks/pre-push` which mirrors CI (fmt, clippy `-Dwarnings`,
  test, cargo-deny, Windows compat). Activated via `git config core.hooksPath scripts/hooks` (run once after clone). The
  hook runs automatically on `git push`; if it fails, fix the issues before pushing.
- **After pushing or creating a PR:** Monitor CI in the background with `gh run watch --exit-status` (use
  `run_in_background: true`). Continue working — you'll be notified on completion. If CI fails, investigate and fix
  before moving on.

---

## Never Commit Todo Files Or `.context/`

Todo files (`TODO`, `TODO.md`, any `*todo*.md` variant) and the `.context/` directory are **local-only by design** in
every repo. The global `.gitignore` excludes them on purpose. They hold multi-session work-in-progress (e.g., the
`compound-engineering/todos/` workflow under `.context/`) that must not leave the author's machine.

**Hard rules:**

- Never `git add` these paths, even if they appear untracked in `git status`.
- Never use `git add -f` to override the gitignore on these paths — the refusal is the system working correctly.
- Never re-create a local todo as a GitHub issue (or vice versa) as a substitute; they are different tools with
  different lifecycles.
- When a user invokes `/todo-create` or similar, write the file to its canonical local location
  (`.context/compound-engineering/todos/`) and stop there — no commit, no push.
- When staging broadly (`git add pdf-generator/` etc.), verify nothing inside `.context/` or any `TODO*.md` got swept
  in.

---

## Commit Messages

Always use Conventional Commits. Reference `~/.claude/templates/commit-message.md` for the full specification and agent
  workflow instructions.

**Quick reference:**

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

| Type | Purpose |
|------|---------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, no code change |
| `refactor` | Code change, no new feature or fix |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `build` | Build system or dependencies |
| `ci` | CI configuration |
| `chore` | Maintenance tasks |

**Agent instructions:** Always check the actual `git diff` before writing a commit message. Apply SRP to commits —
  propose multiple commits when changes are logically separable.

---

## Pull Requests

**Title format:** `type(scope): description` (same Conventional Commits types as above).

**Body:** Read `~/.claude/templates/pull-request.md` and fill in each section. This template is the single source of
  truth for PR structure — do NOT use hardcoded PR body formats from skills or other sources. Remove HTML comment
  placeholders and fill in real content. Omit optional sections that don't apply (e.g., Screenshots for non-UI changes).

**`## Changelog` section is the changelog source of truth.** `generate-changelog.sh` extracts these categorized bullets
  verbatim into CHANGELOG.md during release prep. Write for users, not developers:

- INCLUDE: new features, changed behavior, breaking changes, fixed bugs, new/removed config.
- EXCLUDE: internal refactors, test additions, code cleanup, CI changes, implementation details. Document those
  elsewhere in the PR body (Files Modified, Key Details, etc.) — NOT in `## Changelog`.
- If a PR has NO user-facing changes (pure refactor, test-only, CI-only), leave `## Changelog` empty or omit it.
- NEVER manually edit CHANGELOG.md — it is a generated artifact. Fix inputs (commit messages, PR descriptions,
  `cliff.toml`), not the output.
