# Git, Commits, Pull Requests & CI

Detail behind the **Branches**, **Commits & PRs**, **Worktree commits and pushes**, and **CI after push** rules in
`~/.claude/CLAUDE.md`. Open this before authoring any commit message, PR/issue/release body, committing or pushing from
a linked worktree, or when watching CI after a push.

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

**Enforcement.** The `~/.claude/ai-attribution-guard.sh` PreToolUse Bash hook denies `git commit` and
`gh pr|issue|release` calls whose message or body carries the trailer. It resolves `--file` / `-F` / `--body-file` /
`--notes-file` and reads the artifact, so a trailer authored into a `/tmp/` body is caught at the same gate as an inline
one; a human `Co-Authored-By:` passes. Tests at `tests/ai-attribution-guard.bats` (22 cases) — run with
`bats tests/ai-attribution-guard.bats`. The hook exists because the rule alone loses to a mid-session harness reminder
that instructs the opposite, and the cleanup is a signed-history rewrite plus a force-push to a protected branch.

## Rewriting pushed history (reword, force-push)

**Default: don't.** Rewriting already-pushed or shared history is a last resort, not a cleanup reflex. A
wrong-but-cosmetic commit message (mis-scoped, mislabeled, wrong message grabbed from a shared `/tmp` file) is almost
never worth a rewrite: the content is correct and `git show --stat` shows the real files. On a repo several agents share
(a symlinked knowledge store like `docs/solutions/`), prefer leaving it — see
`docs/solutions/workflow-issues/shared-working-tree-git-add-commit-race-across-concurrent-agents.md`.

**`git history reword <commit>` (git 2.54, experimental) strips signatures and resets committer dates.** It is the
ergonomic way to reword a commit deep in history — `--dry-run`, `--update-refs=(head|branches)`, and non-interactive via
`GIT_EDITOR="cp /tmp/msg.txt" git history reword <sha>` — and it automates the rebase. But it re-hashes the target
commit **and every descendant**, and in doing so it **drops each rebuilt commit's signature (output is unsigned) and
resets the committer date to now**; it also refuses merge commits. On a repo that signs commits (`commit.gpgSign=true`)
this silently un-verifies every re-hashed commit and flattens their committer timestamps: a message-only reword of one
commit ten-deep leaves all eleven commits unsigned under a single committer date (author dates and tree survive). So
`git history reword` is acceptable only where signatures and committer dates do not matter; on a signed repo it is the
wrong tool, and rewording one commit degrades every unrelated commit stacked above it.

**To rewrite while preserving signatures + committer dates**, use the `strip-ai-attribution` skill's `git commit-tree`
chain (rebuilds each commit from its exact tree with `-S` re-signing and `GIT_COMMITTER_DATE` preserved) or
`git rebase --root --exec '… commit --amend --no-edit -S'` with committer-date restoration. That skill's
`references/git-mechanics.md` tabulates why `commit-tree` beats `reword`/`filter-repo` here; bulk attribution/trailer
strips are that skill's job (user-invocable only, gated on explicit confirmation).

**When a rewrite is genuinely warranted, do it safely.** Operate in a **fresh throwaway clone**, never the
shared/symlinked working copy (moving its refs out from under a concurrent writer is the exact hazard the shared-tree
doc describes). Before pushing, confirm the rewrite changed only history, not content: `git diff origin/main HEAD` must
be **empty**. Push with `--force-with-lease` (it aborts rather than clobbering if a writer advanced the ref in your
window); on abort, re-clone and retry. Every SHA changes, so every other clone, worktree, and CI cache must re-clone or
hard-reset, and any SHAs pinned in other docs go stale.

## Linked worktrees and git hooks

Git runs a hook with variables that pin git to the repository being committed or pushed, and every process the hook
starts inherits them. `GIT_DIR` outranks a child's cwd and `git -C <dir>`; `GIT_INDEX_FILE` outranks the index of
whatever repository the child finds. A tool that runs git somewhere else on purpose then acts on the hook's repository
instead: a test fixture's `git init` writes `core.bare = true` into the shared config and the main clone refuses
`git commit` from then on, a scratch commit lands on the branch being pushed, or a child's `git add` lands in the
commit's temporary index.

What git 2.56 exports, with `<gitdir>` the checkout's private git directory (`<main>/.git/worktrees/<name>` for a linked
worktree). `GIT_PREFIX` is set in every case:

