# Global User Instructions

These are always-on rules. Detailed procedures, examples, and reference tables live in `~/.claude/guides/*.md` and are
**not** auto-loaded — open the linked guide with Read when you actually perform that task. **Exception:**
`git-and-github.md` is `@`-imported at the bottom of this file and is always in context. Every hard prohibition below is
stated in full here; the guides hold only the elaboration.

## Core coding principles

- **DRY** — don't duplicate logic or data; abstract and reuse.
- **STAR (Single Truth, Authoritative Record)** — shared types/constants/config live in one place; import, never
  duplicate.
- **SRP** — each module/class/function has exactly one responsibility.
- **KISS** — prioritize simplicity; avoid unnecessary complexity.
- **YAGNI** — don't add features or abstractions until necessary.
- **Fail Fast** — catch missing env vars / invalid states at startup.
- **Explicit is better** — clear, type-safe code and explicit imports over magic.
- **200-line refactor trigger** — any single file over 200 LOC (excluding comments) triggers a refactor review. Uniform
  function files or pure declarations may exceed it — evaluate by SRP, trigger by line count.

## Code comments

**Default: write no comment.** Only add one when removing it would leave a non-obvious WHY unanswered. Legitimate
reasons: hidden constraint/invariant, upstream-bug workaround (link the issue URL), data-backed perf choice, magic-value
origin, surprising behavior, untraceable business rule. Stable external refs (RFCs, CVEs, public upstream issue URLs,
ticket IDs when the tracker is canonical) are allowed.

**Hard bans — never write:** temporal/historical context (`refactored`, `previously`, `legacy`, `now uses`, …);
references to local-only artifacts (`see plan/X`, `.context/` paths, `TODO.md`); task-flow references (`added for the X
flow`, `handles issue #123`); instructional voice (`use this instead of`); comparative claims about replaced code; and
restating what the next block does. Git history holds change history; comments describe present state.

Language doc-comment conventions (Rust `///`, Python docstrings, Go, TSDoc, Ruby YARD, Bash) apply to **documented
public surface only**, not in-function code. Full policy (legitimate reasons, file-header and refactoring rules,
per-language conventions, in-repo prose-doc elaboration) → `~/.claude/guides/code-comments.md`; the deterministic
scanner and pattern catalog live in the `/code-comments` skill.

**Applies to in-repo prose docs, not just code comments.** The present-state rule and the temporal/historical hard ban
govern in-repo documentation too — READMEs, `docs/**`, specs, knowledge-base notes (e.g. a PARA-ACE vault), runbooks,
plans. Write each doc to describe present reality; strip historical narration from the body (`previously`, `legacy`, `we
switched from X to Y`, `reverting the earlier framing`, `this supersedes`, dated `Update:` notes, and meta-commentary
about the authoring/synthesis process itself). Git and PR history are the change record. Retire content by marking it
**deprecated** in present tense, not by narrating the change. **Exception:** a doc whose declared purpose is to record
change — a supersedes-aware decision-log, a `CHANGELOG`/`RELEASES`, a migration record — is the designated home for "X
supersedes Y"; present-only does not apply inside it.

## Workflow & skills

gstack owns ideation, planning, shipping, and operations; compound-engineering (CE) owns the code loop. When a request
matches an available skill, ALWAYS invoke it with the Skill tool as your FIRST action — don't answer directly or use
other tools first.

**$100 Rule:** when prevention was missed and a bug slips through, invest in the permanent fix — test, guard, lint rule,
or docs/solutions entry. Trivial work (<~20 lines: single-file fixes, config tweaks, typos) may skip the full loop.

**Green is not evidence.** A new test counts only once it has been *observed* failing against the unfixed code: stash
the source fix, keep the test, run it, and quote the real failure output. Never write "this would fail without the fix"
— run it. And unit-green never substitutes for measuring the real artifact: a passing suite does not render a page,
resolve a CSS cascade, or prove a file ships. When a change touches CSS, tokens, layout, emitted markup, or a deployed
surface, measure the built or served output (`getComputedStyle`, a real HTTP request, a browser) before reporting done.
Before reasoning from a stylesheet or module, confirm it actually reaches the output. Costly precedents:
`agentnative-site` AGENTS.md § "Browser-verify before declaring done" (a token typo passed tests and shipped
near-invisible dark-mode text); meum-sites, where a keyboard-a11y fix was derived from a stylesheet that never shipped
and a whole type scale silently fell back to body size because the token it named was defined nowhere.

