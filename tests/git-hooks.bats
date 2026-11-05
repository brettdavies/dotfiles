#!/usr/bin/env bats
# Tests for git hooks in .githooks/
#
# Run: bats tests/git-hooks.bats

bats_require_minimum_version 1.5.0

HOOKS_DIR="$BATS_TEST_DIRNAME/../.githooks"

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "pre-commit passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" ".githooks/pre-commit"
  [ "$status" -eq 0 ]
}

@test "post-checkout passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" ".githooks/post-checkout"
  [ "$status" -eq 0 ]
}

@test "post-merge passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" ".githooks/post-merge"
  [ "$status" -eq 0 ]
}

@test "pre-push passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" ".githooks/pre-push"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "all hooks are executable" {
  for hook in pre-commit post-checkout post-merge pre-push; do
    [ -x "$HOOKS_DIR/$hook" ]
  done
}

@test "all hooks use bash shebang" {
  for hook in pre-commit post-checkout post-merge pre-push; do
    head -1 "$HOOKS_DIR/$hook" | grep -q "bash"
  done
}

@test "all hooks use strict mode" {
  for hook in pre-commit post-checkout post-merge; do
    grep -q "set -euo pipefail" "$HOOKS_DIR/$hook"
  done
}

# ---------------------------------------------------------------------------
# pre-commit / pre-push symmetry
#
# The two gates differ only in scope: pre-commit checks staged paths, pre-push
# checks the repository. Everything else — which checks run, how they report,
# how they are scheduled — is shared, so a change to one cannot silently leave
# the other behind.
# ---------------------------------------------------------------------------

@test "both gates route their checks through the same scripts" {
  for script in lint-shell lint-workflows run-tests core-env-guard.sh; do
    grep -q "scripts/$script" "$HOOKS_DIR/pre-commit"
    grep -q "scripts/$script" "$HOOKS_DIR/pre-push"
  done
}

@test "both gates report through the shared library" {
  for hook in pre-commit pre-push; do
    grep -q 'lib/report\.sh' "$HOOKS_DIR/$hook"
  done
}

@test "both gates schedule through the shared library" {
  for hook in pre-commit pre-push; do
    grep -q 'gate_begin' "$HOOKS_DIR/$hook"
    grep -q 'gate_spawn' "$HOOKS_DIR/$hook"
    grep -q 'gate_collect' "$HOOKS_DIR/$hook"
  done
}

@test "neither gate carries its own copy of a shared helper" {
  # A local redefinition is how the two drift apart: the hook keeps working, so
  # nothing fails, and the shared library quietly stops being the one source.
  for hook in pre-commit pre-push; do
    run grep -nE '^[[:space:]]*gate_[a-z]+\(\)' "$HOOKS_DIR/$hook"
    [ "$status" -ne 0 ]
  done
}

@test "the shared library defines every gate helper the hooks call" {
  local lib="$HOOKS_DIR/lib/report.sh"
  for fn in gate_header gate_pass gate_skip gate_fail gate_done \
    gate_begin gate_end gate_spawn gate_collect; do
    grep -qE "^$fn\(\)" "$lib"
  done
}

# ---------------------------------------------------------------------------
# Gate output through a non-blocking pipe
#
# git starts ssh before it runs pre-push, and ssh makes the stderr it shares
# with git non-blocking, so `git push 2>&1 | tail` hands the hook a pipe in that
# state. The gate logs still have to reach a reader that falls behind.
# ---------------------------------------------------------------------------

@test "a gate log reaches a slow reader whole through a pipe ssh left non-blocking" {
  command -v perl >/dev/null 2>&1 || skip "perl not installed"
  local writer="$BATS_TEST_TMPDIR/writer" out="$BATS_TEST_TMPDIR/out"
  cat >"$writer" <<'EOF'
set -euo pipefail
perl -MFcntl -e 'fcntl(STDOUT, F_SETFL, fcntl(STDOUT, F_GETFL, 0) | O_NONBLOCK) or die "fcntl: $!\n"'
. "$1/lib/report.sh"
gate_begin
gate_spawn big seq 1 100000
wait
gate_collect big "big gate" "big gate failed"
EOF
  # The reader starts once the writer has filled the pipe.
  run bash -c 'bash "$1" "$2" | { sleep 1; cat >"$3"; }; exit "${PIPESTATUS[0]}"' \
    _ "$writer" "$HOOKS_DIR" "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$out")" -eq 100001 ]
  [ "$(tail -n 1 "$out")" = "  ✓ big gate" ]
}

