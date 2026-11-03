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

- **Objective:** yazi keeps upgrading daily through the brew job, and the installed plugins follow it without a person.
  Every host installs what `package.toml` pins on every daily run. When the Linux server's yazi differs from the
  version its pins were last proven against, the job bumps the pins itself through a merged PR to `dev` and
  fast-forwards its own checkout when that is safe. Hosts run broken plugins only while no fixing upstream commit has
  cleared the seven-day gate.
- **Product authority:** the operator, through the `rex-linux` session: auto-upgrade, auto-fix, nothing upstream, and
  pull when safe (D7).
- **Open blockers:** none.

---

## Product Contract

### Summary

Two additions to `scripts/upgrade/brew.sh`. On both operating systems it runs `ya pkg install --discard` after the
upgrade, so installed plugins match `package.toml`.
On the Linux server it runs a pin bump whenever the installed yazi differs from
the version the pins were last proven against: the bump resolves the newest upstream revisions past the seven-day
supply-chain gate, installs them into a scratch HOME to get ya's hashes, proves them by running yazi in a private tmux
server, and opens, waits on, and squash-merges a PR to `dev`, then fast-forwards the host checkout when it can. Every
outcome is a field of the run log's `run.end`.

### Problem Frame

Homebrew upgrades yazi daily and unattended, while plugins move only when someone edits `package.toml` and runs
`ya pkg install --discard`. yazi 26.8 replaced the fetcher API and the pinned git.yazi failed on every directory
until #399
repinned it by hand. The same drift recurs on the next breaking yazi release unless the job that upgrades the binary
also moves the plugins.

### Key Decisions

- **D1. The trigger is the installed yazi version against a proven stamp.** The bump writes the yazi version to
  `$YAZI_PINS_STATE_DIR/yazi-pins-proven` only on `bumped` or `not-needed`; `brew.sh` runs the bump on Linux whenever
  `yazi --version` differs from that stamp, and a missing stamp counts as different. This covers the run that upgraded
  yazi, an upgrade made outside the job (a manual `bu` or `brew upgrade`), and every retry after a `waiting` or `failed`
  outcome or a run the unit killed mid-bump, with no separate marker.
- **D2. One rev per upstream repo, gated by GitHub's push time.** The candidate is the commit an entry of the repo's
  activity log (push, force push, or merge) left on the default branch at least seven days ago and that is still on
  that branch. Commit dates are not used for the gate, because whoever pushes a commit sets them. One rev per repo is
  what `ya pkg upgrade` records and what #399 pinned; a rev that moved only because an unrelated plugin in the same
  repo changed leaves ya's hash unchanged, so the bump compares hashes, not revs, to decide whether anything changed.
  The gate applies even when the current pins are broken: the brief sets it, and the cost is a window in which hosts
  run broken plugins until a fix has been upstream for seven days.
- **D3. A pin never moves backwards.** When the current rev already contains the candidate (`compare` reports the
  current rev ahead or identical), the dep keeps its current rev.
- **D4. The check runs yazi for real.** Scratch HOME holding the candidate config, a private tmux server
  (`tmux -L yazi-pins-check-<pid>`), and a generated git repo holding an untracked file and a Markdown file. Pass means
  no `Failed` task, no `N left` counter, git.yazi's sign beside the untracked file, and the Markdown file previewed
  through piper and glow. Parsing the captured panes is a separate function, so the suite tests it against #399's
  captures without yazi or tmux.
- **D5. The bump works in a fresh clone of the base branch, never `~/dotfiles`.** It reads `package.toml` and the yazi
  config from that clone and commits there. Commits sign through the global git config's headless path;
  `GIT_TERMINAL_PROMPT=0`, `GH_PROMPT_DISABLED=1`, `GIT_EDITOR=true`, and `ssh -o BatchMode=yes` turn any prompt into
  a failure.