| Hook and command            | Main clone (`.git` is a directory)                | Linked worktree (`.git` is a file)                                  |
| --------------------------- | ------------------------------------------------- | ------------------------------------------------------------------- |
| pre-commit, `commit`        | `GIT_INDEX_FILE=.git/index` (relative)            | `GIT_DIR=<gitdir>`, `GIT_INDEX_FILE=<gitdir>/index`                 |
| pre-commit, `commit -a`     | `GIT_INDEX_FILE=<abs>/.git/index.lock`            | `GIT_DIR=<gitdir>`, `GIT_INDEX_FILE=<gitdir>/index.lock`            |
| pre-commit, `commit <path>` | `GIT_INDEX_FILE=<abs>/.git/next-index-<pid>.lock` | `GIT_DIR=<gitdir>`, `GIT_INDEX_FILE=<gitdir>/next-index-<pid>.lock` |
| pre-push                    | nothing that names a repository                   | `GIT_DIR=<gitdir>`                                                  |

The right column covers every checkout whose `.git` is a file: a linked worktree, attached or `--detach`, a
`--separate-git-dir` clone, and a submodule. Its paths are absolute, so they resolve from any cwd. In the main clone, a
push exports nothing that names a repository and a plain commit's relative index resolves against each child's own
repository, so both are safe; `commit -a` and `commit <path>` export an absolute index path in every checkout.

Hooks that isolate the environment split the work:

- **pre-push clears the variables at its top**, before it starts anything. Git starts every hook at the worktree root,
  so the hook's own git calls find the same repository by discovery, and pre-push has no temporary index to lose.
- **pre-commit keeps them and wraps each tool it starts** in a subshell that unsets them. Its staged-path lookup has to
  read the temporary index of `commit -a` and `commit <path>`; cleared at the top, `git diff --cached` reads the real
  index, the staged set comes back empty, and every gate is skipped.
- The variables: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`,
  `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_PREFIX`, `GIT_NAMESPACE`. dotfiles keeps them in `.githooks/lib/git-env.sh`
  (`git_env_clear`, `git_env_isolated`); the github-repo-setup templates in `hooks-lib.sh` (`without_git_repo_env`) and
  the `unset` at the top of each pre-push template.

To check a repo before committing or pushing from a worktree, search its hooks directory (this honors `core.hooksPath`)
from the checkout's root:

```bash
rg -n 'git_env_clear|git_env_isolated|without_git_repo_env|unset GIT_DIR' "$(git rev-parse --git-path hooks)"
```

The repo is safe when pre-push unsets the variables before its first command and every tool pre-commit starts goes
through the wrapper. A repo with no hooks is safe too. A test runner that scrubs the variables itself (dotfiles
`scripts/run-tests`, a bats `setup`, a Bun preload) protects only that suite, not the hook's other gates. Anywhere else,
commit and push from a standalone clone, and stage with `git add` before a plain `git commit` rather than `commit -a` or
`commit <path>`.

cargo-deny 0.19.1 through 0.19.5 refresh the advisory database by running git under the inherited variables. From a
linked worktree's pre-push, that resets the branch to its remote and writes the repository into the advisory database
clone, which then breaks cargo-deny for every repository on the host. 0.19.6 clears the variables first
([EmbarkStudios/cargo-deny#858](https://github.com/EmbarkStudios/cargo-deny/pull/858)). An isolating hook covers every
version; still check `cargo deny --version`, and that no `cargo install` copy in `~/.cargo/bin` shadows the Homebrew one
on PATH. Background: `docs/solutions/test-failures/linked-worktree-push-exports-git-dir-into-prepush-test-suite.md`.

## Pull requests

**Title format:** `type(scope): description` (same Conventional Commits types as above).

**Body:** PR templates cascade — repo-local first, global fallback:

1. If the repo has `.github/pull_request_template.md`, use **that** file. It is authoritative for this repo (it may have
   diverged from the global template intentionally — respect the local version).
2. Otherwise, fall back to `~/.config/github/pull_request_template.md`.

Fill in each section, remove HTML comment placeholders, and insert real content. Omit optional sections that don't apply
(e.g., Screenshots for non-UI changes). Do NOT use hardcoded PR body formats from skills or other sources — the cascade
above is the single source of truth.

**Pre-flight before every `gh pr create` / `gh pr edit --body`:** read the template file first
(`cat .github/pull_request_template.md`, or the global fallback) and use its content as the body skeleton. If you're
about to `--body` a hand-written string instead of filling in the template, stop — that's the bypass.

**Sub-section completeness.** The template's `Files Modified` block has four sub-headers (`**Modified:**` /
`**Created:**` / `**Renamed:**` / `**Deleted:**`); `Related Issues/Stories` has four labels (`Story:` / `Issue:` /
`Architecture:` / `Related PRs:`). All four are required even when empty — write `- None.` or `n/a` rather than deleting
the sub-header or label. The "delete empty sections" rule applies ONLY to the `Changelog` block's `### Added` /
`### Changed` / `### Fixed` / `### Documentation` subsections, per the template's own comment.

