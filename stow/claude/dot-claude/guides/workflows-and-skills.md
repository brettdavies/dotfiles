# Workflows, Skills & the Solutions Corpus

Detail behind the **Workflow & skills** and **Solutions repo** rules in `~/.claude/CLAUDE.md`. Open this when picking a
skill for a task, dispatching a learnings researcher, or writing to `docs/solutions/`.

## Development workflow: gstack + compound-engineering

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

### Key routing rules

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

### $100 Rule

When prevention was missed and a bug or regression slips through, invest in the permanent fix — add a test, a guard, a
lint rule, or a docs/solutions entry. The cost of fixing later always exceeds the cost of fixing now.

### Trivial work exemption

Single-file fixes, config tweaks, typo corrections, and similar changes that touch fewer than ~20 lines may skip the
full loop. Use judgment.

## Query solutions first

Before answering questions, diagnosing issues, researching options, or proposing changes, run `qmd query "<topic>"
--collection solutions` to surface existing decisions and patterns. Solutions contain hard-won decisions that cannot be
inferred from the file layout alone. This applies to all interactions — questions, debugging, code review, and
architecture discussions — not just implementation.

**This explicitly includes `/investigate` and any gstack debugging skill.** Their built-in prior-learnings step runs
`gstack-learnings-search`, which queries the gstack brain, NOT `docs/solutions/` — a different store. Run `qmd query
"<symptoms>" --collection solutions` yourself during symptom-collection, before forming a hypothesis. The skill's
history search does not cover the shared corpus, and treating it as if it does has cost a full re-derivation of an
already-documented root cause and fix.

## Learnings-researcher dispatch (the qmd companion hack)

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

**Extend the same dispatch to `/investigate` and other gstack debugging skills.** They are not CE skills, so the rule
above does not auto-apply, and their `gstack-learnings-search` step does not reach `docs/solutions/`. When investigating
a bug, dispatch `qmd-learnings-researcher` (or run `qmd query "<symptoms>" --collection solutions`) during the skill's
Phase 1 symptom-collection, before the first hypothesis — the shared corpus is where prior root causes and fixes live.

## Shared solutions repo

`docs/solutions/` in every repo is a symlink to `~/dev/solutions-docs` — a separate private git repo
(`brettdavies/solutions-docs`). This centralizes all compounded solutions so the learnings-researcher agent can search
across all repos from any working directory.

**After writing to `docs/solutions/`** (e.g., via `/compound`), you MUST commit and push in the shared repo:

```bash
cd ~/dev/solutions-docs && git add -A && git commit -m "docs: <description>" && git push
```

The consuming repo's `git status` will show nothing for `docs/solutions/` because the symlink target is gitignored. If
the symlink is missing, recreate it from the consuming repo's root with an absolute path (the shell expands `$HOME` at
execution, baking in the resolved path on the current machine): `ln -s "$HOME/dev/solutions-docs" docs/solutions`.
Absolute is preferred over a relative target because a relative target depends on how deep the consuming repo lives in
the filesystem — `../../dev/solutions-docs` resolves correctly only when the repo lives two levels under `$HOME`, and
silently produces a broken `~/dev/dev/solutions-docs` target when the repo sits at `~/dev/<repo>/`.