- **D6. The CI wait is bounded and keeps the branch mergeable.** It polls the PR until every check is `SUCCESS`,
  `SKIPPED`, or `NEUTRAL` and the merge state is `CLEAN`, up to `YAZI_PINS_CI_TIMEOUT` (default 30 minutes), inside
  the unit's `TimeoutStartSec=2h`. `dev`'s ruleset requires an up-to-date branch, so a `BEHIND` PR is updated with
  `gh pr update-branch`; the new head is trusted only when it is a merge commit whose parents include the head the job
  pushed, and the merge is pinned to it with `--match-head-commit`.
- **D7. Pull when safe.** After the job's own bump PR merges, it runs `git -C ~/dotfiles pull --ff-only` only when that
  checkout is on the base branch, letting git refuse a pull that would overwrite a local edit, then
  `ya pkg install --discard`.
  Any other state leaves the checkout alone and names the pull command as `next_step`. The pull also brings everything
  else merged to `dev` since the last pull, and the post-merge hook restows `claude` and `secrets`; the operator
  accepted both.

### Requirements

- R1. `brew.sh` runs `ya pkg install --discard` after the upgrade on Linux and macOS when `ya` is on PATH. ya's
  output lines become `info` events; a non-zero exit adds one `warning` event,
  `Warning: ya pkg install exited <n>; installed yazi packages may not match package.toml. Rerun: ya pkg install --discard`,
  and the run's outcome still follows the upgrade alone. Without `--discard`, ya refuses to replace an installed package
  whose files differ from the hash `package.toml` records, which an older pin's files always do, so a plain install
  moves nothing on a host that already has the packages.
- R2. On Linux, when the installed yazi version differs from the proven stamp (D1), `brew.sh` runs the bump and records
  its outcome. On macOS it never runs the bump.
- R3. The bump clones the base branch, resolves each `package.toml` dep's candidate rev under D2 and D3, installs the
  candidates into a scratch HOME with empty hashes, and reads back the hashes ya records.
- R4. When every candidate hash equals the current hash, the bump checks those pins: pass is `not-needed`. When a hash
  changed, it checks the candidates: pass leads to R5. A failed candidate check is followed by a check of the current
  pins, and their pass is `not-needed` with the rejected candidates named in `value`. When no check passes, the outcome
  is `waiting` if a pinned dep's own directory upstream has a commit newer than the cutoff, else `failed`
  (`check-failed`). Nothing is opened in any of these cases.
- R5. A passing changed candidate is committed on `fix/yazi-pins-<yazi-version>-<UTC yyyymmdd>` from the base branch,
  as ya wrote it. The bump opens a PR whose body fills the repo's PR template, waits on CI under D6, squash-merges with
  `--match-head-commit`, confirms the PR is `MERGED`, and pulls under D7.
- R6. The bump records the URL and head SHA of the PR it opens. An open `fix/yazi-pins-*` PR whose URL and head match
  that record is resumed when its branch names the installed yazi version (wait, merge, pull), and closed with its
  branch deleted before a fresh bump when it names another version. Any other open `fix/yazi-pins-*` PR ends the run
  `failed` with reason `pr-open`, without merging.
- R7. `run.end` gains `yazi_pins`: `null` when the run did not bump, else
  `{outcome, reason, exit_code, message, value, yazi_version, pr, host_update, next_step {action, command, docs}}`.
  `outcome` is `bumped | not-needed | waiting | failed`. `reason` is `pr-merged` for `bumped`, `up-to-date` for
  `not-needed`, `cooldown` for `waiting`, and for `failed` one of `check-failed`, `upstream-unreachable`, `git-failed`,
  `hash-failed`, `gh-failed`, `ci-failed`, `ci-timeout`, `merge-failed`, `pr-open`, `bad-output` (set by `brew.sh` for
  a missing or malformed outcome line), and `script-error` (a run killed mid-bump). `exit_code` is the bump's; `value`
  is the offending value or `null`. `host_update` is `null` unless the bump merged, else
  `{action (pulled | skipped | failed), reason (ok | no-checkout | not-on-base | pull-failed | install-failed),
  checkout, message}`. `next_step.action` is `none | pull | rerun | inspect-pr`, its `command` a verbatim headless
  command, and its `docs` `BOOTSTRAP.md#yazi-plugin-pins`. A `waiting` or `failed` outcome also emits one `warning`
  output event. No existing field changes.