## Stacked PRs

A stack is a chain of feature branches where each PR targets the branch below it (`feat/b` → `feat/a` → `dev`). The
official extension manages them: `gh extension install github/gh-stack`. GitHub tracks the stack server-side as its own
object with a stack number, separate from the local branch chain.

### Land the whole stack in one atomic merge

`gh stack merge <top-pr> --squash --yes` is the default way to land a stack. It merges every PR up to and including the
one named in a single all-or-nothing operation: each PR squashes into the base under its own `<title> (#n)` subject and
body, so a provenance guard that requires the `(#n)` reference still passes, and a failure on any one PR merges none of
them. Only open/not-draft state is checked client-side; branch protection and rulesets are evaluated server-side when
the merge runs, and bypassing merge requirements is not supported for stacks.

Prefer it, because merging one PR at a time is quadratic in CI. GitHub restacks every tracked branch above each merge,
and a workflow triggered on `pull_request` with no path filter cannot tell that the restacked trees are byte-identical,
so it runs the full battery on every branch again. A ten-PR stack costs about 45 restacks and ninety full workflow runs
that way. The atomic merge performs no intermediate restack, so nothing re-runs.

Every gate the sequential flow spreads across cycles has to be satisfied before the single call:

- **Every head green**, verified by rollup rather than watcher exit code (below).
- **Every body validated** against that PR's own `base...HEAD` — `origin/dev...<head>` for the bottom PR,
  `origin/<parent-branch>...<head>` for each PR above it. That is the diff GitHub shows and the diff its squash carries;
  `origin/dev...<head>` on a mid-stack PR wrongly includes every layer beneath it.
- **Stale stack narration rewritten** to present tense. Squash settings that copy `PR_TITLE` + `PR_BODY` put "stacked
  on #N" and "once #N merges" into permanent history.

### Verify CI by rollup, not by watcher exit code