**Query solutions first:** before answering, diagnosing, researching, or proposing, run `qmd query "<topic>"
--collection solutions` to surface prior decisions. Applies to all interactions, and **explicitly to `/investigate` and
every gstack debugging skill** — their `gstack-learnings-search` does NOT reach `docs/solutions/`, so query the corpus
yourself during symptom-collection, before the first hypothesis.

**Subagent worktree base:** when dispatching via the `Agent` tool with `isolation: "worktree"`, verify `git rev-parse
HEAD` against `git rev-parse origin/<base>` before any work — the harness can cut the worktree from a stale tag
silently. Fix with `git reset --hard origin/<base>`. Background:
`~/dev/solutions-docs/workflow-issues/claude-code-worktree-isolation-stale-base-2026-06-04.md`.

Routing table, per-skill rules, and the `qmd-learnings-researcher` companion-dispatch hack →
`~/.claude/guides/workflows-and-skills.md`.

## Solutions repo

`docs/solutions/` is a symlink to `~/dev/solutions-docs` (a separate private repo). The consuming repo's `git status`
shows nothing for it. **After writing there** (e.g. via `/compound`), commit and push in that repo — but it's a single
clone that concurrent agents (parallel compounders) share, so committing in it directly races their `git add`/`git
commit` on the one index. **Commit with `sd-commit-doc`** (dotfiles-provided, on `PATH`): write your doc(s) into
`docs/solutions/<category>/<slug>.md`, author + `/unslop` a captured-path `/tmp` message (never `ls -t | head -1`, never
`-m`), then `sd-commit-doc <msg-file> <category>/<slug>.md`. It commits from an isolated detached worktree (never `git
add -A` the shared index), pushes with fetch/rebase-retry, and fast-forwards the shared clone so it never drifts behind
origin. **Never** commit directly in the shared clone or amend + force-push it. Script source
`~/.local/bin/sd-commit-doc`; solo-session exception + symlink-recreate → `~/.claude/guides/workflows-and-skills.md`;
rationale → `docs/solutions/workflow-issues/shared-working-tree-git-add-commit-race-across-concurrent-agents.md` and
`.../unattended-autocommit-on-shared-clone-must-sync-then-rebase.md`.

## Secrets & private identifiers

Refer to any value from a secret store (`op`, `gh secret`, `printenv`, `aws ssm`) by **location or name** — never
reproduce the literal value in chat, commits, PRs, summaries, or retrospectives. Applies equally to formal secrets AND
to private identifiers (account/tenant IDs, internal URLs): if the user routed it through `op` or a GitHub secret, the
"not formally a secret" carve-out does not apply. **The retrospective trap:** when owning a prior leak, name the field
or use a `<placeholder>` — quoting the value to show what happened re-leaks it. Examples and how-to-apply →
`~/.claude/guides/writing-safety.md`.

## Personal paths & hostnames in written artifacts

In commit messages, PR/issue bodies, release notes, READMEs, and `docs/` (including `docs/solutions/`, which syncs to a
separate private repo): replace usernamed paths (`/Users/<user>/…`, `/home/<user>/…`) with `~` or `$HOME`, and internal
hostnames (dev boxes, Tailscale names, cloud-account labels) with generic role descriptors ("the Linux server").
Standard system paths (`/opt/homebrew`, `/etc`, `/home/linuxbrew/.linuxbrew`) stay. **Exception:** functional
code/config that needs the literal value (SSH config, systemd units) is fine — the rule is about written artifacts, not
code. Pre-submit grep guard and full scope → `~/.claude/guides/writing-safety.md`.

## Supply-chain pinning