- R8. The bump is runnable by hand: `scripts/upgrade/yazi-pins.sh [--base BRANCH] [--repo URL] [--gh-repo OWNER/NAME]
  [--checkout PATH]`, with `--help`. It prints the outcome object as its last stdout line and progress on stderr, and
  exits 0 for `bumped`/`not-needed`, 75 for `waiting`, 1 for `failed`, and 2 for a usage error.

### Success Criteria

- A brew run that upgrades nothing still installs plugins, and a failed install is a warning, not a failed run.
- With yazi changed and the pins already good, the run log says `not-needed` and writes the stamp.
- Against a throwaway base branch pinned to old revs, run in the unit's environment, the bump opens a PR, CI passes,
  the PR merges into that branch, and the run log says `bumped` with the link. The exercise's branch is deleted
  afterwards.

### Scope Boundaries

- No change to the systemd unit, the timer, or the LaunchAgent (`stow/local/` and `stow/launchagent/` stay as they
  are). The unit's PATH already puts Homebrew's `gh`, `git`, `tmux`, and `yazi` first.
- No upstream contribution, no plugin forks, no pins for plugins `package.toml` does not already list.
- No dry-run mode: the manual entry point runs the same path as the job.
- `uv-tools.sh` gets the new `yazi_pins` field as `null` through the shared library and nothing else.

---

## Planning Contract

### Key Technical Decisions

- **Files.** `scripts/upgrade/lib/yazi.sh` holds what `brew.sh` calls (`yazi_pkg_install`, `yazi_pins_after_upgrade`).
  `scripts/upgrade/yazi-pins.sh` is the bump's entry point and flow; `scripts/upgrade/lib/yazi-pins-lib.sh` holds its
  upstream, install, and CI helpers; `scripts/upgrade/lib/yazi-pins-pr.sh` writes the commit message and PR body; and
  `scripts/upgrade/lib/yazi-check.sh` holds the tmux check and the pane verdict.
- **Seams.** `YAZI_PINS_CMD` (the bump `brew.sh` runs), `YAZI_PINS_CHECK_CMD` (the check the bump runs),
  `YAZI_PINS_STATE_DIR` (stamp, PR record, and saved check capture; default
  `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles`), `YAZI_PINS_CI_TIMEOUT`, `YAZI_PINS_POLL_S`, `YAZI_PINS_NOW`, and
  `--repo`/`--gh-repo`/`--checkout` (a local bare repo and fixture checkout in tests), following the
  `STOW_DEPLOY_TARGET` precedent of overrides a suite points at a sandbox.
- **Upstream lookups** go through `gh api`: `repos/<o>/<r>` for the default branch,
  `repos/<o>/<r>/activity?ref=refs/heads/<branch>` for push times, `compare/<a>...<b>` for ancestry (the gated
  candidate is still on the branch; D3), and `commits?path=<dep>.yazi&since=<cutoff>&per_page=1` for "a pinned dep has
  a newer commit". `gh`'s built-in `--jq` does the JSON work, so the bump needs no JSON tool.
- **Hashes** come from ya alone: write the candidate `package.toml` with `hash = ""`, run `ya pkg install` under the
  scratch HOME, read the file back. #399 showed ya fills an empty hash and rewrites the file in place. What the PR
  commits is ya's own output, never a hand-formatted file.
- **Parsing `package.toml`** is an awk pass over its `[[plugin.deps]]`/`[[flavor.deps]]` blocks and their `use`,
  `rev`, and `hash` lines. ya writes the file, so its shape is fixed.
