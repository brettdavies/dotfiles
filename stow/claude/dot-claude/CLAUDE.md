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
- Typography, fonts, type hierarchy, readability → invoke typeset
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

**During CE skill dispatches:** When `/ce-plan`, `/ce-ideate`, `/ce-code-review`, or `/ce-optimize` instructs you to
dispatch `compound-engineering:ce-learnings-researcher` (agent name as of CE v3.0.0 — was
`compound-engineering:research:learnings-researcher` in ≤2.68.x), ALSO dispatch the user-level
`qmd-learnings-researcher` (`~/.claude/agents/qmd-learnings-researcher.md`) in the same parallel batch with the same
query context. Merge both result sets — prefer qmd's findings where they disagree, since qmd's hybrid retrieval is
tolerant of the tag-vocabulary drift that defeats the plugin's grep pre-filter on the ~230-doc shared corpus. The plugin
agent still runs (it has a mandatory critical-patterns.md read that's worth keeping); the qmd agent catches what grep
misses. This is a local hack around
[compound-engineering-plugin#655](https://github.com/EveryInc/compound-engineering-plugin/issues/655) — remove this
directive once that lands upstream.

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
the symlink is missing, recreate it with a relative path (works on both macOS and Linux): `ln -s
../../dev/solutions-docs docs/solutions`

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

## Code Comments

**Default: write no comment.** Code earns clarity from naming, structure, and types — not prose. Only add a comment when
removing it would leave a non-obvious WHY unanswered for a future reader who lacks your conversation context.

**Legitimate reasons to comment** (the only ones):

- **Hidden constraint or invariant** the type system can't express.
- **Workaround for a specific upstream bug.** Link the upstream issue URL, not a local ticket slug.
- **Performance choice backed by data** (`O(1) lookup — benchmarked 3x faster than .find() at n>100`).
- **Magic value's origin** (`MAX_RETRIES = 3 // p99 transient failure rate from SLO dashboard`).
- **Surprising behavior** (null vs undefined, UTC-only handling, side effect the function name doesn't promise).
- **Business rule whose source isn't traceable from the call site.**

**Hard bans — never write these:**

- **Temporal or historical context.** No `refactored`, `previously`, `formerly`, `used to`, `legacy`, `was`,
  `originally`, `now uses`, `replaced with`, `improved`, `enhanced`, `new approach`, `old approach`. Git history holds
  change history; comments describe present state.
- **References to local-only artifacts.** No `see plan/X`, `see unit 10`, `from the Y handoff`, `per docs/plans/...`,
  `docs/brainstorms/...`, `.context/` paths, `TODO.md`, internal-only doc slugs. These files live only on the author's
  machine (per the "Never Commit Todo Files Or `.context/`" rule) — referencing them in code is guaranteed rot.
- **Task-flow references.** No `added for the X flow`, `used by Y`, `handles the case from issue #123`, `part of the
  auth refactor`. Belongs in the PR description.
- **Instructional voice.** No `use this instead of`, `copy this pattern`, `migrate to this`, `prefer this over`. Code
  stands on its own; comments document, they don't lecture.
- **Comparative claims about replaced code.** No `better than the previous`, `cleaner than the old`, `more efficient
  than before`. If the new code is better, the diff shows it.
- **Restating what the next code block does.** If the comment paraphrases the code it sits above — whether that's one
  line or several lines implementing a single conceptual operation — delete the comment or rename the symbol. A comment
  over a 5-line if-block that says only "Check if X exists" is restating just as much as the same comment over a single
  line. Section headers that label a *composite* block of distinct steps (parse-then-validate-then- normalize) are
  allowed; comments that paraphrase one operation across several lines are not.

**Stable external references ARE allowed** when durable enough to outlive several refactors and resolvable by someone
outside the team:

- RFCs (`per RFC 7231 §6.5.4`)
- CVEs (`CVE-2024-12345`)
- Public upstream issue URLs (`https://github.com/owner/repo/issues/N` in a third-party library)
- Vendor bug-tracker URLs, specification sections
- JIRA / Linear ticket IDs **when the project's tracker is the canonical record** for that requirement

**File headers:** none by default. Add a 1-2 line top-of-file comment only when the file's role isn't obvious from its
name and exports. No `ABOUTME:` convention unless the project already uses it.

**Refactoring rule:** preserve existing comments unless they're demonstrably wrong. Existing comments encode
institutional knowledge written for a reason. Don't strip context just because you're touching the file. Don't add a new
comment about the change itself — describe the resulting code's present state.

**Language conventions override the default** for documented public surface area, not for in-function code:

- **Rust** — `///` doc comments on public items (`pub fn`, `pub struct`, public modules). Required for `pub` items if
  the project enables `missing_docs`.
- **Python** — module / class / public-function docstrings. Format follows the project's choice (Google, NumPy, PEP
  257); never mix formats within one project. Type hints replace `:param:` / `:returns:` lines.
- **Go** — exported-identifier doc comments per Effective Go: first sentence starts with the identifier name.
- **TypeScript / JavaScript** — TSDoc only on public exports where signature isn't self-explanatory. Type annotations
  replace `@param` / `@returns` type info.
- **Ruby** — YARD comments on public methods of gems / libraries; not required for application code.
- **Bash** — function-level `#` block when the script is itself a tool (CLI surface); not required for ad-hoc scripts.

These conventions cover the documented surface only — comments inside function bodies still follow the default ("write
no comment unless WHY is non-obvious").

**Audit:** the [`code-comments` skill](~/.claude/skills/code-comments/SKILL.md) ships `scripts/scan.sh` to flag the
hard-banned patterns across changed files. Invoke `/code-comments` during code review or before commit. The skill also
holds the full pattern catalog (`references/forbidden-patterns.md`), per-language guides in
`references/languages/<lang>.md` (load only the language you need), and good/bad examples (`references/examples.md`).

---

## Supply-Chain Pinning: SHA pins, never version/tag pins

Always pin to immutable commit SHAs wherever a SHA can substitute for a mutable tag or version. This is a hard rule, not
a preference. Mutable refs (`@v4`, `@main`, `@latest`) can be force-moved to point at different code — a live
supply-chain attack surface (`tj-actions/changed-files`, March 2025).

**Where it applies:**

- **GitHub Actions `uses:`** — `uses: actions/checkout@<40-char-sha> # v4.2.2`. Trailing comment names the version so
  humans can read it at a glance; the pin itself is the SHA.
- **Reusable workflows** — `uses: owner/repo/.github/workflows/x.yml@<sha>`.
- **Docker images** — `FROM node@sha256:<digest>`, not `FROM node:20`.
- **Git submodules / subtrees** — full commit SHA.
- Anywhere else a mutable tag is normally accepted — choose the SHA.

**Exception — package managers with lockfiles:** npm / bun / cargo / pip version constraints in manifest files are fine
when a lockfile (`bun.lock`, `package-lock.json`, `Cargo.lock`, `uv.lock`) captures the integrity hash. The lockfile IS
the SHA. Do NOT try to replace `"react": "^18"` with a commit SHA — that breaks package managers.

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

- ✅ "the `account_id` field in `Cloudflare API Token - Wrangler (<server>)`"
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

## Personal paths and machine names: relative or generic in all written artifacts

The "Secrets and identifiers" rule above covers values from secret stores. This rule covers two broader categories that
frequently leak into commit messages, PR bodies, and docs without anyone noticing:

**Personally-identifying paths.** Any path containing a username (`/Users/<user>/...`, `/home/<user>/...`,
`/c/Users/<user>/...`) reveals the developer's local layout and identity. Replace with relative or environment-variable
forms. Examples:

- `/Users/<user>/dotfiles/...` → `~/dotfiles/...`
- `/home/<user>/.bun/bin` → `$HOME/.bun/bin`
- If you must show a path that the runtime stores absolutely (systemd `Environment=`, plist `PATH=`, etc.), substitute
  `$HOME` in the rendered text and note that the literal file expands it.

Standard-system absolute paths without identifying segments stay as-is: `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`, `/etc/...`, `/home/linuxbrew/.linuxbrew/bin` (Linuxbrew's install path is shared across all installations
and isn't PII).

**Machine and host names.** Don't reference internal hostnames (development boxes, home-network machines, Tailscale
magic DNS names, cloud-account labels) by their literal name in any written artifact. Use generic descriptors that
communicate the role. Examples:

- `<internal-hostname>`, `<internal-hostname>_wifi` → "the Linux server", "the deployed server", "the headless server",
  "this Mac" (Mac itself isn't identifying since every macOS dev box is "a Mac")
- Cloud account names, tenant identifiers, internal subdomains → describe by role

**Scope:** commit messages, PR titles and bodies, issue bodies, issue comments, release notes, docs in `docs/solutions/`
(which sync to a separate public repo), READMEs, plan files in `docs/plans/`, chat transcripts that may get pasted into
issues, retrospective notes. The 1Password entry name in the Cloudflare example above is itself written `(<server>)`,
not the literal hostname — the rule applies even to "harmless-looking" examples in docs.

**Exception — functional code and config:** SSH config entries, hostname-dependent scripts, systemd unit files that need
the literal `/home/<user>/` path because the runtime doesn't expand `$HOME`, and similar code that NEEDS the literal
value to function are fine. The rule applies to written artifacts about the code, not the code itself.

**How to apply:**

- Before submitting any commit message, PR body, or doc, scan the draft. A practical grep guard before `gh pr edit
  --body-file`:

  ```bash
  rg '/Users/[^/]+/|/home/[^/]+/|<your-known-hostnames>' /tmp/pr-body.md
  ```

  If anything fires, replace with relative or generic equivalents before submit.
- The `/unslop` skill doesn't detect these patterns yet — treat the guard above as your own pre-submit pass until it
  does.
- For solutions-docs entries (which ship to a public repo), the bar is the same as PRs: generic descriptors only.

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
- **rtk auto-rewrite hook:** A PreToolUse hook on Bash transparently rewrites supported commands (`git`, `cargo`, `gh`,
  `pytest`, `docker`, etc.) through [`rtk`](https://github.com/rtk-ai/rtk) for 60-90% token compression. Three meta
  commands are NOT auto-rewritten and must be invoked explicitly: `rtk gain` (savings analytics), `rtk discover` (find
  missed compression opportunities), `rtk proxy <cmd>` (run unfiltered for debugging). Idempotent — already-`rtk`
  commands pass through unchanged.
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

---

## CI monitoring is automated

After `git push`, `gh pr create`, `gh pr merge`, `gh release create`, `gh workflow run`, or any `gh api .../dispatches`
call, a PostToolUse hook (`~/.claude/ci-watch-prompt.sh`) enumerates currently-active workflow runs and injects a system
reminder listing each run id with the exact `gh run watch <id> --exit-status` command to spawn. Comply with the prompt:
spawn one Bash call per active run with `run_in_background: true` (in parallel), so the harness notifies you when each
finishes — no polling needed.

For PR-scoped checks (after `gh pr create`/`gh pr merge`), prefer `gh pr checks <pr> --watch` — it covers all checks
across all triggered workflows on the PR head in a single watcher.

After every batch of watchers finishes, re-run `gh run list --branch <branch>` to catch dispatched chains (e.g.
`release.yml` → homebrew dispatch → `finalize-release`). The hook only fires after the original action; chained runs
need a manual re-check.

If you push CI-triggering changes via a path the hook doesn't cover (or `gh` is unavailable in the hook's environment),
run the same flow manually. Never proceed past a red run.

The full policy and matcher list lives in the script header at `~/.claude/ci-watch-prompt.sh` — that's the source of
truth.

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

**Handoff documents** (multi-session kickoff prompts that brief a future agent on state-of-the-world before they pick up
work) live at `.context/handoffs/` and follow the CE plan filename convention:

```text
.context/handoffs/YYYY-MM-DD-NNN-<slug>-handoff.md
```

- `YYYY-MM-DD` is the date the handoff was written.
- `NNN` is a zero-padded per-day counter (`001`, `002`, …) so multiple handoffs on the same day sort deterministically.
- `<slug>` is a kebab-case topic identifier matching the unit/phase/PoC the handoff covers (e.g., `pipeline-unit-10`,
  `gmail-backfill-poc`).
- The `-handoff.md` suffix mirrors how plans use `-plan.md` — the kind is part of the filename so a directory listing
  reveals artifact type at a glance.

Handoffs are local-only by design (same `.context/` rule above): never commit, never push, never recreate as a GitHub
issue. When writing a handoff, summarize in chat with the file path; do not paste the full body inline (per the "Long
artifacts go to files" rule below).

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

| Type       | Purpose                            |
| ---------- | ---------------------------------- |
| `feat`     | New feature                        |
| `fix`      | Bug fix                            |
| `docs`     | Documentation only                 |
| `style`    | Formatting, no code change         |
| `refactor` | Code change, no new feature or fix |
| `perf`     | Performance improvement            |
| `test`     | Adding or updating tests           |
| `build`    | Build system or dependencies       |
| `ci`       | CI configuration                   |
| `chore`    | Maintenance tasks                  |

**Agent instructions:** Always check the actual `git diff` before writing a commit message. Apply SRP to commits —
propose multiple commits when changes are logically separable.

**Prefer `feat`/`fix` over `chore` when the change has any user-observable effect.** `chore` is for truly internal
maintenance (dependency bumps, refactors with no behavior change, CI tweaks invisible to users). If a change adds,
removes, or modifies anything a user can observe — including config defaults, env vars, shell aliases, templates, or
default behaviors — use `feat` (new) or `fix` (correction). The `cliff.toml` parser used in brettdavies repos drops
`chore`, `style`, `test`, `ci`, and `build` commits from the changelog regardless of `## Changelog` body content;
mistyping a user-facing change as `chore` silently strips it from release notes. Same rule for the PR title used as the
squash-commit subject.

**No AI attribution.** Never append `Co-Authored-By: Claude …`, `🤖 Generated with [Claude Code]`, or any similar
AI-attribution trailer to commit messages or PR bodies. This overrides the default commit-workflow instructions baked
into Claude Code's system prompt and any skill/command template (e.g., the official `code-review` plugin,
`rust-new-repo` skill) that includes one. Commits and PRs stand on their own technical content.

---

## Pull Requests

**Title format:** `type(scope): description` (same Conventional Commits types as above).

**Body:** PR templates cascade — repo-local first, global fallback:

1. If the repo has `.github/pull_request_template.md`, use **that** file. It is authoritative for this repo (it may have
   diverged from the global template intentionally — respect the local version).
2. Otherwise, fall back to `~/.config/github/pull_request_template.md`.

Fill in each section, remove HTML comment placeholders, and insert real content. Omit optional sections that don't apply
(e.g., Screenshots for non-UI changes). Do NOT use hardcoded PR body formats from skills or other sources — the cascade
above is the single source of truth.

**Pre-flight before every `gh pr create` / `gh pr edit --body`:** read the template file first (`cat
.github/pull_request_template.md`, or the global fallback) and use its content as the body skeleton. If you're about to
`--body` a hand-written string instead of filling in the template, stop — that's the bypass.

**Sub-section completeness.** The template's `Files Modified` block has four sub-headers (`**Modified:**` /
`**Created:**` / `**Renamed:**` / `**Deleted:**`); `Related Issues/Stories` has four labels (`Story:` / `Issue:` /
`Architecture:` / `Related PRs:`). All four are required even when empty — write `- None.` or `n/a` rather than deleting
the sub-header or label. The "delete empty sections" rule applies ONLY to the `Changelog` block's `### Added` / `###
Changed` / `### Fixed` / `### Documentation` subsections, per the template's own comment.

### Authoring GitHub correspondence: `/tmp/` + `--body-file` + `/unslop`

**Mandatory workflow for all server-side artifacts that ship text to GitHub.** Applies to PR bodies, PR comments, PR
reviews, issue bodies, issue comments, release notes, and any future `gh` command that takes a `--body` or `--notes`
flag. Also covers `git commit -m` (the squash-merge commit message lands in public history alongside the PR body).

Three steps. The first two are mandatory in every repo; the third is mandatory in every repo regardless of whether the
repo has its own prose-linting pipeline.

1. **Author in `/tmp/`.** Write the body to `/tmp/pr-body.md` (or `/tmp/commit-msg.md`, `/tmp/release-notes.md`, etc.).
   The auto-format hook (`md-wrap.py`) skips `/tmp/` paths, so the file keeps its authored shape — no 120-char wrapping
   inside prose. Write each paragraph and each bullet as **one logical line**; GitHub soft-wraps for display.
2. **Run `/unslop /tmp/<path>.md`.** The `unslop` skill (`~/.claude/skills/unslop/`) is required for every body before
   submission. It runs `scripts/score.py` as a deterministic gate, then recasts only the lines the script flags —
   em-dash density, formulaic structures ("It's not X, it's Y", "Here's the thing", etc.), filler openers, AI
   self-references, pseudo-profound openers. Score `0` exits silently; non-zero scores produce recast diffs the agent
   reviews. This rule is universal — even repos without Vale + LanguageTool wired up still run `/unslop` so the prose
   floor is in place.
3. **Submit via file flag.** `gh pr create --body-file /tmp/<path>.md`, `gh pr edit --body-file ...`, `gh pr comment
   --body-file ...`, `gh issue create --body-file ...`, `gh release create --notes-file ...`, `git commit --file ...`.
   Never inline the body via `--body "..."`, `-m "..."`, or a `--body "$(cat <<'EOF' ... EOF)"` heredoc.

Typical flow:

```bash
$EDITOR /tmp/pr-body.md             # author the body, one logical line per paragraph
/unslop /tmp/pr-body.md             # mandatory scrub pass
gh pr create --base dev --title "type(scope): description" --body-file /tmp/pr-body.md
```

**Why mandatory `/unslop`:** every repo benefits from the slop floor, even ones without the broader Vale + LT pipeline.
The Vale + LanguageTool + unslop *full stack* remains repo-local (currently `agentnative-skill`, `agentnative-cli`,
`agentnative-site`, `agentnative-spec` — see those repos' `RELEASES.md` "Prose scrubbing" sections). Repos without
Vale/LT still run `/unslop` as the minimum acceptable scrub.

**Enforcement.** The `~/.claude/heredoc-pr-guard.sh` PreToolUse Bash hook rejects `gh pr (create|edit|comment|review)
--body "<heredoc>"`, `gh issue (create|edit|comment) --body "<heredoc>"`, `gh release (create|edit) --notes
"<heredoc>"`, and `git commit -m "<heredoc>"`. The hook is wired into `stow/claude/dot-claude/settings.json` and runs on
every Bash tool call. Tests covering 41 cases (positive, negative, and adversarial red-team bypasses) live at
`tests/heredoc-pr-guard.bats` — run with `bats tests/heredoc-pr-guard.bats`. If a legitimate use is blocked, fix the
regex; do NOT bypass the hook for individual commands.

Why hook + docs (not docs alone): inline heredoc into `--body` produces wrapped-and-escape-trapped text that lands in
the PR body AND in the squash-merge commit message. Cleanup after the fact requires either re-submitting via
`--body-file` (acceptable) or a destructive `git history reword` + force-push to a protected branch (not acceptable).
~30 seconds of pre-submit `/tmp/` work avoids both.

**Heredoc escape rule (fallback for when `--body-file` is impractical).** If you still compose a body inline via `gh pr
create --body "$(cat <<'EOF' ... EOF)"`, the single-quoted delimiter (`<<'EOF'`) preserves the body **literally** — no
variable expansion, no backslash interpretation. Do NOT escape inner quotes, backslashes, or dollar signs. If the body
needs to render `"foo"`, write `"foo"` — not `\"foo\"`. The latter renders as literal backslash-quote in markdown AND
lands in the squash-merge commit message, where cleanup requires a destructive `git history reword` + force-push to a
protected branch. The `--body-file` approach above sidesteps this entire class of problem.

**`## Changelog` section is the changelog source of truth.** `generate-changelog.sh` extracts these categorized bullets
verbatim into CHANGELOG.md during release prep. Write for users, not developers:

- INCLUDE: new features, changed behavior, breaking changes, fixed bugs, new/removed config.
- EXCLUDE: internal refactors, test additions, code cleanup, CI changes, implementation details. Document those
  elsewhere in the PR body (Files Modified, Key Details, etc.) — NOT in `## Changelog`.
- If a PR has NO user-facing changes (pure refactor, test-only, CI-only), leave `## Changelog` empty or omit it.
- NEVER manually edit CHANGELOG.md — it is a generated artifact. Fix inputs (commit messages, PR descriptions,
  `cliff.toml`), not the output.

---

## Branch discipline

Code changes always go on a feature branch (`feat/...` or `fix/...`) cut from `dev`, then PR'd back. `dev` and `main`
receive code only via PR.

**Exception — plan/docs-only commits:** Edits to `docs/brainstorms/**`, `docs/ideation/**`, `docs/plans/**`,
`docs/research/**`, `docs/reviews/**`, `docs/solutions/**`, and similar planning-only docs commit directly to `dev`. No
feature branch, no PR. Plans are inert text — they don't ship. Feature-branch ceremony adds friction without reducing
risk.

**The exception is bounded by audience, not extension.** Markdown that ships verbatim to consumers — skill bundles
(`bundle/**.md`), top-level repo-facing files (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`,
`RELEASES.md`, `CHANGELOG.md`), in-repo runbooks an end user or agent reads at runtime — does NOT qualify for the
exception. Those are public-facing artifacts and go through the standard feature-branch + PR flow even though they're
"just markdown". The test is: would skipping review here put a typo, factual error, or stale instruction in front of a
consumer? If yes, PR.

Ambiguous cases (docs + code in the same change, or planning + shipped docs in the same change) → use a feature branch.
When a single logical change spans both audiences, prefer two commits: direct-push the planning bits, PR the
consumer-facing bits.

---

## Long artifacts go to files, not chat

When the user asks for a substantial artifact (detailed prompt, plan, spec, long code block, multi-section doc), write
it to a file with the Write tool. Summarize in chat in a sentence or two; do not paste the full content.

**Why:** Long artifacts in chat waste tokens on both sides, are harder to re-read, and usually get re-written to a file
anyway. Reading long output in terminal scrollback is worse than opening the file in an editor.

**How to apply:**

- Pick a sensible path (`~/.gstack/projects/<slug>/ceo-plans/` for repo-scoped planning artifacts; repo root for
  artifacts that belong with the code) or ask the user.
- Summarize in chat: what's in the file, where it lives, any caveats.
- If the user asks to see changes, show diffs. Never re-paste the whole file.
- Trigger threshold: ~30 lines or any multi-section structured document. Short snippets, single commands, or targeted
  diffs are fine inline.

---

## System configs go in dotfiles, not ad-hoc

Machine-level config files (AppArmor profiles, sysctl settings, udev rules, etc.) live in `~/dotfiles/` and deploy via
stow. Never solve a problem by writing one-off `sudo bash -c` files into `/etc/`.

**Why:** Reproducibility. Ad-hoc writes to `/etc/` are invisible to version control and forgotten on the next machine.
The dotfiles repo is the canonical source for machine provisioning.

**How to apply:** When a fix needs a system config file, the canonical location is `~/dotfiles/` with a stow target.
Document the fix in `docs/solutions/` (via `/compound`) pointing to the dotfiles location.
