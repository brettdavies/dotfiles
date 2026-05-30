# Local-Only Files: Todos, `.context/`, and Handoffs

Detail behind the **Local-only files** rule in `~/.claude/CLAUDE.md`. The hard prohibitions live inline; this file holds
the full hard-rule list and the handoff filename convention. Open it when writing a todo, a handoff, or staging broadly
near `.context/`.

## Never commit todo files or `.context/`

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

## Handoff documents

Handoff documents (multi-session kickoff prompts that brief a future agent on state-of-the-world before they pick up
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
artifacts go to files" rule).