- **Run log.** `run_log_start` sets `RUN_YAZI_PINS=null`; `run_log_finish` appends `"yazi_pins":$RUN_YAZI_PINS`.
  Before starting the bump, `brew.sh` sets `RUN_YAZI_PINS` to a `failed`/`script-error` object, so a run killed
  mid-bump still reports it. The bump sources `run-log.sh` for `_run_log_str` and prints its outcome object as its last
  stdout line; `brew.sh` accepts that line only when it starts with `{"outcome":"` and one of the four outcomes, and
  otherwise records `failed`/`bad-output`.

### Sequencing

U1 (run-log field and `ya pkg install`) lands first in the branch and is independently useful. U2 (pane verdict and
check) and U3 (bump) follow. U4 wires the bump into `brew.sh`. U5 documents. U6 is the end-to-end exercise.

## Implementation Units

### U1. `ya pkg install` in the brew job, and the `yazi_pins` field

- `scripts/upgrade/lib/yazi.sh`: `yazi_pkg_install` streams ya's output as `info` events and notes one warning on a
  non-zero exit. `brew.sh` calls it after `run_log_upgrade`, on both OSes.
- `scripts/upgrade/lib/run-log.sh`: `RUN_YAZI_PINS`, appended to `run.end`; schema comment updated.
- **Tests first** (`tests/scheduled-upgrades.bats`): the brew job runs `ya pkg install --discard` after `bu` with a
  `ya` stub;
  a failing stub yields a `warning` event and a `success` run; `run.end` carries `"yazi_pins": null` on a run that did
  not bump, for both jobs.

### U2. The check

- `scripts/upgrade/lib/yazi-check.sh`: `yazi_check_verdict <listing> <preview> <tasks>` prints `ok` or a reason
  (`failed-fetchers`, `pending-fetchers`, `no-git-sign`, `no-preview`); `yazi_check <home> <out-dir>` builds the repo,
  runs yazi in a private tmux server, waits for the listing to settle, hovers the Markdown file, opens the task view,
  captures each, and kills the server on every exit path. The bump keeps the last captures at
  `$YAZI_PINS_STATE_DIR/yazi-pins-check.txt` and names that path in `value` when a check fails.
- **Tests first** (`tests/yazi-pins.bats`): the verdict against #399's captures (failed tasks, pending fetchers, no
  sign, no rendered preview, and a clean run). The live tmux path runs in U6 and was run against #399's scratch HOMEs:
  the old pins gave `failed-fetchers`, the new pins `ok`.

### U3. The bump

- `scripts/upgrade/yazi-pins.sh` and its libraries: resume or close an earlier PR (R6); clone the base; parse
  `package.toml`; resolve candidates (D2, D3); install them into a scratch HOME; check (R4); and for a bump commit,
  push, `gh pr create`, wait (D6), merge, and pull (D7). Prints the outcome object last; scratch dirs and the tmux
  server go away on every exit path.
- **Tests first** (`tests/yazi-pins.bats`), with `gh`, `ya`, `yazi`, and the check stubbed, a local bare repo as
  `--repo`, and a fixture checkout as `--checkout`: `not-needed` (hashes equal, check passes); candidate fails but
  current pins pass (`not-needed`, candidate named); `waiting` (both fail, a pinned dep has a newer commit); `failed`
  `check-failed` (both fail, nothing newer); `bumped` (branch pushed to the bare repo with ya's revs and hashes, PR
  against the base, merge pinned to the pushed head, fixture checkout fast-forwarded); `bumped` with the checkout on
  another branch (`skipped`, pull in `next_step`); a `BEHIND` PR updated and merged at the new head; `ci-failed`;
  `ci-timeout`; a recorded PR for the installed yazi resumed and merged; a recorded PR for an older yazi closed and
  replaced; an unrecorded PR (`pr-open`); a candidate older than the current rev kept (D3).

### U4. Wire the bump into `brew.sh`

