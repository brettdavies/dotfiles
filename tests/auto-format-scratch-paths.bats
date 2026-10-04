#!/usr/bin/env bats
# The auto-format hook's scratch-path gate.
#
# A loose file under /tmp is a transient draft and keeps its authored shape. A
# file inside a git work tree under /tmp is repo content, so a worktree checked
# out there is formatted like any other checkout.

setup() {
  # An inherited GIT_DIR outranks `-C`, so the hook's work-tree probe would read
  # whichever repo the caller was in. Git exports these to hooks.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO_SRC/stow/claude/dot-claude/auto-format.sh"

  # The literal /tmp prefix is the scratch path under test, so the fixtures sit
  # there rather than under $TMPDIR, which may point anywhere.
  TMP=$(mktemp -d /tmp/dotfiles-auto-format.XXXXXX)

  # A sandbox HOME so the hook resolves its helpers and global config here.
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  cp "$REPO_SRC/stow/claude/dot-claude/md-wrap.py" "$HOME/.claude/md-wrap.py"
  chmod +x "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC/stow/claude/dot-markdownlint-cli2.yaml" "$HOME/.markdownlint-cli2.yaml"

  export CLAUDE_PROJECT_DIR="$TMP/project"
  mkdir -p "$CLAUDE_PROJECT_DIR" "$TMP/loose"
  git init -q "$TMP/repo"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

LONG='This is a deliberately long prose line that runs past one hundred and twenty characters so any wrapper reaching it would split the line in two.'

# write_md PATH: a heading plus one over-length prose line.
write_md() {
  mkdir -p "$(dirname "$1")"
  printf '# Heading\n\n%s\n' "$LONG" >"$1"
}

# run_hook PATH: feed the hook a PostToolUse payload for that file.
run_hook() {
  jq -n --arg f "$1" '{tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1 || true
}

line_count() {
  wc -l <"$1" | tr -d ' '
}

@test "a loose file under /tmp keeps its authored shape" {
  write_md "$TMP/loose/draft.md"
  run_hook "$TMP/loose/draft.md"
  [ "$(line_count "$TMP/loose/draft.md")" -eq 3 ]
  grep -qF "$LONG" "$TMP/loose/draft.md"
}

@test "a file in a git work tree under /tmp is formatted" {
  write_md "$TMP/repo/docs/note.md"
  run_hook "$TMP/repo/docs/note.md"
  [ "$(line_count "$TMP/repo/docs/note.md")" -gt 3 ]
}

@test "a file inside the .git directory of a /tmp work tree keeps its shape" {
  # rev-parse answers "false" with a zero exit here, so a status-only probe
  # would treat this file as work-tree content and reformat it.
  write_md "$TMP/repo/.git/draft.md"
  run_hook "$TMP/repo/.git/draft.md"
  [ "$(line_count "$TMP/repo/.git/draft.md")" -eq 3 ]
}