@test "a failing perl does not stop a hook from sourcing the gate library" {
  local stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 1\n' >"$stubs/perl"
  chmod +x "$stubs/perl"
  run env PATH="$stubs:$PATH" bash -c 'set -euo pipefail; . "$1/lib/report.sh"; echo sourced' _ "$HOOKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced" ]
}

# ---------------------------------------------------------------------------
# pre-commit: branch protection
# ---------------------------------------------------------------------------

@test "pre-commit blocks commits on main" {
  grep -q 'branch.*=.*"main"' "$HOOKS_DIR/pre-commit"
}

@test "pre-commit verifies gpgsign" {
  grep -q 'commit.gpgsign' "$HOOKS_DIR/pre-commit"
}

# ---------------------------------------------------------------------------
# post-checkout / post-merge: git-crypt auto-unlock
# ---------------------------------------------------------------------------

@test "post-checkout uses sentinel-based git-crypt check" {
  grep -q 'sentinel=' "$HOOKS_DIR/post-checkout"
  grep -q 'grep -qI' "$HOOKS_DIR/post-checkout"
}

@test "post-merge uses sentinel-based git-crypt check" {
  grep -q 'sentinel=' "$HOOKS_DIR/post-merge"
  grep -q 'grep -qI' "$HOOKS_DIR/post-merge"
}

@test "post-checkout chains Git LFS" {
  grep -q 'git lfs post-checkout' "$HOOKS_DIR/post-checkout"
}

@test "post-merge chains Git LFS" {
  grep -q 'git lfs post-merge' "$HOOKS_DIR/post-merge"
}

@test "pre-push chains Git LFS" {
  grep -q 'git lfs pre-push' "$HOOKS_DIR/pre-push"
}

# ---------------------------------------------------------------------------
# core.hooksPath
# ---------------------------------------------------------------------------

@test "core.hooksPath is set to .githooks" {
  # stow-deploy sets this on first deploy. On a fresh CI checkout it's
  # unset and the hooks aren't active — skip rather than misreport.
  hookspath=$(git -C "$BATS_TEST_DIRNAME/.." config --get core.hooksPath 2>/dev/null || true)
  [ -n "$hookspath" ] || skip "core.hooksPath not set (CI checkout without stow-deploy)"
  [ "$hookspath" = ".githooks" ]
}

# ---------------------------------------------------------------------------
# pre-commit: the shell-startup perf suite
#
# The suite times the shells' startup files, so a commit that changes none of
# them has nothing for it to measure. The stubs record each gate script call,
# in start order, in $FIX/calls.
# ---------------------------------------------------------------------------

