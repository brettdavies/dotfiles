#!/usr/bin/env bats
# What the hook forwards to the agent should be only what the agent can act on.
#
# markdownlint-cli2 opens every run with a version banner, a `Finding:` line
# restating the path and every ignore glob, and a `Linting: N file` count. On a
# clean file those three plus `Summary: 0 issues in 0 files` are the whole
# output, so forwarding it spends context on every markdown edit to say
# nothing, and on a file that does have violations the same lines push the
# violations down the report. `0 issues in 0 files` counts files WITH issues,
# not files linted, so it is the clean case rather than a sign nothing ran.

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO_SRC/stow/claude/dot-claude/auto-format.sh"

  # Step 3 is the subject here, so without the linter there is nothing to assert.
  command -v markdownlint-cli2 >/dev/null 2>&1 || skip "markdownlint-cli2 not installed"

  # Deliberately NOT under /tmp: the hook skips scratch paths before any
  # formatting step. TMPDIR is cleared for the same reason.
  unset TMPDIR
  _sandbox_root="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-tests"
  mkdir -p "$_sandbox_root"
  TMP=$(mktemp -d "$_sandbox_root/auto-format-lint.XXXXXX")

  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  cp "$REPO_SRC/stow/claude/dot-claude/md-wrap.py" "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC"/stow/claude/dot-claude/md_wrap_*.py "$HOME/.claude/"
  chmod +x "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC/stow/claude/dot-markdownlint-cli2.yaml" "$HOME/.markdownlint-cli2.yaml"

  export CLAUDE_PROJECT_DIR="$TMP/project"
  mkdir -p "$CLAUDE_PROJECT_DIR"
}

teardown() {
  # setup skips before TMP is set when a tool is missing.
  if [ -n "${TMP:-}" ]; then
    rm -rf "$TMP"
  fi
}

# run_hook PATH: feed the hook a PostToolUse payload and capture its stdout,
# which is the JSON envelope carrying additionalContext, or nothing at all.
run_hook() {
  jq -n --arg f "$1" '{tool_input: {file_path: $f}}' | bash "$HOOK" 2>/dev/null
}

# A heading jumping h1 -> h4 trips MD001, which --fix cannot repair, so it
# survives as a stable unfixable violation.
write_dirty() {
  printf '# Heading\n\n#### Skipped level\n\nok\n' >"$CLAUDE_PROJECT_DIR/dirty.md"
}

write_clean() {
  printf '# Heading\n\nA short clean line.\n' >"$CLAUDE_PROJECT_DIR/clean.md"
}

@test "a clean file reports nothing at all" {
  write_clean
  run run_hook "$CLAUDE_PROJECT_DIR/clean.md"
  [ "$status" -eq 0 ]
  [ -z "${output//[[:space:]]/}" ]
}

@test "a real violation is still reported" {
  write_dirty
  run run_hook "$CLAUDE_PROJECT_DIR/dirty.md"
  [ -n "$output" ]
  ctx=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"MD001"* ]]
  [[ "$ctx" == *"heading-increment"* ]]
}

@test "the violation report drops the banner, Finding, and Linting lines" {
  write_dirty
  run run_hook "$CLAUDE_PROJECT_DIR/dirty.md"
  ctx=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" != *"markdownlint-cli2 v"* ]]
  [[ "$ctx" != *"Finding:"* ]]
  [[ "$ctx" != *"Linting:"* ]]
}

@test "a non-zero issue count keeps its Summary line as the headline" {
  write_dirty
  run run_hook "$CLAUDE_PROJECT_DIR/dirty.md"
  ctx=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Summary: 1 issue in 1 file"* ]]
}
