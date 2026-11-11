#!/usr/bin/env bats
# Runs md-align-tables' Python unit tests (stow/claude/dot-claude/test_md_align_tables.py).
#
# Run: bats tests/md-align-tables.bats
#
# The markdown auto-format hook pipes every edited markdown file through
# md-align-tables.py, so a regression there shows up only as quietly misaligned
# tables. A suite here puts those unit tests behind scripts/run-tests, which CI,
# pre-push, and pre-commit all run.
#
# The script imports wcwidth at load, so without it every case skips and a bare
# `python3 -B` run proves nothing. The suite therefore needs uv to supply
# wcwidth, and skips visibly when uv is missing.

TESTS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/test_md_align_tables.py"

@test "md-align-tables unit tests pass" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed; md-align-tables needs wcwidth"
  run uv run --no-project --with wcwidth python3 -B "$TESTS"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}
