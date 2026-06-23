# Code Comments — Full Policy

Detail behind the **Code comments** rule in `~/.claude/CLAUDE.md`. The default and the hard bans are stated inline; this
file holds the full policy (legitimate reasons, file-header rule, refactoring rule, per-language conventions). The
`/code-comments` skill ships the deterministic scanner (`scripts/scan.sh`) and the forbidden-pattern catalog.

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
  line. Section headers that label a *composite* block of distinct steps (parse-then-validate-then-normalize) are
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

**In-repo prose docs follow the same present-state rule.** The temporal/historical hard ban above is not limited to code
comments — it governs in-repo documentation too: READMEs, `docs/**`, specs, runbooks, plans, and knowledge-base notes
(e.g. a PARA-ACE vault). Write each doc to describe present reality and let `git blame` and the PR carry the evolution;
strip `previously` / `we switched from X` / `reverting the earlier framing` / `this supersedes` / dated `Update:` notes
/ meta-commentary about the synthesis process. The mechanism when content changes: rewrite the page so the current state
reads as if it were always true. Retire a stale section by marking it **deprecated** in present tense rather than
narrating its removal — for example, replace `Update (2026-05): migrated from Foo to Bar` with a clean description of
Bar, since the migration lives in the history, not the body. **Exception:** a doc whose explicit purpose is to log
change — a supersedes-aware decision-log, a `CHANGELOG`/`RELEASES`, a migration record — is the designated home for
supersession narration; present-only does not apply inside it.

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

**Audit:** the `/code-comments` skill ships `scripts/scan.sh` to flag the hard-banned patterns across changed files.
Invoke it during code review or before commit. The skill also holds the full pattern catalog
(`references/forbidden-patterns.md`), per-language guides in `references/languages/<lang>.md` (load only the language
you need), and good/bad examples (`references/examples.md`).