- `yazi_pins_after_upgrade`: Linux only; runs when `yazi --version` differs from the stamp; sets the `script-error`
  placeholder, runs `timeout` + `YAZI_PINS_CMD`, logs the bump's stderr as `info` events, validates and stores the
  outcome, and emits the warning for `waiting`/`failed`. The stamp is the bump's to write.
- **Tests first:** a Linux run with yazi differing from the stamp runs the bump stub and logs its outcome; a matching
  stamp skips it; a missing stamp runs it; a `waiting` outcome emits the warning; a malformed outcome line is
  `failed`/`bad-output`; macOS never bumps.

### U5. Document it

- `BOOTSTRAP.md`'s scheduled-upgrades section gains a "yazi plugin pins" subsection: the steps, the stamp, the outcomes
  and reasons, the manual rerun, and the `yazi_pins` query.
- `stow/yazi/dot-config/yazi/yazi.toml` header: the brew job installs and bumps the pins as well as the deploy.

### U6. End-to-end exercise

Push a throwaway branch `test/yazi-pins-e2e` cut from `dev` with `package.toml` pinned to #399's predecessor revs.
Run `scripts/upgrade/yazi-pins.sh --base test/yazi-pins-e2e --checkout <scratch clone on that branch>` through
`systemd-run --user --wait --pipe` with the `brew-upgrade.service` PATH, and `YAZI_CONFIG_HOME` pointed at a scratch
config, so neither `~/dotfiles` nor `~/.config/yazi` is touched. Confirm candidate resolution, the scratch install and
hashes, the live tmux check, the PR to the throwaway base, green CI, the squash merge, and the scratch checkout's pull.
Then delete the throwaway branch, and quote the outcome in the PR body. The `bats` workflow has no branch filter, so CI
runs for a PR into any base; the throwaway base has no ruleset, so the `BEHIND` path stays covered by U3's tests.

## Verification Contract

- Every new test observed failing against the unfixed code first, quoted in the PR body.
- `scripts/lint-shell`, `scripts/core-env-guard.sh`, and `scripts/run-tests` on the touched suites, then the pre-push
  mirror.
- U6 run once against the real GitHub repo and a real yazi, in the unit's environment, with its PR merged into the
  throwaway base and cleaned up.

## Definition of Done

