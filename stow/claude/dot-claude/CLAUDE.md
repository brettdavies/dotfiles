# Global User Instructions

## Compound Engineering Workflow

You MUST follow the Plan > Work > Review > Compound loop for all non-trivial work.

**Loop:**

1. **Plan** (`/plan`) — Research the codebase, check `docs/solutions/` for prior art, design an approach. Planning
   should take more effort than implementing. Ask the three questions: What was the hardest decision? What alternatives
   were rejected? Where are you least confident?
2. **Work** (`/work`) — Implement the plan. Follow the plan exactly; deviate only with explicit rationale.
3. **Review** (`/review`) — Multi-agent review. Fix all findings before proceeding.
4. **Compound** (`/compound`) — Document the solution in `docs/solutions/` so the team never re-solves the same problem.

**$100 Rule:** When prevention was missed and a bug or regression slips through, invest in the permanent fix — add a
   test, a guard, a lint rule, or a docs/solutions entry. The cost of fixing later always exceeds the cost of fixing
   now.

**Trivial work exemption:** Single-file fixes, config tweaks, typo corrections, and similar changes that touch fewer
   than ~20 lines may skip the full loop. Use judgment.

**Before researching from scratch:** Always check `docs/solutions/` for existing solutions and patterns.

---

## Shared Solutions Repo

`docs/solutions/` in every repo is a symlink to `~/dev/solutions-docs` — a separate private git repo
   (`brettdavies/solutions-docs`). This centralizes all compounded solutions so the learnings-researcher agent can
   search across all repos from any working directory.

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
  refactor review to evaluate splitting responsibilities into smaller, focused modules.

---

## CLI Tool Preferences

- **Prefer CLI tools** over direct in-memory manipulation when possible, especially for editing or searching within
  larger files or across the codebase.
- Examples: Use `sed`, `awk`, or in-place editing CLI utilities for modifying files; use code-aware tools (`ast-grep`)
  for refactoring.
- **For file deletion,** do NOT use `rm` or `git rm` (both are denied in `settings.json`).
- Instead, use [`trash`](https://github.com/sindresorhus/trash) to safely move files to the system trash.
- **For code search:**
- Always use [`rg` (ripgrep)](https://github.com/BurntSushi/ripgrep) instead of `grep` (denied in `settings.json`) for
  fast recursive search.
- [`ast-grep`](https://ast-grep.github.io/) is available for syntax-aware codebase traversal.
- **For knowledge base search,** use [`qmd`](https://github.com/tobi/qmd) to search the Obsidian vault, solutions-docs,
  and skills collections. Prefer `qmd search` (BM25, ~30ms) for keyword queries; escalate to `qmd vsearch` (vector, ~2s)
  for semantic queries; use `qmd query` (hybrid, ~10s) only for broad discovery. Always search qmd before researching
  from scratch — check solutions and vault for prior art.
- **For JSON processing,** use [`jaq`](https://github.com/01mf02/jaq) instead of `jq`. It's a Rust reimplementation with
  compatible syntax.
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
