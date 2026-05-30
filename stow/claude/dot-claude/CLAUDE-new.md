# Global User Instructions

These are always-on rules. Detailed procedures, examples, and reference tables live in `~/.claude/guides/*.md` and are
**not** auto-loaded — open the linked guide with Read when you actually perform that task. Every hard prohibition below
is stated in full here; the guides hold only the elaboration.

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
per-language conventions) → `~/.claude/guides/code-comments.md`; the deterministic scanner and pattern catalog live in
the `/code-comments` skill.

## Workflow & skills

gstack owns ideation, planning, shipping, and operations; compound-engineering (CE) owns the code loop. When a request
matches an available skill, ALWAYS invoke it with the Skill tool as your FIRST action — don't answer directly or use
other tools first.

**$100 Rule:** when prevention was missed and a bug slips through, invest in the permanent fix — test, guard, lint rule,
or docs/solutions entry. Trivial work (<~20 lines: single-file fixes, config tweaks, typos) may skip the full loop.

**Query solutions first:** before answering, diagnosing, researching, or proposing, run `qmd query "<topic>"
--collection solutions` to surface prior decisions. Applies to all interactions, and **explicitly to `/investigate` and
every gstack debugging skill** — their `gstack-learnings-search` does NOT reach `docs/solutions/`, so query the corpus
yourself during symptom-collection, before the first hypothesis.

Routing table, per-skill rules, and the `qmd-learnings-researcher` companion-dispatch hack →
`~/.claude/guides/workflows-and-skills.md`.

## Solutions repo

`docs/solutions/` is a symlink to `~/dev/solutions-docs` (a separate private repo). The consuming repo's `git status`
shows nothing for it. **After writing there** (e.g. via `/compound`), commit and push in that repo: `cd
~/dev/solutions-docs && git add -A && git commit -m "docs: …" && git push`. Symlink-recreate command →
`~/.claude/guides/workflows-and-skills.md`.

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
**Exception:** package-manager version constraints (npm/bun/cargo/pip) are fine when a lockfile captures the integrity
hash — the lockfile is the SHA; don't SHA-pin `"react": "^18"`. Tag→SHA resolution and audit script →
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

## CI after push

After `git push` / `gh pr create|merge` / `gh release create` / `gh workflow run` / `gh api …/dispatches`, a PostToolUse
hook lists active runs with the exact `gh run watch <id> --exit-status` to spawn — run one per active run in the
background (or `gh pr checks <pr> --watch` for PR-scoped). Re-run `gh run list --branch <branch>` afterward to catch
chained runs. **Never proceed past a red run.** Policy source of truth: the `~/.claude/ci-watch-prompt.sh` header.

## CLI tools

Prefer CLI tools via Bash over built-in Read/Edit/Grep/Glob (`rg`/`fd`/`jaq`/`ast-grep`; `cat`/`bat`; `sed`/`awk`).
Install order: brew > bunx/uvx > python3/node. **`trash`, never `rm`/`git rm`** (both denied in `settings.json`). `uv
run` for ad-hoc Python. `qmd query` for knowledge-base search. Don't manually wrap markdown — the `md-wrap.py` hook
does. Full preference list (Python bytecode, rtk, gh auth, Rust pre-push) → `~/.claude/guides/cli-tools.md`.

## Long artifacts → files

When the user asks for a substantial artifact (detailed prompt, plan, spec, long code block, multi-section doc — roughly
≥30 lines), write it to a file and summarize in chat in a sentence or two; don't paste the full content. Pick a sensible
path (`~/.gstack/projects/<slug>/` for repo-scoped planning artifacts; repo root for artifacts that belong with the
code) or ask. Show diffs if asked to see changes, never the whole file again.

## System configs → dotfiles

Machine-level config (AppArmor profiles, sysctl, udev rules, systemd units) lives in `~/dotfiles/` and deploys via stow
— never one-off `sudo bash -c` writes into `/etc/`. When a fix needs a system config file, add it to the dotfiles repo
with a stow target and document it in `docs/solutions/`.
