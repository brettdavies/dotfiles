#!/usr/bin/env bats
# Tests for scripts/lint-workflows, the shared actionlint dispatcher.
#
# .githooks/pre-commit, .githooks/pre-push, and the ShellCheck workflow all route
# through this script, so a gap here silently weakens every gate.
#
# Run: bats tests/lint-workflows.bats

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/lint-workflows"
PROBE="$BATS_TEST_DIRNAME/../.github/workflows/.lint-probe.yml"

teardown() {
  rm -f "$PROBE"
}

_require_actionlint() {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint not installed"
}

@test "lint-workflows is executable" {
  [ -x "$SCRIPT" ]
}

@test "no arguments is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "--all rejects extra arguments" {
  _require_actionlint
  run "$SCRIPT" --all .github/workflows/bats.yml
  [ "$status" -eq 2 ]
}

@test "--all passes over the current tree" {
  _require_actionlint
  run "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow file(s) clean"* ]]
}

@test "composite actions are filtered out rather than passed to actionlint" {
  _require_actionlint
  # actionlint parses the workflow schema; a composite action is a different
  # shape it rejects outright, so passing one would be an error, not a no-op.
  run "$SCRIPT" .github/actions/setup-shellcheck/action.yml README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 workflow file(s)"* ]]
}

@test "a broken workflow is rejected" {
  _require_actionlint
  # An undefined `needs` reference is an actionlint check with no shellcheck
  # involvement, so this holds whether or not shellcheck is on PATH.
  cat >"$PROBE" <<'PROBEEOF'
name: Lint Probe
on: pull_request
jobs:
  probe:
    runs-on: ubuntu-latest
    needs: [nonexistent-job]
    steps:
      - run: echo hi
PROBEEOF
  run "$SCRIPT" ".github/workflows/$(basename "$PROBE")"
  [ "$status" -eq 1 ]
}

@test "a shell bug inside a run block is caught" {
  _require_actionlint
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck absent, so run: blocks are unchecked"
  # This is the class that found the release.yml glob bug: actionlint delegates
  # `run:` bodies to shellcheck, so an unquoted expansion surfaces here and
  # nowhere else in the gate.
  cat >"$PROBE" <<'PROBEEOF'
name: Lint Probe
on: pull_request
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - run: |
          FOO=bar
          rm -rf $FOO/*
PROBEEOF
  run "$SCRIPT" ".github/workflows/$(basename "$PROBE")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shellcheck"* ]] || [[ "$output" == *"SC"* ]]
}

# The concurrency guard reads every workflow in the checkout it finds with git,
# so these run a copy of both scripts from a scratch repo: a probe group in the
# real .github/workflows/ would fail a parallel --all run.
_scratch_repo() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/.github/workflows"
  cp "$SCRIPT" "$BATS_TEST_DIRNAME/../scripts/check-workflow-concurrency.sh" "$ROOT/scripts/"
  git -C "$ROOT" init -q
}

_probe_workflow() {
  cat >"$ROOT/.github/workflows/probe.yml" <<PROBEEOF
name: Probe
on: pull_request
concurrency:
  group: $1
  cancel-in-progress: true
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
PROBEEOF
}

@test "a concurrency group that starts with an expression is rejected" {
  _require_actionlint
  _scratch_repo
  # Valid to actionlint: inside a called workflow github.workflow is the
  # caller's name, so the collision only the concurrency guard sees.
  _probe_workflow '${{ github.workflow }}-${{ github.ref }}'
  run "$ROOT/scripts/lint-workflows" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe.yml:4 concurrency group starts with an expression"* ]]
}

@test "a concurrency group led by a literal token passes" {
  _require_actionlint
  _scratch_repo
  _probe_workflow 'probe-${{ github.ref }}'
  run "$ROOT/scripts/lint-workflows" .github/workflows/probe.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: every concurrency group is namespaced"* ]]
}

@test "the concurrency guard runs only when a workflow is in scope" {
  _require_actionlint
  _scratch_repo
  # pre-commit passes only staged paths, so a commit that stages no workflow
  # never reaches the guard, even with a bad group already in the tree.
  _probe_workflow '${{ github.workflow }}-${{ github.ref }}'
  run "$ROOT/scripts/lint-workflows" README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 workflow file(s) to check"* ]]
}
