# Git, Commits, Pull Requests & CI

Detail behind the **Branches**, **Commits & PRs**, and **CI after push** rules in `~/.claude/CLAUDE.md`. Open this
before authoring any commit message, PR/issue/release body, or when watching CI after a push.

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

## Commit messages

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

## Pull requests

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

## Authoring GitHub correspondence: `/tmp/` + `--body-file` + `/unslop`

**Mandatory workflow for all server-side artifacts that ship text to GitHub.** Applies to PR bodies, PR comments, PR
reviews, issue bodies, issue comments, release notes, and any future `gh` command that takes a `--body` or `--notes`
flag. Also covers `git commit -m` (the squash-merge commit message lands in public history alongside the PR body).

Three steps. The first two are mandatory in every repo; the third is mandatory in every repo regardless of whether the
repo has its own prose-linting pipeline.

1. **Author in `/tmp/` with a collision-proof name.** Generic names like `/tmp/pr-body.md` clobber parallel sessions,
   and reused tmp files from earlier turns ship stale content. Use one of two filename forms — no exceptions. For
   PR-scoped artifacts (PR body, PR comment, PR review), name the file `/tmp/pr-body-<repo>.<branch>.md` where `<repo>`
   is `$(basename "$(git rev-parse --show-toplevel)")` and `<branch>` is `$(git rev-parse --abbrev-ref HEAD | tr / -)`
   (slashes in branch names → `-`). The repo+branch key scopes the file to the current work, so re-runs on the same
   branch overwrite in place — desired, since resubmitting replaces server-side. For everything else (commit messages,
   issue bodies, issue comments, release notes, one-off bodies), name the file `/tmp/<kind>-$(uuidv7).md`. The `uuidv7`
   helper lives at `stow/local/dot-local/bin/uuidv7` (deploys to `~/.local/bin/uuidv7` via `scripts/stow-deploy local`);
   it's a three-line `python3.14` script around `uuid.uuid7()` (stdlib uuid7 was added in 3.14, so the shebang pins that
   version). UUIDv7 is time-ordered, so `ls /tmp/commit-msg-*.md` sorts by creation. Use a fresh UUID per file — never
   reuse one across two artifacts. The auto-format hook (`md-wrap.py`) skips `/tmp/` paths, so the file keeps its
   authored shape — no 120-char wrapping inside prose. Write each paragraph and each bullet as **one logical line**;
   GitHub soft-wraps for display.
2. **Run `/unslop /tmp/<path>.md`.** The `unslop` skill (`~/.claude/skills/unslop/`) is required for every body before
   submission. It runs `scripts/score.py` as a deterministic gate, then recasts only the lines the script flags —
   em-dash density, formulaic structures ("It's not X, it's Y", "Here's the thing", etc.), filler openers, AI
   self-references, pseudo-profound openers. Score `0` exits silently; non-zero scores produce recast diffs the agent
   reviews. This rule is universal — even repos without Vale + LanguageTool wired up still run `/unslop` so the prose
   floor is in place. **Voice-match against captured notes.** `/unslop` catches the deterministic patterns; the
   voice-match layer is judgment. After `/unslop` returns clean, check `~/dev/brettdavies/brettdavies/.context/voice.md`
   if it exists for patterns the regexes can't catch — sycophantic echoes, fabricated verifications, restated-argument
   summaries, "Thanks again" closes. Voice-matching is the heavy pass on conversational surfaces (PR comments, issue
   discussion, thread replies); on PR bodies and release notes it's a lighter pass — those stay technical with only
   slight softening. When a draft gets meaningfully rewritten, append the LLM-draft → Brett-rewrite swap in `voice.md`
   with a one-line "why" so the next draft starts closer.
3. **Submit via file flag, then delete the tmp file.** `gh pr create --body-file <path>`, `gh pr edit --body-file ...`,
   `gh pr comment --body-file ...`, `gh issue create --body-file ...`, `gh release create --notes-file ...`, `git commit
   --file ...`. Never inline the body via `--body "..."`, `-m "..."`, or a `--body "$(cat <<'EOF' ... EOF)"` heredoc.
   **As soon as the `gh` (or `git commit`) call returns success, delete the tmp file with `trash <path>`.** The file is
   single-use; leaving it around invites accidental reuse with stale content on the next turn and clutters `/tmp/`. If
   the submit fails, keep the file, fix, resubmit, then delete on success.

Typical flow (PR body):

```bash
REPO=$(basename "$(git rev-parse --show-toplevel)")
BRANCH=$(git rev-parse --abbrev-ref HEAD | tr / -)
BODY=/tmp/pr-body-${REPO}.${BRANCH}.md
$EDITOR "$BODY"                                  # one logical line per paragraph
/unslop "$BODY"                                  # mandatory scrub pass
gh pr create --base dev --title "type(scope): description" --body-file "$BODY"
trash "$BODY"                                    # delete after successful submit
```

Typical flow (commit message):

```bash
MSG=/tmp/commit-msg-$(uuidv7).md
$EDITOR "$MSG"
/unslop "$MSG"
git commit --file "$MSG"
trash "$MSG"                                     # delete after successful commit
```

**Don't sidecar the tmp path.** Bash tool calls run in fresh shells, so `$MSG` doesn't survive between calls. Do NOT
write the path to a sidecar file (`echo "$MSG" > /tmp/last-msg-path.txt` or any equivalent) and re-read it later.
Re-paste the literal path in each call, or recompute it deterministically (the PR-body form already does, from
`<repo>.<branch>`). Sidecar paths outlive the current turn and `/clear`, silently pointing new work at stale targets.
Applies to **any** sidecar filename — picking a different name doesn't make it safe.

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

## Changelog is the changelog source of truth

The `## Changelog` section of the PR body is the changelog source of truth. `generate-changelog.sh` extracts these
categorized bullets verbatim into CHANGELOG.md during release prep. Write for users, not developers:

- INCLUDE: new features, changed behavior, breaking changes, fixed bugs, new/removed config.
- EXCLUDE: internal refactors, test additions, code cleanup, CI changes, implementation details. Document those
  elsewhere in the PR body (Files Modified, Key Details, etc.) — NOT in `## Changelog`.
- If a PR has NO user-facing changes (pure refactor, test-only, CI-only), leave `## Changelog` empty or omit it.
- NEVER manually edit CHANGELOG.md — it is a generated artifact. Fix inputs (commit messages, PR descriptions,
  `cliff.toml`), not the output.

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
