#!/usr/bin/env bats
# Tests for git hooks in .githooks/
#
# Run: bats tests/git-hooks.bats

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
