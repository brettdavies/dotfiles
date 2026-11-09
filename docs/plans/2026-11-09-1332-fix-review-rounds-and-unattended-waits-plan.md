---
title: "fix: one review round, reviews fitted to the change, the smallest change, and waits that end"
type: fix
status: active
date: 2026-11-09
---

# One review round, reviews fitted to the change, the smallest change, and waits that end

Two PRs: one in dotfiles (base `dev`) and one in agent-skills (base `main`), both ready for Brett's final review by
21:00 CST on 2026-11-09.

## What the last three days show

Source: 67 brettdavies PRs updated since 2026-11-06 across 11 repos, their 84 review comments, the agent-slot ledger,
and the slot and prime transcripts.

1. **Round 2 does not change the outcome.** Ten PRs had a second `ce-code-review` round
   (agent-skills #229, #231, #233, #238; dotfiles #466, #473, #479; xurl-rs #524, #530, #531, #533). Every round 2
   reported no P0 or P1; its findings were P2 and P3, mostly gaps in round 1's own fixes. Two PRs went to a granted
   round 3 (agent-skills #231, dotfiles #466).
2. **Rounds go with size.** The three largest non-release PRs ran 2 or 3 rounds of code and devex review: dotfiles #466
   (+3182, 48 commits), agent-skills #229 (+2989, 24 commits), agent-skills #231 (+2286, 20 commits).
3. **The round cap is not enforced.** `slot-review-cap.sh` counts a `ce-code-review` Skill call made by the slot's own
   top-level Claude. The agent-slot skill has every review run as `claude -p` from a throwaway clone, which the hook
   never sees, so the ledger has no `review-round` event since 2026-11-05. The "round 1 of 2" labels on PRs are the
   slots counting themselves.
4. **Every review runs on Opus at `xhigh`, whatever it reviews**, docs-only and release PRs included.
5. **Review choice is fixed, not fitted.** Briefs and prime memories say `ce-code-review` on every PR, `/devex-review`
   for anything a developer uses, and `/cso` for credentials. Lite in-session reviews on small canon-sync PRs
   (.github#119, agentnative-cli #308/#309, bird #216/#217, homebrew-tap #187, xurl-rs #540) worked.
6. **Nothing says "smallest change".** The guards against overengineering are the brief's `Scope:`, the `Touches:` push
   gate, and `Adds:`, which nothing checks. No rule tells an agent to prefer the minimal fix.
7. **Unattended waits wake late.** In the xurl-rs 4.6.0 release slot (2026-11-07, 04:25 to 06:52 UTC), each time the
   slot ended its turn it parked on a background wait that woke it late, and Brett's "and?" or "how's it going?" made it
   look again and move on:
   - A poll waited on the tap and finalize runs with `case "$f" in *finalize*completed*)`. The run is named "Finalize
     Release", so the case-sensitive match never fired. Both runs were done at 06:34:58; the slot sat until Brett asked
     at 06:39, and the loop would have run about 30 minutes.
   - `gh run watch --exit-status` exits only when the whole run ends. A musl build cell failed early; the slot found it
     when Brett asked at 06:17, before the watcher's notice at 06:20.
   - Five CI runs were watched one after another, each under `timeout 3000`; the notice came 11 minutes after the start.
   - Not stalls: from 04:29 to 06:04 the slot waited on a "cut" from xurl-rs-prime and on Brett's merges.

## Requirements

- R1. One `ce-code-review` round per PR. A second round runs only when round 1 confirmed a P0 or P1, and it reviews only
  the fixes for those P0 and P1 findings, nothing broader. After the last round, every in-brief finding is fixed with no
  further review.
- R2. The slot hook keeps a hard cap of 2 rounds per PR as a backstop, and it counts the documented review path
  (`claude -p` from a throwaway clone) as well as a Skill call.
- R3. The coordinating prime, as well as Brett, may grant a round past the cap with `agent-slot grant-review`. A slot
  cannot grant itself one: the verb refuses a slot's directory and pane, and the cap hook denies a slot's Claude any
  Bash command that runs it.
- R4. Every review is recorded twice:
  - When the task has a plan doc, the review gets an entry in the plan's `## Review log`, committed and pushed when the
    review starts and again when it finishes. Every review's verdict also goes in a PR comment.
  - A slot also messages its coordinating prime when each review starts and when it finishes. That is the second place
    of record, and the prime keeps the count.
- R5. The reviews are chosen for the change, by the table below. The brief's `Reviews:` line names the picks with a few
  words on why, and `none` with a reason is valid. Primes pick the same way for their own PRs.
- R6. Every review and every reviewer subagent runs on Opus. Effort is set per review, by the table below.
- R7. Agents build the smallest change that meets the brief, and start its reviews once it meets the brief and its
  tests pass. From then on they change only what a review finding or a failing check calls for.
- R8. A background wait ends when the thing it waits on ends, or soon after its usual length.

### Reviews fitted to the change (R5)

| The change                                                                        | Reviews                                       |
| --------------------------------------------------------------------------------- | --------------------------------------------- |
| Trivial: typo, version or release bump, a one-line config fix, a factual docs fix | none, with the reason in the PR body          |
| Prose only (docs, skill text), no behavior change                                 | `ce-code-review` (the skill picks its depth)  |
| Code, hooks, or workflow behavior                                                 | `ce-code-review`                              |
| A new or changed command, verb, flag, output contract, or setup step someone runs | add `/devex-review`                           |
| Credentials, auth, permissions, network egress, or untrusted input                | add `/cso`                                    |

### Model and effort per review (R6)

| Review           | Model                                | Effort  |
| ---------------- | ------------------------------------ | ------- |
| `ce-code-review` | Opus, every reviewer subagent forced | `high`  |
| `/devex-review`  | Opus                                 | `high`  |
| `/cso`           | Opus                                 | `xhigh` |

A brief may raise the effort for a risky change.

### The smallest change (R7)

Added to CLAUDE.md, and folded into the agent-slot skill's "The brief is the scope":

> **Smallest change:** build the smallest change that meets the task. Add no verb, flag, option, config key,
> abstraction, or harness it does not name; a reviewer's suggestion of one goes under "Not in scope". When a fix needs
> its own fix, stop and report rather than widening the change.

### Waits that end (R8)

Added to CLAUDE.md § "Never block on a wait":

> **A wait must end when the thing does.** Before backgrounding a hand-written poll, run its exit test once against a
> finished example, such as a completed run of the same workflow, and confirm it fires; match names case-insensitively.
> Watch parallel runs in parallel, one watcher each. Bound each wait by about 1.5 times its usual length, not a
> catch-all like 3000 s; a bound a documented command sets stands. When a watcher times out, read the state yourself
> before waiting again.

The CI-watch reminder carries the same guidance with no fixed number, since each workflow's usual length differs.
`gh run watch` cannot stop at the first failed job, and GitHub reruns a failed job only after the run ends, so no new
watch tool is built.

## Changes

### dotfiles (one PR off `dev`)

- `stow/claude/dot-claude/slot-review-cap.sh`: also count a `PreToolUse` Bash call by the slot's top-level Claude whose
  command runs `claude` and names `ce-code-review`, through the same decide function and ledger line, and deny a Bash
  command from a slot's Claude session that runs `agent-slot grant-review`. The cap stays at 2.
- `tests/slot-review-cap.bats`: cases for the Bash path: counted (the documented multi-line command included), denied at
  the cap, and not counted outside a slot or for a command that does not start a review; a slot's own grant denied, and
  a quoted search for it and a prime's grant passed.
- `stow/claude/dot-claude/settings.json`: register the cap hook on `Skill|Bash`, and drop the ask rule on
  `agent-slot grant-review`, so a prime can grant. The verb still refuses with `review-grant-from-slot` from a slot's
  directory, and from a pane on the slot tmux server that is not a prime's.
- `stow/claude/dot-claude/slot-scope-guard.sh` and its tests: find `git push` after `timeout` with options, such as the
  skill's documented `timeout -s INT -k 30 1500 git push`, which the guard did not check against the brief's
  `Touches:`.
- `scripts/agent-slot/lib/reviewgrant.sh`, `lib/help.sh`, `lib/launch.sh`, and the README review-cap section: the new
  wording (one round, a second on a P0 or P1, the prime may grant).
- `stow/claude/dot-claude/CLAUDE.md`:
  - a short "Code reviews" rule covering R1, R4, R5, R6, and R7, pointing at the agent-slot skill's
    `references/slot-rules.md` § Reviews for the tables;
  - the R8 bullet.
- `stow/claude/dot-claude/ci-watch-prompt.sh`: print each `gh run watch` under a `timeout`, one watcher per run.

### agent-skills (one PR off `main`)

- `agent-slot/SKILL.md`:
  - the `Reviews:` brief line, and a `Touches:` line that lists the task's plan doc;
  - "At most 2 review rounds", now R1 and R2;
  - "Run the reviews as the brief names them", which points at `slot-rules.md` for recording and the command;
  - R7 under "The brief is the scope".
  - The slot SessionStart hook reads these rules from this file, so slots get them with no code change. The section
    stays small enough that a foreign-head slot's start context, the largest, keeps them inline under the hook's
    9,500-character limit.
- `agent-slot/references/slot-rules.md` § Reviews: the two tables (their single source), the three places each review is
  recorded (R4), how a second round reviews only round 1's P0 and P1 fixes, and a review command that takes the effort
  and bound from the table and keeps the skill name on the command line, where the cap hook counts it.
- `agent-slot/references/coordinate.md`: the prime keeps the round count from the slot's messages and may grant a round
  past the cap.

### Memory files (local, not in any repo)

These state the old rules, so they are updated to match:

- agent-skills: `feedback_review_stack`, `feedback_brief_is_the_scope`, `feedback_no_outstanding_items_on_pr`.
- dotfiles: `feedback_brief_is_the_scope`, `feedback_pr_never_merges_with_open_items`.
- lmgroktfy: `pr-scope-brief-only-two-rounds`.
- xurl-rs: `feedback_draft_until_reviews_done`.
- Their `MEMORY.md` index lines.

## Verification

- `bats tests/slot-review-cap.bats` and `tests/slot-scope-guard.bats`. Each new case is seen failing against the code
  without its change.
- The slot-context hook, run against the new `SKILL.md`, inlines the rules for a normal and a foreign-head slot.
- The full dotfiles pre-push gate, and agent-skills' markdownlint and prose gate.
- `rg` over the changed rule files and the memory files finds no remaining "2 review rounds", "at most 2 rounds", or
  all-`xhigh` review rule.

## Not in scope

- A new `agent-slot review` verb that runs and counts reviews.
- A hook that reads finding severity.
- A fail-fast CI watch tool.
- Changes to `ce-code-review`, `/devex-review`, or `/cso`.
- Other repos' docs and runbooks, such as xurl-rs's release runbook watchers.

## Reviews of this work

- This plan: one plan review, `/compound-engineering:ce-doc-review`. The plan is a process and gate change whose main
  risk is unclear or conflicting rules across many files, which that review's coherence, feasibility, and scope-guardian
  lenses check.
- Each PR: one `ce-code-review` round on Opus at `high`.
- dotfiles PR: one `/devex-review` on Opus at `high`, since who may run `agent-slot grant-review`, its refusal, and the
  cap hook's deny messages change.
- No `/cso`: a grant appends one ledger line, and the cap is a guard against an agent's mistakes, not a trust boundary.

## Review log

| # | Review | Of | Model, effort | Started (UTC) | Finished (UTC) | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `ce-doc-review` | this plan at `5f9dac6` | Opus, `high` | 2026-11-09 19:33 | 2026-11-09 19:51 | 4 P1, 9 P2, 1 P3, 4 decisions; each fixed or decided in this plan |
| 2 | `ce-code-review` | agent-skills#239 at `036acb1` | Opus, `high` | 2026-11-09 20:04 | 2026-11-09 20:09 | stopped to add the review-before-polish rule; rerun below |
| 3 | `ce-code-review` | dotfiles#485 at `617047b` | Opus, `high` | 2026-11-09 20:04 | 2026-11-09 20:09 | stopped to add the review-before-polish rule; rerun below |
| 4 | `/devex-review` | dotfiles#485 at `617047b` | Opus, `high` | 2026-11-09 20:04 | 2026-11-09 20:13 | 6/10, no P0; 1 P1 (the cap counts non-review commands), 3 P2, 5 P3; fixes follow |
| 5 | `ce-code-review` | agent-skills#239 at `ab6a19d` | Opus, `high` | 2026-11-09 20:09 | 2026-11-09 20:11 | stopped to bar polish after the reviews too; rerun below |
| 6 | `ce-code-review` | dotfiles#485 at `4d76a55` | Opus, `high` | 2026-11-09 20:09 | 2026-11-09 20:11 | stopped to bar polish after the reviews too; rerun below |
| 7 | `ce-code-review` | agent-skills#239 at `8deecbe` | Opus, `high` | 2026-11-09 20:11 | | running |
| 8 | `ce-code-review` | dotfiles#485 at `3df9310` | Opus, `high` | 2026-11-09 20:11 | | running |
