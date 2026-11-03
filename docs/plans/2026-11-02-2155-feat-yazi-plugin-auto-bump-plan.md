---
title: Yazi Plugin Auto-Bump - Plan
type: feat
date: 2026-11-02
topic: yazi-plugin-auto-bump
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Yazi Plugin Auto-Bump - Plan

## Goal Capsule

- **Objective:** yazi keeps upgrading daily through the brew job, and the installed plugins keep working without anyone
  noticing an upgrade. Every host installs what `package.toml` pins on every daily run, and when Homebrew upgrades yazi
  on the Linux server, the job bumps the pins itself through a merged PR to `dev`.
- **Product authority:** the operator, through the `rex-linux` session. The operator chose auto-upgrade and auto-fix;
  nothing goes upstream.
- **Open blockers:** none. One decision is open with `rex-linux` (D7) and defaults to its recommended option.

---

## Product Contract

### Summary

Two additions to `scripts/upgrade/brew.sh`. On both operating systems it runs `ya pkg install` after the upgrade, so
installed plugins match `package.toml`. On the Linux server it runs a pin bump whenever a run upgrades yazi, or a
previous bump is still pending: the bump resolves the newest upstream commits past the seven-day supply-chain gate,
installs them into a scratch HOME to get ya's hashes, proves them by running yazi in a private tmux server, and opens,
waits on, and squash-merges a PR to `dev`. Every outcome is a field of the run log's `run.end`.

### Problem Frame

Homebrew upgrades yazi daily and unattended, while plugins move only when someone edits `package.toml` and runs
`ya pkg install`. yazi 26.8 replaced the fetcher API and the pinned git.yazi failed on every directory until #399
repinned it by hand. The same drift recurs on the next breaking yazi release unless the job that upgrades the binary
also moves the plugins.

### Key Decisions

- **D1. The trigger is the run's `changes` naming yazi, or a pending marker.** The brief names `changes`; `changes`
  names yazi only on the one run that upgraded it, so a bump that waits or fails would never retry. The bump writes a
  marker before it starts and removes it only on `bumped` or `not-needed`, so a wait, a failure, and a run the unit's
  start timeout kills all retry on the next daily run.
- **D2. One rev per upstream repo: its newest commit at least seven days old.** That is what `ya pkg upgrade` records
  (the repo's HEAD) and what #399 pinned. A rev that moved only because an unrelated plugin in the same repo changed
  leaves ya's hash unchanged, so the bump compares hashes, not revs, to decide whether anything changed.
- **D3. A pin never moves backwards.** When the current rev is newer than the gated candidate (a pin someone set by hand
  inside the seven days), the dep keeps its current rev.
- **D4. The check runs yazi for real.** Scratch HOME holding the candidate config, a private tmux server
  (`tmux -L yazi-pins-<pid>`), a generated git repo, and the task view: pass means no `Failed` task, no `N left`
  counter, and a git sign rendered beside the untracked file. Parsing the captured pane is a separate function, so the
  suite tests it against the captures from #399 without yazi or tmux.
- **D5. The bump works in a fresh clone in a scratch directory, never `~/dotfiles`.** Commits sign through the global
  git config's headless path; `GIT_TERMINAL_PROMPT=0`, `GH_PROMPT_DISABLED=1`, and `ssh -o BatchMode=yes` turn any
  prompt into a failure.
- **D6. The CI wait is bounded inside the bump.** It polls the PR's check rollup until every check is `SUCCESS` and the
  merge state is `CLEAN`, up to `YAZI_PINS_CI_TIMEOUT` (default 30 minutes), and the whole bump runs under `timeout`
  (default 60 minutes), both well inside the unit's `TimeoutStartSec=2h`.
- **D7. The job does not pull `~/dotfiles` (open with `rex-linux`, defaulting to this).** A merged bump reaches a host
  on its next pull; the run log's `next_step` names that pull. The alternative (fast-forward a clean `dev` checkout
  after the merge) adds one guarded step and does not change anything else in this plan.

