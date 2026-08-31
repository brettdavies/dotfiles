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