- PR to `dev` merged with every check `SUCCESS` by the rollup.
- `rex-linux` has the PR links (#399 and this one), the first failing test runs, and the U6 outcome.

## Decision ledger

- D1-D6: settled from the brief, the existing code (`run-log.sh` schema rules, `brew-upgrade.service` timeout and
  PATH, `bats.yml` triggers, `protect-dev.json` required checks and its strict up-to-date policy), the GitHub activity
  API, and #399's measurements.
- D7: the operator chose B, "pull when safe", through `rex-linux` on 2026-11-02.
- E1-E4 (Eng Review), X1-X5 (DX Review), and the Doc Review dispositions below are applied above.

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
  `yazi-pins.sh` holding the check would pass 300 lines and mix two jobs, so the original three-file arrangement stands.
  **Scope accepted as-is.**
- **Search.** Renovate and Dependabot cover neither `ya pkg` nor a yazi-run proof; the repo already carries its own
  supply-chain gate (the seven-day cooldown in `config/shell/supply-chain.sh`). [Layer 1: reuse the repo's own run log
  and gate conventions.]

### Reality rows

- REALITY: premise-table pass unverified=0 (yazi upgrades through brew: `brew list --versions yazi` = 26.9.1; `changes`
  names packages by brew name: `run-log.sh` `run_log_changes`; unit PATH puts Homebrew first:
  `stow/local/dot-config/systemd/user/brew-upgrade.service` `Environment=PATH=`; start timeout 2h: same file
  `TimeoutStartSec=2h`; `dev` requires `shellcheck` and `bats`: `.github/rulesets/protect-dev.json`; CI runs for any
  base: `.github/workflows/bats.yml` `pull_request:` with no branch filter; `gh` auth from `hosts.yml`:
  `gh auth status`)
- REALITY: already-done pass (origin/dev at 5106ada holds no yazi pin automation; #399 added only the deploy step)
- REALITY: surface-check pass (`commits?until=`/`since=` answered for yazi-rs/plugins and yazi-rs/flavors;
  `gh pr merge --squash --delete-branch --match-head-commit`, `gh pr create --body-file --head --repo` in `--help`)
- REALITY: binding-decisions pass (the operator's "auto-upgrade, auto-fix" choice via `rex-linux`; D7 answered by the same
  session)
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
├── ya pkg install --discard (both OSes) .. stub ok → info lines; stub fail → 1 warning, run success   [U1]
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

`ya pkg install` re-fetches every package each run: about 40 s a day on each host [measured]. The bump costs one scratch
install (1-3 min) plus CI (about 1.5 min) [measured], only on runs that upgrade yazi or retry. Both are fine for a daily
background job.

### Failure modes

| Failure                             | Handling                                      | Outcome                                                                     |
| ----------------------------------- | --------------------------------------------- | --------------------------------------------------------------------------- |
| GitHub API or clone unreachable     | no PR                                         | `failed` (`upstream-unreachable` / `git-failed`), marker kept               |
| scratch `ya pkg install` fails      | no PR                                         | `failed` (`hash-failed`), marker kept                                       |
| check fails                         | no PR                                         | `waiting` when newer upstream commits exist, else `failed` (`check-failed`) |
| `gh pr create` fails after the push | branch left, dated name frees tomorrow's      | `failed` (`gh-failed`)                                                      |
| CI red                              | PR left open                                  | `failed` (`ci-failed`), resumed or reported `pr-open` next run              |
| CI slower than the cap              | PR left open                                  | `failed` (`ci-timeout`), resumed next run (E2)                              |
| unit start timeout kills the run    | `run.end` reason `script-error` from the trap | marker kept, retried                                                        |

Failure modes: 0 critical gaps flagged.

### Outside voice

Skipped: the slot runs unattended and `/compound-engineering:ce-doc-review` gives this plan an independent pass next.

### NOT in scope

Changing the unit, timer, or LaunchAgent. Pins for plugins `package.toml`
does not list.

### Worktree parallelization

Sequential: U1-U5 touch the same two library files and one suite, and U6 needs them all.

### Unresolved decisions

- None: D7 (pull after merge) was answered B, "pull when safe", by `rex-linux`.

### Completion summary

Scope accepted as-is; 4 findings in Sections 1-4 (1 critical, 3 informational), all accepted and applied to the plan; 0
critical gaps in failure modes; premise table unverified=0.


## DX Review

Run unattended in agent slot dotfiles/3; every choice below was made from the code, the repo's docs, and #399's
evidence, with no question sent to a person. Product type: CLI tool and scheduled automation (the surface is
`scripts/upgrade/yazi-pins.sh` and the run log's `yazi_pins`). Mode: **DX POLISH**, since this extends an existing
job. Web research was not run; comparisons below use in-distribution knowledge only.

### Developer Persona Card

```text
TARGET DEVELOPER PERSONA
========================
Who:       an agent (or the operator) reading the brew job's run log, often the coordinating session
Context:   the morning after Homebrew upgraded yazi, or when yazi's git column looks wrong
Tolerance: one query and one command; it cannot ask what a message meant
Expects:   a stable reason, the PR link, and a verbatim next command, as every other run.end field gives
```

### Developer Empathy Narrative

I query the run log the way `run-log.sh`'s header says (`journalctl --user -t brew-upgrade -o cat | jaq ...`). Today a
yazi upgrade shows up only as a `changes` entry, and nothing tells me the plugins are now broken; I learn it from 76
failed tasks in yazi. With this plan, `run.end.yazi_pins` says `bumped` with the PR, `waiting` with when to expect the
gate to open, or `failed` with the reason, the offending deps or check verdict, and the command to rerun. The one thing
I could still miss is the pull (D7): `bumped` is not the same as installed on this host, so `next_step` has to say so.

### Competitive DX Benchmark

| Tool | Start → result | Time + evidence type | DX choice | Source |
| --- | --- | --- | --- | --- |
| Renovate / Dependabot | dependency release → merged PR | hours to days, reported | PRs with age gates and auto-merge on green | in-distribution knowledge |
| `ya pkg upgrade` by hand | notice breakage → repinned | 30+ min, observed (#399) | manual, no gate, no proof | this session |
| This plan | yazi upgrade → `yazi_pins` outcome | one daily run, estimated | gated, proven in yazi, merged on green, logged | plan R1-R8 |

Target: Champion for the persona's clock (one query to a decision), which R7 meets.

### Magical Moment Specification

The morning after a breaking yazi release, `run.end.yazi_pins` reads `bumped` with a merged PR, and nobody saw a failed
fetcher. Vehicle: the existing run log, no new channel.

### Developer Journey Map

```text
STAGE           | DEVELOPER DOES                                  | FRICTION POINTS                 | STATUS
----------------|-------------------------------------------------|---------------------------------|-------
1. Discover     | reads BOOTSTRAP.md scheduled-upgrades section   | yazi steps undocumented today   | fixed (U5)
2. Install      | nothing: brew job already scheduled             | none                            | ok
3. Hello World  | one jaq query for run.end.yazi_pins             | query not documented            | fixed (U5)
4. Real Usage   | reads outcome, follows next_step                | pull after bump (D7)            | fixed (next_step names it)
5. Debug        | reruns yazi-pins.sh, reads the saved check pane | no dry run, no saved capture    | fixed (X3, X4)
6. Upgrade      | nothing: schema only adds fields                | none                            | ok
```

### First-Time Developer Confusion Report

```text
T+0:00  Queries run.end, sees yazi_pins: waiting. Needs to know until when.  → message names the newest commit's date
T+0:30  Sees failed/check-failed. Needs to see what yazi showed.             → value names the saved pane capture (X4)
T+1:00  Wants to retry by hand without opening a PR.                         → --dry-run (X3)
T+2:00  Sees bumped, but yazi on this host still fails.                      → next_step: pull, then ya pkg install --discard
```

### Passes

| Pass | Before | After | Note |
| --- | --- | --- | --- |
| 1 Getting started | 6 | 9 | documented query and manual entry point (U5, R8) |
| 2 CLI design | 5 | 8 | `--help`, `--dry-run`, distinct exit codes (X2, X3) |
| 3 Errors | 5 | 8 | error-contract fields `exit_code` and `value` (X1); see matrix |
| 4 Docs | 5 | 8 | BOOTSTRAP section with reasons and queries (U5) |
| 5 Upgrade | 9 | 9 | additive schema change only |
| 6 Tooling | 6 | 8 | dry run, saved check capture, test seams |
| 7 Ecosystem | n/a | n/a | private dotfiles; no community surface |
| 8 Measurement | 7 | 8 | every outcome is a queryable run-log field |

```text
ERROR PATH MATRIX (agent-ready-v1)
Path                   | Class       | what | fix  | recovery | code | context | trace | redaction | channel | Cap
ya pkg install fails   | dependency  | pass | pass | pass     | pass | pass    | N/A   | pass      | pass    | -
check fails            | partial     | pass | pass | pass     | pass | pass    | pass  | pass      | pass    | - (after X4)
CI red on bump PR      | partial     | pass | pass | pass     | pass | pass    | N/A   | pass      | pass    | -
bump crashes/killed    | unexpected  | pass | pass | pass     | pass | pass    | pass  | pass      | pass    | -
```

Before X1 the plan had no offending value or exit code (CAP6 on `check fails`: context); before X4 a failed check left
nothing to inspect (CAP6: trace). Corrected line: `{"outcome":"failed","reason":"check-failed","exit_code":1,
"value":"failed-fetchers; pane ~/.local/state/dotfiles/yazi-pins-check.txt",...}`. No secret reaches the log: `gh` and
`git` read credentials from their own config and nothing echoes them.

### Decisions

- X1 accepted: `yazi_pins` carries `exit_code` and `value` (R7), meeting the repo's error contract.
- X2 accepted: `--help` and exit codes 0 / 75 / 1 / 2 (R8).
- X3 accepted: `--dry-run` with outcome `would-bump` for manual runs (R8).
- X4 accepted: the check saves its last pane capture and names it (U2).
- X5 accepted: the `ya pkg install` warning wording, starting `Warning:` so the run log counts it (R1).

### DX Scorecard

Overall 6/10 → 8/10. TTHW for the persona's clock: one query, under 2 minutes [estimated].

### Unresolved Decisions

- None: D7 was answered B by `rex-linux`.


## Doc Review

`/compound-engineering:ce-doc-review` in non-interactive mode, run unattended in agent slot dotfiles/3. Reviewers:
coherence, feasibility, scope-guardian, adversarial (no validated upstream contract; unattended merges), and
security-lens (push and merge credentials; third-party plugin code). Coverage: all five returned. The cross-model pass
was skipped: it would send this repo's plan to a third-party model, and nobody in the unattended slot could sanction
that egress.

| Finding | Reviewer | Disposition |
| --- | --- | --- |
| A behind PR never turns `CLEAN` under `dev`'s strict up-to-date rule | feasibility, adversarial | applied: D6 updates the branch and pins the merge to the verified new head |
| The gate reads pusher-set commit dates | security | applied: D2 gates on the activity log's push time |
| Resume merges any `fix/yazi-pins-*` PR by name | security | applied: R6 resumes only the recorded URL and head |
| A resumed PR may carry pins checked against an older yazi | adversarial | applied: R6 closes and replaces it |
| `changes` misses yazi upgrades made outside the job | adversarial | applied: D1 triggers on the version stamp |
| A failed candidate is reported as breakage when current pins work | adversarial | applied: R4 checks the current pins |
| Repo-wide "newer commits" makes `failed` nearly unreachable | adversarial | applied: path-scoped per pinned dep |
| The check covers only git.yazi | adversarial | applied: D4 adds the piper preview; a broken flavor has no capture to test against, so it is not checked |
| Parse before clone reads the stale host checkout | feasibility | applied: D5 and R3 clone first |
| Objective promises no person while D7 left the pull out | coherence, scope-guardian | applied: D7 answered B |
| `would-bump` missing from the outcome set; dry run beyond the brief | coherence, scope-guardian | applied: dry run removed; exit codes kept |
| A run killed mid-bump has no `yazi_pins` | coherence | applied: `script-error` placeholder set before the bump |
| No reason for the success outcomes | coherence | applied: `pr-merged`, `up-to-date` |
| U6 runs in the slot's environment, not the unit's | adversarial | applied: U6 runs under `systemd-run --user` with the unit's PATH |
| The seven-day gate leaves #399-type breakage live for days | adversarial | kept: the brief sets the gate; the window is stated in the Goal Capsule and D2 |

Residual risks, recorded rather than fixed: the check runs candidate plugin code as the job's user, beside the `gh`
token and signing key (the same code runs on every host once merged, so the check moves that exposure earlier rather
than adding a new one); and a yazi release that changes how ya records hashes would make every host's daily
`ya pkg install` rewrite its `package.toml`, which then blocks D7's pull until someone commits or resets it.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | not run | — |
| Outside Review | none | Independent 2nd opinion | 0 | skipped (unattended) | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 4 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | not run | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 1 | ISSUES OPEN | score: 6/10 → 8/10, TTHW: one query → one query under 2 min |

- **OUTSIDE COVERAGE:** outside voice and the cross-model doc-review pass were skipped in this unattended run; no
  external provider ran.
- **VERDICT:** Eng, DX, and doc reviews ran; every finding is applied or recorded with its reason, and D7 is answered.

NO UNRESOLVED DECISIONS