### Requirements

- R1. `brew.sh` runs `ya pkg install` after the upgrade on Linux and macOS when `ya` is on PATH. ya's output lines
  become `info` events; a non-zero exit adds one `warning` event naming the exit status and the rerun command, and the
  run's outcome still follows the upgrade alone.
- R2. On Linux, when the run's `changes` name yazi or a pending marker exists, `brew.sh` runs the bump and records its
  outcome. On macOS it never runs the bump.
- R3. The bump resolves each `package.toml` dep's candidate rev under D2 and D3, installs the candidates into a scratch
  HOME with empty hashes, and reads back the hashes ya records.
- R4. When every candidate hash equals the current hash, the bump runs the check against those pins: pass is
  `not-needed`; fail is `waiting` when any pinned upstream repo has commits newer than the cutoff, else `failed`.
- R5. When a hash changed, the bump runs the check against the candidates: fail is `waiting` or `failed` as in R4 and
  opens nothing; pass commits the new `package.toml` on `fix/yazi-pins-<yazi-version>-<UTC yyyymmdd>` from the base
  branch, opens a PR whose body fills the repo's PR template, waits on CI under D6, squash-merges with
  `--match-head-commit` set to the head CI passed on, and confirms the PR is `MERGED`.
- R6. An open PR from an earlier bump (head branch `fix/yazi-pins-*`) is resumed rather than duplicated: the bump waits
  on its checks under D6 and merges it when they pass; red checks end `failed` with reason `pr-open` and the PR's link.
- R7. `run.end` gains `yazi_pins`: `null` when the run did not bump, else
  `{outcome, reason, message, yazi_version, pr, next_step {action, command, docs}}`. `outcome` is
  `bumped | not-needed | waiting | failed`; `reason` is a closed kebab-case set; `next_step.action` is
  `none | pull | rerun | inspect-pr`. A `waiting` or `failed` outcome also emits one `warning` output event. No existing
  field changes.
- R8. The bump is also runnable by hand (`scripts/upgrade/yazi-pins.sh [--base BRANCH] [--repo URL]`) and prints the
  same outcome object on stdout, so a person can rerun or prove it outside the brew job.

### Success Criteria

- A brew run that upgrades nothing still installs plugins, and a failed install is a warning, not a failed run.
- With yazi upgraded and pins already good, the run log says `not-needed` and clears the marker.
- Against a throwaway base branch pinned to an old rev, the bump opens a PR, CI passes, the PR merges into that branch,
  and the run log says `bumped` with the link. The exercise's branch and PR are deleted or closed afterwards.

### Scope Boundaries

- No change to the systemd unit, the timer, or the LaunchAgent (`stow/local/` and `stow/launchagent/` stay as they are).
  The unit's PATH already puts Homebrew's `gh`, `git`, `tmux`, and `yazi` first.
- No upstream contribution, no plugin forks, no pins for plugins `package.toml` does not already list.
- `uv-tools.sh` gets the new `yazi_pins` field as `null` through the shared library and nothing else.

---

## Planning Contract

### Key Technical Decisions

- **Files.** `scripts/upgrade/lib/yazi.sh` holds what `brew.sh` calls (`yazi_pkg_install`, `yazi_pins_after_upgrade`).
  `scripts/upgrade/yazi-pins.sh` is the bump (entry point and PR flow). `scripts/upgrade/lib/yazi-check.sh` holds the
  tmux check and the pane verdict. Each stays near or under 200 lines.
- **Seams.** `YAZI_PINS_CMD` (the bump `brew.sh` runs), `YAZI_PINS_CHECK_CMD` (the check the bump runs),
  `YAZI_PINS_STATE_DIR` (marker location, default `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles`),
  `YAZI_PINS_CI_TIMEOUT`, `YAZI_PINS_POLL_S`, and `--repo` (a local bare repo in tests), following the
  `STOW_DEPLOY_TARGET` precedent of overrides a suite points at a sandbox.
