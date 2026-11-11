#!/usr/bin/env bats
# The auto-format hook runs nothing in a slot whose head is another person's fork, because its formatters can load code
# from the tree they run in. Measured: bunx runs the tree's node_modules/.bin/prettier, markdownlint-cli2 loads the
# tree's .markdownlint.cjs, and rustup's rustfmt shim runs the tree's rustfmt when rust-toolchain.toml names the absolute
# path of a toolchain the tree holds, which a slot's predictable path makes easy to write. The formatters stubbed here
# stand for all of them.
#
# Run: bats tests/auto-format-foreign-head.bats
# run-tests: parallel

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/auto-format.sh"
  T=$BATS_TEST_TMPDIR
  CALLS=$T/calls.log
  : >"$CALLS"
  export CLAUDE_PROJECT_DIR=$T/project
  git init -q "$CLAUDE_PROJECT_DIR"
  printf 'module.exports = {};\n' >"$CLAUDE_PROJECT_DIR/.prettierrc.js"
  printf '{}\n' >"$CLAUDE_PROJECT_DIR/pyproject.toml"
  mkdir -p "$T/bin"
  local tool
  for tool in bunx markdownlint-cli2 ruff rustfmt shfmt rubocop; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$tool" "$CALLS" >"$T/bin/$tool"
    chmod +x "$T/bin/$tool"
  done
  PATH=$T/bin:$PATH
}

edit() {
  : >"$CLAUDE_PROJECT_DIR/$1"
  jq -n --arg f "$CLAUDE_PROJECT_DIR/$1" '{tool_input: {file_path: $f}}' | "$HOOK" >/dev/null
}

@test "outside a foreign head, an edit reaches the formatter for its type" {
  edit a.js
  grep -q '^bunx prettier --write ' "$CALLS"
  edit a.md
  grep -q '^markdownlint-cli2 ' "$CALLS"
  edit a.rb
  grep -q '^rubocop ' "$CALLS"
  edit a.rs
  grep -q '^rustfmt ' "$CALLS"
}

@test "in a foreign head's slot, no edit reaches any formatter" {
  printf '{"head_foreign": true}\n' >"$CLAUDE_PROJECT_DIR/.git/agent-slot.json"
  local file
  for file in a.js a.json a.yml a.md a.py a.rs a.sh a.rb; do edit "$file"; done
  [ ! -s "$CALLS" ]
}

@test "a file in a foreign head's slot reaches no formatter when another project's Claude edits it" {
  local slot=$T/foreign-slot
  git init -q "$slot"
  printf '{"head_foreign": true}\n' >"$slot/.git/agent-slot.json"
  : >"$slot/a.md"
  jq -n --arg f "$slot/a.md" '{tool_input: {file_path: $f}}' | "$HOOK" >/dev/null
  [ ! -s "$CALLS" ]
}

@test "a slot's record without the field leaves the formatters on" {
  printf '{"head_foreign": false}\n' >"$CLAUDE_PROJECT_DIR/.git/agent-slot.json"
  edit a.md
  grep -q '^markdownlint-cli2 ' "$CALLS"
}

@test "a file outside a foreign slot's git directory reaches no formatter when that slot's Claude edits it" {
  printf '{"head_foreign": true}\n' >"$CLAUDE_PROJECT_DIR/.git/agent-slot.json"
  git init -q "$T/elsewhere"
  : >"$T/elsewhere/a.json"
  jq -n --arg f "$T/elsewhere/a.json" '{tool_input: {file_path: $f}}' | "$HOOK" >/dev/null
  [ ! -s "$CALLS" ]
}