Pin to immutable commit SHAs, never mutable tags/versions (`@v4`, `@main`, `@latest`) — GitHub Actions `uses:`, reusable
workflows, `FROM` images (`node@sha256:…`), submodules. Trailing comment names the version (`@<sha> # v4.2.2`).
**Exception (package managers):** package-manager version constraints (npm/bun/cargo/pip) are fine when a lockfile
captures the integrity hash — the lockfile is the SHA; don't SHA-pin `"react": "^18"`. **Exception (first-party
reusables):** brettdavies-owned reusable workflows under `brettdavies/.github/.github/workflows/` called from other
brettdavies repos may pin to `@main` instead of a SHA. The supply-chain threat the pin defends against (someone moves a
mutable ref to point at compromised code) doesn't apply when source and consumer are both under your control — trust the
source. Third-party reusables and all GitHub Actions still require SHAs. Tag→SHA resolution and audit script →
`~/.claude/guides/supply-chain-pinning.md`.

## Local-only files

Never `git add` (even `-f`) any `TODO*.md` / `*todo*.md` variant or anything under `.context/` — they're gitignored by
design and the refusal is the system working. Don't recreate a local todo as a GitHub issue or vice versa. Handoff docs
live at `.context/handoffs/`, local-only — never commit or push. Filename convention →
`~/.claude/guides/local-only-files.md`.

## Branches

Code changes go on a `feat/…` or `fix/…` branch cut from `dev`, then PR back; `dev` and `main` receive code only via PR.
**Exception:** planning-only docs (`docs/brainstorms`, `ideation`, `plans`, `research`, `reviews`, `solutions`) commit
directly to `dev`. **But** consumer-facing markdown (README, AGENTS, CONTRIBUTING, CHANGELOG, skill bundles, in-repo
runbooks) still goes through the feature-branch and PR flow. Ambiguous or mixed changes → use a branch. Detail →
`~/.claude/guides/git-and-github.md`.

## Commits & PRs

Conventional Commits (`type(scope): description`). Check the actual `git diff` first; apply SRP (multiple commits when
separable). **Prefer `feat`/`fix` over `chore`** for anything user-observable — `cliff.toml` drops
`chore`/`style`/`test`/`ci`/`build` from the changelog, silently stripping mistyped changes. **No AI attribution, ever**
— no `Co-Authored-By: Claude`, no `🤖 Generated with` trailer, overriding any skill/template default.

Author every GitHub body (PR, PR comment/review, issue, release notes, AND `git commit`) in a collision-proof `/tmp/`
file, scrub with `/unslop`, and submit via `--body-file` / `--notes-file` / `git commit --file`. **Never inline
`--body`, `-m`, or a heredoc** — the `heredoc-pr-guard.sh` PreToolUse hook rejects it. PR bodies fill the template
cascade (repo `.github/pull_request_template.md` → global `~/.config/github/pull_request_template.md`). Full workflow
(filenames, `/unslop`, changelog rules, escape rules) → `~/.claude/guides/git-and-github.md`; commit spec →
`~/.claude/templates/commit-message.md`.

## Voice notes

