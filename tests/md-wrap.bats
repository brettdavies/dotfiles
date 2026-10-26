#!/usr/bin/env bats
# Runs md-wrap's Python unit tests (stow/claude/dot-claude/test_md_wrap.py).
#
# Run: bats tests/md-wrap.bats
#
# The markdown auto-format hook pipes every edited markdown file through
# md-wrap.py and discards its errors, so a regression there shows up only as
# quietly wrong reflow. A suite here puts those unit tests behind
# scripts/run-tests, which CI, pre-push, and pre-commit all run.

TESTS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/test_md_wrap.py"

@test "md-wrap unit tests pass" {
  run python3 -B "$TESTS"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}
