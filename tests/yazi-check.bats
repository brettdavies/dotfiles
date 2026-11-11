#!/usr/bin/env bats
# The pane verdict of scripts/upgrade/lib/yazi-check.sh, which proves yazi plugin pins in a running yazi.
#
# Run: bats tests/yazi-check.bats
# run-tests: parallel

CHECK_LIB="$BATS_TEST_DIRNAME/../scripts/upgrade/lib/yazi-check.sh"
PANES="$BATS_TEST_DIRNAME/fixtures/yazi-check"

# The pane fixtures are yazi 26.9.1 captures from a scratch tmux server: "broken" ran git.yazi 5d5c480, whose fetcher
# predates yazi 26.8's API, and "good" ran e0bbd20. The preview fixtures hover a Markdown file whose heading glow
# renders without its "#" when piper runs it.

_verdict() {
  # shellcheck disable=SC1090
  . "$CHECK_LIB"
  yazi_check_verdict "$@"
}

@test "a task view listing failed git fetchers fails the check" {
  run _verdict "$PANES/broken-listing.txt" "$PANES/good-preview.txt" "$PANES/broken-tasks.txt"
  [ "$output" = failed-fetchers ]
}

@test "fetchers still pending in the status bar fail the check" {
  run _verdict "$PANES/broken-listing.txt" "$PANES/good-preview.txt" "$PANES/good-tasks.txt"
  [ "$output" = pending-fetchers ]
}

@test "a listing with no git sign beside the untracked file fails the check" {
  run _verdict "$PANES/unsigned-listing.txt" "$PANES/good-preview.txt" "$PANES/good-tasks.txt"
  [ "$output" = no-git-sign ]
}

@test "a Markdown preview not rendered through piper fails the check" {
  run _verdict "$PANES/good-listing.txt" "$PANES/raw-preview.txt" "$PANES/good-tasks.txt"
  [ "$output" = no-preview ]
}

@test "an empty task view, no pending fetchers, the signs, and a rendered preview pass the check" {
  run _verdict "$PANES/good-listing.txt" "$PANES/good-preview.txt" "$PANES/good-tasks.txt"
  [ "$output" = ok ]
}

