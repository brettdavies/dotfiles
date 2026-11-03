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
  opens nothing; pass commits the new `package.toml` on `fix/yazi-pins-<yazi-version>` from the base branch, opens a PR
  whose body fills the repo's PR template, waits on CI under D6, squash-merges, and confirms the PR is `MERGED`.
- R6. An open PR from an earlier bump blocks a new one: the outcome is `failed` with reason `pr-open` and the PR's link.
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
- **Run log.** `run_log_start` sets `RUN_YAZI_PINS=null`; `run_log_finish` appends `"yazi_pins":$RUN_YAZI_PINS`. The
  bump prints its outcome as one JSON object on its last stdout line; `brew.sh` validates it with `jaq` before storing
  it, and records `failed`/`bad-output` when it is missing or malformed.

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
  wait (D6), `gh pr merge --squash --delete-branch`, confirm `MERGED`. Prints the outcome object last. Scratch dirs and
  the tmux server go away on every exit path.
- **Tests first** (`tests/yazi-pins.bats`), with `gh`, `ya`, and the check stubbed and a local bare repo as `--repo`:
  `not-needed` (hashes equal, check passes), `waiting` (hashes equal, check fails, newer commits exist), `failed`
  `check-failed`, `bumped` (branch pushed to the bare repo with the new revs and hashes, PR created against the base,
  merged after a green rollup), `ci-failed`, `ci-timeout`, `pr-open`, and no backwards move (D3).

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