- **Upstream lookups** go through `gh api`: `repos/<o>/<r>/commits?until=<cutoff>&per_page=1` for the candidate,
  `commits/<rev>` for the current rev's date, and `commits?since=<cutoff>&per_page=1` for "newer commits exist".
- **Hashes** come from ya alone: write the candidate `package.toml` with `hash = ""`, run `ya pkg install` under the
  scratch HOME, read the file back. #399 showed ya fills an empty hash and rewrites the file in place.
- **Parsing `package.toml`** is an awk pass over its `[[plugin.deps]]`/`[[flavor.deps]]` blocks and their `use`, `rev`,
  and `hash` lines. ya writes the file, so its shape is fixed, and the bump hands ya the candidate file and commits what
  ya writes back, never its own formatting. No TOML tool joins the dependencies.
- **Run log.** `run_log_start` sets `RUN_YAZI_PINS=null`; `run_log_finish` appends `"yazi_pins":$RUN_YAZI_PINS`. The
  bump sources `run-log.sh` for `_run_log_str` and builds its outcome object with it, printed as its last stdout line.
  `brew.sh` accepts that line only when it starts with `{"outcome":"` and one of the four outcomes, and otherwise
  records `failed` with reason `bad-output`, so `brew.sh` needs no JSON tool either.

### Sequencing

U1 (run-log field and `ya pkg install`) lands first in the branch and is independently useful. U2 (pane verdict and
check) and U3 (bump) follow. U4 wires the bump into `brew.sh`. U5 documents. U6 is the end-to-end exercise.

## Implementation Units

### U1. `ya pkg install` in the brew job, and the `yazi_pins` field

- `scripts/upgrade/lib/yazi.sh`: `yazi_pkg_install` streams ya's output as `info` events and notes one warning on a
  non-zero exit. `brew.sh` calls it after `run_log_upgrade`, on both OSes.
- `scripts/upgrade/lib/run-log.sh`: `RUN_YAZI_PINS`, appended to `run.end`; schema comment updated.
- **Tests first** (`tests/scheduled-upgrades.bats`): the brew job runs `ya pkg install` after `bu` with a `ya` stub; a
  failing stub yields a `warning` event and a `success` run; `run.end` carries `"yazi_pins": null` on macOS and on a
  Linux run that did not upgrade yazi.

### U2. The check

- `scripts/upgrade/lib/yazi-check.sh`: `yazi_check_pane <file>` prints `ok` or a reason (`failed-fetchers`,
  `pending-fetchers`, `no-git-sign`); `yazi_check <home>` builds the demo repo, runs yazi in a private tmux server,
  waits for the listing, opens the task view, captures, and kills the server on every exit path.
- **Tests first** (`tests/yazi-pins.bats`): `yazi_check_pane` against the #399 captures (failed tasks → reason, clean
  view → `ok`, a listing without the sign → `no-git-sign`). The live tmux path is exercised in U6.

### U3. The bump

- `scripts/upgrade/yazi-pins.sh`: parse `package.toml` (`use`, `rev`, `hash` per dep), resolve candidates (D2, D3),
  compute hashes in a scratch HOME, decide (R4, R5), and for a bump: clone, branch, commit, push, `gh pr create`, CI
  wait (D6), `gh pr merge --squash --delete-branch --match-head-commit <sha>`, confirm `MERGED`. Prints the outcome
  object last. Scratch dirs and the tmux server go away on every exit path.