`gh pr checks --watch` returns once no check it can see is pending, and its exit code says only whether one of them
failed. In gh 2.36.0 and later it exits 1 when a check ends `FAILURE`, `ERROR`, `TIMED_OUT`, or `ACTION_REQUIRED`, and 0
when every check ends `SUCCESS`, `SKIPPED`, `NEUTRAL`, or `CANCELLED`; releases before 2.36.0 also exit 1 on `CANCELLED`
([cli/cli#7960](https://github.com/cli/cli/pull/7960)). `SKIPPED` exits 0 in every release that has `--watch`. Without
`--watch`, a pending check exits 8 (gh 2.34.0 and later, [cli/cli#7866](https://github.com/cli/cli/pull/7866)). It keeps
one entry per check, the most recently started: a check run is keyed by its name, workflow, and event, and a status
context by its context name
([`eliminateDuplicates`](https://github.com/cli/cli/blob/e95424515725d5dab88fb221a5df00e8b604269e/pkg/cmd/pr/checks/aggregate.go#L96)).
It counts only the checks registered when it polls, so a workflow that registers after its last poll is never counted.
Read the rollup instead and assert every live conclusion is `SUCCESS`. In the rollup, a branch GitHub rewrote twice
shows each check twice: a `CANCELLED` set from the superseded run under the concurrency group plus the live set. Check
runs and status contexts also report differently — a check run carries `status` plus `conclusion` while a status context
carries `state`, so a filter that reads only `conclusion // state` counts in-progress check runs as passing:

```bash
gh pr view <n> --json headRefOid,mergeStateStatus,statusCheckRollup --jq '
  def st: if .__typename == "CheckRun" then (if .status == "COMPLETED" then .conclusion else .status end) else .state end;
  {merge: .mergeStateStatus, tally: ([.statusCheckRollup[] | st] | group_by(.) | map({(.[0]): length}) | add)}'
```

### Sequential merges, when the stack must land in pieces

Merge the lowest unmerged PR with `gh stack merge <pr> --squash --yes`, then read what GitHub did before touching
anything locally. It deletes the merged head branch, retargets the next PR to the base, and restacks every branch above
onto the new tip with the trees preserved and itself as committer. The local side only needs
`git branch -f <branch> origin/<branch>` per branch (or `git reset --hard origin/<branch>` in a checkout); never
force-push over GitHub's rewrite, and never delete a branch by hand. Then wait for the restacked heads' CI, which is the
only gate on a repo whose workflows trigger on `pull_request` alone, and repeat.

The restack happens only while GitHub still tracks the stack. A pair stacked by base branch alone, or removed from the
stack before the lower PR merges (both timelines show `removed_from_stack`), is retargeted to the base and left as it
was, and the upper PR goes `DIRTY`: the base now holds the lower PR as one squash commit while the upper branch still
carries its original commits. Merge the base into the upper branch, resolve hunk by hunk rather than taking whole files,
and check that the resolved diff's `git patch-id --stable` matches the upper PR's own patch before committing; a chained
`git merge-tree --write-tree` over the planned squash order shows beforehand which PRs will need this. Steps and
caveats: `docs/solutions/workflow-issues/resolve-stacked-pr-after-base-squash-merge-and-verify-by-patch-id.md`.

Without the extension, the equivalent is the asynchronous merge endpoint. GitHub refuses the synchronous
`PUT .../pulls/<n>/merge` for any PR it tracks as part of a stack, including one it rebased itself after the PR below
merged, so do not retry through it:

```bash
gh pr view <n> --json body -q .body > <scratchpad>/pr<n>-merge-msg.md      # trash after the merge
gh api -X PUT repos/<owner>/<repo>/pulls/<n>/merge-async \
  -f merge_method=squash -f merge_action=direct_merge -f sha=<full-head-sha> \
  -f commit_title="<pr title> (#<n>)" -F commit_message=@<scratchpad>/pr<n>-merge-msg.md
gh api repos/<owner>/<repo>/pulls/<n>/merge-async/<uuid>                   # poll until status is "merged"
```

The 202 response carries `details.uuid`; poll until `status` is `merged` or `failed`. Pass `commit_title` and
`commit_message` explicitly so the squash keeps the web UI's `<title> (#n)` + body shape. This endpoint also merges
every PR up to and including the one named, so call it on the lowest unmerged PR.

### Bookkeeping: link, adopt, inspect, detach

- **`gh stack link --base <trunk> <pr...>`** creates or updates the GitHub stack from existing PRs, bottom to top,
  without adopting local tracking. This is the entry point when the branches are managed by hand or by another tool. It
  never rewrites the branches.
- **`gh stack init --base <trunk> <branch...>`** adopts existing branches into local tracking, bottom to top, leaving
  every branch SHA untouched.
- **`gh stack view --short`** lists the chain with each PR's state; `--json` for machine reading. `gh stack rebase`
  cascades a rebase across the chain and `gh stack push` force-pushes each branch with its own lease.
- **Detach through the extension, never by hand.** `gh pr edit <n> --base <trunk>` is refused for a PR GitHub tracks as
  part of a stack. Use `gh stack unstack <stack-number>` to detach on GitHub, or `--local` to drop only local tracking.
  Never chain a branch deletion after a base edit: deleting the branch a PR targets closes that PR, and a head that has
  since been rewritten cannot be reopened.

## Authoring GitHub correspondence: `/tmp/` + `--body-file` + `/unslop`

**Mandatory workflow for all server-side artifacts that ship text to GitHub.** Applies to PR bodies, PR comments, PR
reviews, issue bodies, issue comments, release notes, and any future `gh` command that takes a `--body` or `--notes`
flag. Also covers `git commit -m` (the squash-merge commit message lands in public history alongside the PR body).

Three steps. The first two are mandatory in every repo; the third is mandatory in every repo regardless of whether the
repo has its own prose-linting pipeline.

1. **Author in `/tmp/` with a collision-proof name.** Generic names like `/tmp/pr-body.md` clobber parallel sessions,
   and reused tmp files from earlier turns ship stale content. Use one of two filename forms — no exceptions. For
   PR-scoped artifacts (PR body, PR comment, PR review), name the file `/tmp/pr-body-<repo>.<branch>.md` where `<repo>`
   is `$(basename -s .git "$(git remote get-url origin 2>/dev/null || git rev-parse --show-toplevel)")` and `<branch>`
   is `$(git rev-parse --abbrev-ref HEAD | tr / -)` (slashes in branch names → `-`). `<repo>` comes from the origin
   remote, not the checkout's directory: an agent slot's directory is a number (`~/slots/<repo>/<N>`), so parallel slots
   on one branch name would otherwise share a file; the directory name is only the fallback for a repo with no origin.
   The repo+branch key scopes the file to the current work, so re-runs on the same branch overwrite in place — desired,
   since resubmitting replaces server-side. For everything else (commit messages, issue bodies, issue comments, release
   notes, one-off bodies), name the file `/tmp/<kind>-$(uuidv7).md`. The `uuidv7` helper lives at
   `stow/local/dot-local/bin/uuidv7` (deploys to `~/.local/bin/uuidv7` via `scripts/stow-deploy local`); it's a
   three-line `python3.14` script around `uuid.uuid7()` (stdlib uuid7 was added in 3.14, so the shebang pins that
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
   `gh pr comment --body-file ...`, `gh issue create --body-file ...`, `gh release create --notes-file ...`,
   `git commit --file ...`. Never inline the body via `--body "..."`, `-m "..."`, or a `--body "$(cat <<'EOF' ... EOF)"`
   heredoc. **As soon as the `gh` (or `git commit`) call returns success, delete the tmp file with `trash <path>`.** The
   file is single-use; leaving it around invites accidental reuse with stale content on the next turn and clutters
   `/tmp/`. If the submit fails, keep the file, fix, resubmit, then delete on success. Chain the delete on the submit's
   own status: `git commit --file "$MSG" && trash "$MSG"`. Piping the submit's output first
   (`git commit --file "$MSG" | tail -2 && trash "$MSG"`) makes the pipeline exit with `tail`'s status, so a failed
   commit still deletes the message; read the output in a later step instead.

Typical flow (PR body):

```bash
REPO=$(basename -s .git "$(git remote get-url origin 2>/dev/null || git rev-parse --show-toplevel)")
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

**Enforcement.** The `~/.claude/heredoc-pr-guard.sh` PreToolUse Bash hook rejects
`gh pr (create|edit|comment|review) --body "<heredoc>"`, `gh issue (create|edit|comment) --body "<heredoc>"`,
`gh release (create|edit) --notes "<heredoc>"`, and `git commit -m "<heredoc>"`. The hook is wired into
`stow/claude/dot-claude/settings.json` and runs on every Bash tool call. Tests covering 41 cases (positive, negative,
and adversarial red-team bypasses) live at `tests/heredoc-pr-guard.bats` — run with `bats tests/heredoc-pr-guard.bats`.
If a legitimate use is blocked, fix the regex; do NOT bypass the hook for individual commands.

The `~/.claude/piped-commit-guard.sh` PreToolUse Bash hook rejects a `git commit` whose output is piped when a later
step in the same command removes its message file with `trash`, `rm`, or `mv`, and its deny carries the command rebuilt
without the pipe. `set -o pipefail` before the commit, with only `&&` from the pipe to that step, passes. Tests:
`bats tests/piped-commit-guard.bats`.

Why hook + docs (not docs alone): inline heredoc into `--body` produces wrapped-and-escape-trapped text that lands in
the PR body AND in the squash-merge commit message. Cleanup after the fact requires either re-submitting via
`--body-file` (acceptable) or a destructive `git history reword` + force-push to a protected branch (not acceptable).
~30 seconds of pre-submit `/tmp/` work avoids both.

**Heredoc escape rule (fallback for when `--body-file` is impractical).** If you still compose a body inline via
`gh pr create --body "$(cat <<'EOF' ... EOF)"`, the single-quoted delimiter (`<<'EOF'`) preserves the body **literally**
— no variable expansion, no backslash interpretation. Do NOT escape inner quotes, backslashes, or dollar signs. If the
body needs to render `"foo"`, write `"foo"` — not `\"foo\"`. The latter renders as literal backslash-quote in markdown
AND lands in the squash-merge commit message, where cleanup requires a destructive `git history reword` + force-push to
a protected branch. The `--body-file` approach above sidesteps this entire class of problem.

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
across all triggered workflows on the PR head in a single watcher. Its exit code is not the verdict: it exits 1 only
when a check failed, and 0 when the rest passed, were skipped, or were cancelled (gh 2.36.0 and later; see "Verify CI by
rollup, not by watcher exit code"). Read the rollup query from `~/.claude/CLAUDE.md` § "CI after push" afterwards and
assert every conclusion is `SUCCESS` (`SKIPPED` is acceptable only for a conditional job); see "Stacked PRs" for the
duplicated-entry case after a branch rewrite.

After every batch of watchers finishes, re-run `gh run list --branch <branch>` to catch dispatched chains (e.g.
`release.yml` → homebrew dispatch → `finalize-release`). The hook only fires after the original action; chained runs
need a manual re-check.

If you push CI-triggering changes via a path the hook doesn't cover (or `gh` is unavailable in the hook's environment),
run the same flow manually. Never proceed past a red run.

The full policy and matcher list lives in the script header at `~/.claude/ci-watch-prompt.sh` — that's the source of
truth.