_commit_fixture() {
  FIX="$BATS_TEST_TMPDIR/fix"
  WORK="$FIX/work"
  mkdir -p "$WORK/.githooks/lib" "$WORK/scripts" "$FIX/bin"
  git init -q -b dev "$WORK"
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name test
  git -C "$WORK" config commit.gpgsign true
  git -C "$WORK" config core.hooksPath /dev/null
  cp "$HOOKS_DIR/pre-commit" "$WORK/.githooks/pre-commit"
  cp "$HOOKS_DIR"/lib/*.sh "$WORK/.githooks/lib/"
  local s t
  for s in lint-shell lint-workflows run-tests core-env-guard.sh; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"%s/calls"\n' "$s" "$FIX" >"$WORK/scripts/$s"
    chmod +x "$WORK/scripts/$s"
  done
  for t in shellcheck actionlint bats; do
    printf '#!/bin/sh\nexit 0\n' >"$FIX/bin/$t"
    chmod +x "$FIX/bin/$t"
  done
  mkdir -p "$WORK/tests/perf" "$WORK/config/shell"
  : >"$WORK/tests/perf/shell-startup-perf.bats"
  : >"$WORK/tests/other.bats"
  : >"$WORK/config/shell/fragment.sh"
  git -C "$WORK" add -A
  git -C "$WORK" -c commit.gpgsign=false commit -qm seed
}

_precommit() {
  run bash -c 'cd "$1" && PATH="$2:$PATH" .githooks/pre-commit' _ "$WORK" "$FIX/bin"
}

_touch() {
  local f
  for f in "$@"; do
    printf '# %s\n' "$RANDOM" >>"$WORK/$f"
    git -C "$WORK" add "$f"
  done
}

_called() { grep -qx -- "$1" "$FIX/calls"; }

@test "pre-commit: a staged perf suite with no startup file staged is not run" {
  _commit_fixture
  _touch tests/perf/shell-startup-perf.bats
  _precommit
  [ "$status" -eq 0 ]
  [[ "$output" == *"no staged path is on SHELL_STARTUP_PATHS"* ]]
  [[ "$output" == *"no staged test files besides the perf suite"* ]]
  [ ! -e "$FIX/calls" ] || ! grep -q 'run-tests' "$FIX/calls"
}

@test "pre-commit: a staged perf suite with a startup file staged runs alone through --perf-only" {
  _commit_fixture
  _touch tests/perf/shell-startup-perf.bats config/shell/fragment.sh
  _precommit
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$FIX/calls")" = "run-tests --perf-only" ]
  run ! grep -E '^run-tests .*tests/perf' "$FIX/calls"
}

@test "pre-commit: a staged perf suite never rides the parallel batch" {
  _commit_fixture
  _touch tests/perf/shell-startup-perf.bats tests/other.bats
  _precommit
  [ "$status" -eq 0 ]
  _called 'run-tests tests/other.bats'
  run ! grep -E '^run-tests .*tests/perf' "$FIX/calls"
}

@test "pre-commit: a staged startup file alone leaves the other gates as they were" {
  _commit_fixture
  _touch config/shell/fragment.sh tests/other.bats
  _precommit
  [ "$status" -eq 0 ]
  _called 'run-tests tests/other.bats'
  run ! _called 'run-tests --perf-only'
}

@test "pre-commit: a deleted startup file counts as staged for the perf suite" {
  _commit_fixture
  git -C "$WORK" rm -q config/shell/fragment.sh
  _touch tests/perf/shell-startup-perf.bats
  _precommit
  [ "$status" -eq 0 ]
  _called 'run-tests --perf-only'
}

@test "pre-commit: a startup file moved away counts as staged for the perf suite" {
  _commit_fixture
  mkdir -p "$WORK/scripts/lib"
  git -C "$WORK" mv config/shell/fragment.sh scripts/lib/fragment.sh
  _touch tests/perf/shell-startup-perf.bats
  _precommit
  [ "$status" -eq 0 ]
  _called 'run-tests --perf-only'
}

@test "pre-commit: a failing perf suite fails the commit" {
  _commit_fixture
  printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/run-tests"
  _touch tests/perf/shell-startup-perf.bats config/shell/fragment.sh
  _precommit
  [ "$status" -eq 1 ]
}

@test "pre-commit: a staged startup file alone says the timing runs at pre-push" {
  _commit_fixture
  _touch config/shell/fragment.sh
  _precommit
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell-startup timing (runs at pre-push)"* ]]
  [ ! -e "$FIX/calls" ] || ! grep -q 'run-tests' "$FIX/calls"
}

@test "pre-commit: a commit that stages no startup file and no perf suite says nothing of the timing" {
  _commit_fixture
  _touch tests/other.bats
  _precommit
  [ "$status" -eq 0 ]
  [[ "$output" != *"shell-startup timing"* ]]
}

@test "pre-commit: a perf suite that ran is reported as passed" {
  _commit_fixture
  _touch tests/perf/shell-startup-perf.bats config/shell/fragment.sh
  _precommit
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ shell-startup timing"* ]]
}