- **Tests first** (`tests/yazi-pins.bats`), with `gh`, `ya`, and the check stubbed and a local bare repo as `--repo`:
  `not-needed` (hashes equal, check passes), `waiting` (hashes equal, check fails, newer commits exist), `failed`
  `check-failed`, `bumped` (branch pushed to the bare repo with the new revs and hashes, PR created against the base,
  merged with the pushed head's SHA after a green rollup), `ci-failed`, `ci-timeout`, an open earlier PR resumed and
  merged when green, an open earlier PR with red checks (`pr-open`), and no backwards move (D3).

### U4. Wire the bump into `brew.sh`

- `yazi_pins_after_upgrade`: Linux only; triggers on `changes` naming yazi or the marker; writes the marker, runs
  `timeout` + `YAZI_PINS_CMD`, stores the outcome, emits the warning for `waiting`/`failed`, clears the marker on
  `bumped`/`not-needed`.
- **Tests first:** a run whose `changes` include yazi runs the bump stub and logs its outcome; a run without the yazi
  change and without a marker does not; a marker alone triggers it; a `waiting` outcome keeps the marker; macOS never
  bumps.

### U5. Document it

- `BOOTSTRAP.md`'s scheduled-upgrades section: the yazi steps, the marker, the manual rerun, and the `yazi_pins` query.
- `stow/yazi/dot-config/yazi/yazi.toml` header: the brew job installs and bumps the pins as well as the deploy.

### U6. End-to-end exercise

Push a throwaway branch `test/yazi-pins-e2e` cut from `dev` with `package.toml` pinned to #399's predecessor revs, run
`scripts/upgrade/yazi-pins.sh --base test/yazi-pins-e2e` from this slot, and confirm: candidate resolution, scratch
install and hashes, the live tmux check, the PR to the throwaway base, green CI, the squash merge, and the outcome
object. Then delete the throwaway branch. Quote the outcome in the PR body. The `bats` workflow has no branch filter, so
CI runs for a PR into any base.

## Verification Contract

- Every new test observed failing against the unfixed code first, quoted in the PR body.
- `scripts/lint-shell`, `scripts/core-env-guard.sh`, and `scripts/run-tests` on the touched suites, then the pre-push
  mirror.
- U6 run once against the real GitHub repo and a real yazi, with its PR merged into the throwaway base and cleaned up.

## Definition of Done

- PR to `dev` merged with every check `SUCCESS` by the rollup.
- `rex-linux` has the PR links (#399 and this one), the first failing test run, and the U6 outcome.

## Decision ledger

- D1-D6: settled from the brief, the existing code (`run-log.sh` schema rules, `brew-upgrade.service` timeout and PATH,
  `bats.yml` triggers, `protect-dev.json` required checks), and #399's measurements.
- D7: sent to `rex-linux` 2026-11-02 with options A (leave the pull to the operator, recommended) and B (fast-forward a
  clean `dev` checkout after the merge). The plan follows A until an answer arrives.
- E1-E4: decided in the Eng Review below; each is applied to the requirements above.

## Eng Review

Run unattended in agent slot dotfiles/3: every question below was answered from the code, the repo's docs, and this
session's measurements, and the choice is recorded with its evidence. No question went to a person.

### Scope Challenge

- **What already solves each sub-problem.** `run_log_upgrade` already computes `changes`
  (`scripts/upgrade/lib/run-log.sh`, `run_log_changes`), so the yazi trigger reads `RUN_CHANGES` rather than listing
  versions again. `_run_log_str` already escapes JSON strings. `ya pkg install` already computes hashes and writes them
  back. `gh pr merge --match-head-commit` already pins a merge to a head (`gh pr merge --help`). Nothing in the repo
  already resolves upstream revs or drives yazi in tmux.
- **Minimum change.** R1 alone fixes drift between hosts and `package.toml`; R2-R7 are what makes the fix automatic.
  Both are in the brief, so neither is deferred.
- **Complexity.** About 10 files: 3 new scripts, `brew.sh`, `run-log.sh`, 1 new suite and its fixtures, the existing
  upgrade suite, `BOOTSTRAP.md`, `yazi.toml` [estimated]. The gate trips at 8 files. Structure question: one
  `yazi-pins.sh` holding the check would pass 300 lines and mix two jobs, so the original three-file arrangement
  stands. **Scope accepted as-is.**
- **Search.** Renovate and Dependabot cover neither `ya pkg` nor a yazi-run proof; the repo already carries its own
  supply-chain gate (the seven-day cooldown in `config/shell/supply-chain.sh`). [Layer 1: reuse the repo's own run log
  and gate conventions.]

### Reality rows

- REALITY: premise-table pass unverified=0 (yazi upgrades through brew: `brew list --versions yazi` = 26.9.1; `changes`
  names packages by brew name: `run-log.sh` `run_log_changes`; unit PATH puts Homebrew first:
  `stow/local/dot-config/systemd/user/brew-upgrade.service` `Environment=PATH=`; start timeout 2h: same file
  `TimeoutStartSec=2h`; `dev` requires `shellcheck` and `bats`: `.github/rulesets/protect-dev.json`; CI runs for any
  base: `.github/workflows/bats.yml` `pull_request:` with no branch filter; `gh` auth from `hosts.yml`: `gh auth
  status`)
- REALITY: already-done pass (origin/dev at 5106ada holds no yazi pin automation; #399 added only the deploy step)
- REALITY: surface-check pass (`commits?until=`/`since=` answered for yazi-rs/plugins and yazi-rs/flavors;
  `gh pr merge --squash --delete-branch --match-head-commit`, `gh pr create --body-file --head --repo` in `--help`)
- REALITY: binding-decisions pass (the operator's "auto-upgrade, auto-fix" choice via `rex-linux`; D7 open with the
  same session)
- REALITY: numbers pass (CI 81 s [measured: run 41574663201]; repeat `ya pkg install` 40.5 s and first install up to
  about 2.5 min [measured: this session's scratch installs]; 30 min CI cap and 60 min bump cap [estimated], both under
  the unit's 2 h)
- REALITY: deferred-asks pass (no linked issue; the brief's four items map to R1, R2-R6, R7, D5/D6)
- REALITY: pr-count pass (one PR)

### 1. Architecture

- `[CRITICAL] (confidence: 8/10) plan R5 — "waits on CI under D6, squash-merges"`: a merge by PR number takes whatever
  head the PR has at merge time, so a push after the green rollup would merge unchecked content. **E1, accepted:** merge
  with `--match-head-commit` set to the SHA the job pushed and CI passed on (R5).
- `[INFORMATIONAL] (confidence: 8/10) plan R6 — "An open PR from an earlier bump blocks a new one"`: a bump whose CI
  outlived the cap leaves a green PR that every later run reports as `pr-open` until a person merges it. **E2,
  accepted:** resume an open `fix/yazi-pins-*` PR, merging it when green, and report `pr-open` only for red checks (R6).
- `[INFORMATIONAL] (confidence: 7/10) plan R5 — "fix/yazi-pins-<yazi-version>"`: a failed run that pushed its branch
  before `gh pr create` failed leaves the name taken, and the next day's push is rejected. **E3, accepted:** suffix the
  UTC date (R5).
- D1's marker is written before the bump starts, so a run the unit kills mid-bump retries. A permanent failure retries
  daily with a warning each day, which is the visibility wanted; it clears itself once a person fixes the pins.

Dispositions: E1 accepted, E2 accepted, E3 accepted.

### 2. Code quality

- `[INFORMATIONAL] (confidence: 7/10) plan Key Technical Decisions — "brew.sh validates it with jaq"`: `brew.sh` loads
  no JSON tool today, and the bump writes the line itself. **E4, accepted:** a prefix check on the outcome line, and
  `_run_log_str` reused for building it.
- `package.toml` is parsed with awk over ya's own format, and every file the bump commits is ya's own output, so the
  committed file always matches what `ya pkg install` writes on a host (#399 showed a mismatch dirties the checkout).

Dispositions: E4 accepted.

### 3. Tests

```text
brew.sh
├── ya pkg install (both OSes) ............ stub ok → info lines; stub fail → 1 warning, run success   [U1]
├── run.end yazi_pins null (macOS, no yazi change) ...........................................          [U1]
└── yazi_pins_after_upgrade (Linux)
    ├── changes name yazi → bump runs, outcome logged ........................................        [U4]
    ├── marker only → bump runs .........................................................            [U4]
    ├── neither → no bump ...................................................................         [U4]
    ├── waiting/failed → warning event, marker kept; bumped/not-needed → marker cleared .......        [U4]
    └── malformed outcome line → failed/bad-output ............................................       [U4]
yazi-pins.sh
├── not-needed / waiting / check-failed ......................................................        [U3]
├── bumped: branch in bare repo with ya's revs and hashes, PR, green rollup, merge pinned to head .   [U3]
├── ci-failed / ci-timeout ...................................................................        [U3]
├── open earlier PR: green → merged; red → pr-open ...........................................        [U3]
└── current rev newer than candidate → kept (no backwards move) ..............................        [U3]
yazi-check
├── pane verdict: failed tasks / N left / no sign / ok (#399 captures) ...........................    [U2]
└── live tmux run ............................................................ U6 only (needs yazi)
end to end against a throwaway base on GitHub ..................................................     [U6]
```

Every new case is observed failing before its code exists. No existing behavior changes besides the added field, and
`_assert_run_log` checks only the shared fields, so no existing test needs a regression case.

### 4. Performance

`ya pkg install` re-fetches every package each run: about 40 s a day on each host [measured]. The bump costs one
scratch install (1-3 min) plus CI (about 1.5 min) [measured], only on runs that upgrade yazi or retry. Both are fine for
a daily background job.

### Failure modes

| Failure | Handling | Outcome |
| --- | --- | --- |
| GitHub API or clone unreachable | no PR | `failed` (`upstream-unreachable` / `git-failed`), marker kept |
| scratch `ya pkg install` fails | no PR | `failed` (`hash-failed`), marker kept |
| check fails | no PR | `waiting` when newer upstream commits exist, else `failed` (`check-failed`) |
| `gh pr create` fails after the push | branch left, dated name frees tomorrow's | `failed` (`gh-failed`) |
| CI red | PR left open | `failed` (`ci-failed`), resumed or reported `pr-open` next run |
| CI slower than the cap | PR left open | `failed` (`ci-timeout`), resumed next run (E2) |
| unit start timeout kills the run | `run.end` reason `script-error` from the trap | marker kept, retried |

Failure modes: 0 critical gaps flagged.

### Outside voice

Skipped: the slot runs unattended and `/compound-engineering:ce-doc-review` gives this plan an independent pass next.

### NOT in scope

Pulling `~/dotfiles` after a merge (D7, open). Changing the unit, timer, or LaunchAgent. Pins for plugins
`package.toml` does not list.

### Worktree parallelization

Sequential: U1-U5 touch the same two library files and one suite, and U6 needs them all.

### Unresolved decisions

- D7 (pull after merge) is open with `rex-linux`; the plan follows option A until it answers.

### Completion summary

Scope accepted as-is; 4 findings in Sections 1-4 (1 critical, 3 informational), all accepted and applied to the plan;
0 critical gaps in failure modes; premise table unverified=0.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | not run | — |
| Outside Review | none | Independent 2nd opinion | 0 | skipped (unattended) | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 4 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | not run | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | not run | — |

- **OUTSIDE COVERAGE:** outside voice skipped in this unattended run; no external provider ran.
- **VERDICT:** Eng Review ran with all 4 findings accepted and applied; one decision (D7) stays open with `rex-linux`.

**UNRESOLVED DECISIONS:**

- D7: whether the bump job pulls `~/dotfiles` after a merge (open with `rex-linux`, plan follows option A)