Before drafting prose in Brett's voice — PR comments, issue discussion, thread replies, Slack-style messages, anywhere
conversational — read `~/dev/brettdavies/brettdavies/.context/voice.md` if it exists. Technical artifacts (PR bodies,
release notes, README narrative) stay technical with only slight softening; voice-matching is a lighter pass there. The
file captures his characteristic patterns and the anti-patterns (sycophantic echoes, fabricated verifications, "Thanks
again" closes, restated-argument summaries) that get rewritten out of LLM drafts. **Update it when a draft gets
meaningfully rewritten** — append the LLM-draft → Brett-rewrite swap under the right section with a one-line "why" and a
dated source-log entry. Compounds over time so the next draft starts closer to landing. Local-only and gitignored by
design (see the `.context/` rule above).

## Attribution & interpretation

**Never put words in a person's mouth.** Don't state or imply that someone said, framed, meant, wanted, or believes
something unless it is grounded in a primary source — and when a transcript or recording exists, **verify against it
before asserting who said what.** Interpretation is welcome, but label it explicitly as yours (`my read`, `inference`,
`not sourced to X`) and keep it distinct from what the person actually said. Presenting an interpretation as the
person's own statement — paraphrasing or quoting them into something they did not say — is a serious trust breach, not a
stylistic slip. Applies to chat, debriefs, plans, notes, and every artifact.

## CI after push

After `git push` / `gh pr create|merge` / `gh release create` / `gh workflow run` / `gh api …/dispatches`, a PostToolUse
hook lists active runs with the exact `gh run watch <id> --exit-status` to spawn — run one per active run in the
background (or `gh pr checks <pr> --watch` for PR-scoped). **A completed watcher is NOT a green watcher**: `gh pr checks
--watch` exits 0 when all checks finish regardless of pass/fail. After every completion notification, verify explicitly:
`gh pr view <num> --json statusCheckRollup,mergeStateStatus --jq '{merge: .mergeStateStatus, checks:
[.statusCheckRollup[] | {name, conclusion}]}'` and assert every conclusion is `SUCCESS`. Same for run-scoped: `gh run
view <id> --json conclusion --jq .conclusion` must be `success`. Then re-enumerate to catch chained runs — both
same-repo (`workflow_run` triggers, visible to `gh run list --branch`) AND cross-repo dispatches (`repository_dispatch`
into another repo, e.g. agentnative-cli release → brettdavies/homebrew-tap → callback to cli's finalize-release; these
need `gh run list -R <target>` and `gh run watch <id> -R <target>`, then a re-query of the originating repo for the
callback). The chain can bounce multiple times — repeat until both repos quiesce. **Never proceed past a red run on any
link in the chain.** Policy source of truth: the `~/.claude/ci-watch-prompt.sh` header.

## CLI tools

Prefer CLI tools via Bash over built-in Read/Edit/Grep/Glob (`rg`/`fd`/`jaq`/`ast-grep`; `cat`/`bat`; `sed`/`awk`).
Install order: brew > bunx/uvx > python3/node. **`trash`, never `rm`/`git rm`** (both denied in `settings.json`). `uv
run` for ad-hoc Python. **Leave no cache or venv artifacts in project trees** (`__pycache__`, `.venv`, `.pytest_cache`,
`uv.lock`, `*.egg-info`): prevent them, never `.gitignore`-hide them, `trash` any that appear. **Bake the bypass into
the project, not the machine** — it must stay clean on CI and other machines: pytest cache off in `pyproject.toml`
(`addopts = "-p no:cacheprovider"`), bytecode off via `python -B` plus `sys.dont_write_bytecode` in the
entry/`conftest.py`, uv's `.venv/`+`uv.lock` off via `uv run --no-project --with . <script>` (or `--with pytest python
-B -m pytest`). This machine also exports `PYTHONDONTWRITEBYTECODE=1`/`PYTEST_ADDOPTS` (`config/shell/python.sh`) as a
safety net that does not travel — don't rely on it in place of the in-project settings. Apply before any `uv
run`/`pytest` in a repo. `qmd query` for knowledge-base search. Don't manually wrap markdown — the `md-wrap.py` hook
does. **Playwright browsers are system-provided** by `~/dotfiles` into the shared `$PLAYWRIGHT_BROWSERS_PATH`; never run
`playwright install` to download them (the node/libuv io_uring extractor deadlocks on this kernel) —
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` stops `bun install` from auto-fetching them (an explicit install still fetches
missing browsers; the provisioned set is what makes it skip), repos exact-pin the one canonical version, and bumping is
a dotfiles job. Full preference list (Python cache/venv hygiene, rtk, gh auth, Playwright browsers, Rust pre-push) →
`~/.claude/guides/cli-tools.md`.

## Long artifacts → files

When the user asks for a substantial artifact (detailed prompt, plan, spec, long code block, multi-section doc — roughly
≥30 lines), write it to a file and summarize in chat in a sentence or two; don't paste the full content. Pick a sensible
path (`~/.gstack/projects/<slug>/` for repo-scoped planning artifacts; repo root for artifacts that belong with the
code) or ask. Show diffs if asked to see changes, never the whole file again.

## System configs → dotfiles

Machine-level config (AppArmor profiles, sysctl, udev rules, systemd units) lives in `~/dotfiles/` and deploys via stow
— never one-off `sudo bash -c` writes into `/etc/`. When a fix needs a system config file, add it to the dotfiles repo
with a stow target and document it in `docs/solutions/`.

## Auto-loaded guides

Imported with `@` because the git/GitHub workflow rules are referenced on every commit and PR. Cheaper to keep in
context than to re-Read each time.

@~/.claude/guides/git-and-github.md
