#!/usr/bin/env bats
# The markdownlint config's `ignores` globs gate the whole auto-format hook.
#
# markdownlint-cli2 applies them itself, so step 3 always honored them. The
# prose wrapper and table aligner take a path and rewrite it, so an ignored
# file was still reformatted by steps 1 and 2. That reflowed the shared
# solutions repo and re-wrapped generated artifacts whose emitting tool owns
# their line breaks.

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO_SRC/stow/claude/dot-claude/auto-format.sh"

  # Deliberately NOT under /tmp: the hook skips scratch paths before any
  # formatting step, so a /tmp sandbox makes every assertion here pass without
  # the hook doing anything. TMPDIR is cleared for the same reason.
  unset TMPDIR
  _sandbox_root="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-tests"
  mkdir -p "$_sandbox_root"
  TMP=$(mktemp -d "$_sandbox_root/auto-format.XXXXXX")

  # A sandbox HOME so the hook resolves its helpers and global config here.
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  cp "$REPO_SRC/stow/claude/dot-claude/md-wrap.py" "$HOME/.claude/md-wrap.py"
  chmod +x "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC/stow/claude/dot-markdownlint-cli2.yaml" "$HOME/.markdownlint-cli2.yaml"

  export CLAUDE_PROJECT_DIR="$TMP/project"
  mkdir -p "$CLAUDE_PROJECT_DIR/docs/solutions"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

LONG='This is a deliberately long prose line that runs past one hundred and twenty characters so any wrapper reaching it would split the line in two.'

# write_md PATH: a heading plus one over-length prose line.
write_md() {
  printf '# Heading\n\n%s\n' "$LONG" >"$CLAUDE_PROJECT_DIR/$1"
}

# run_hook PATH: feed the hook a PostToolUse payload for that file.
run_hook() {
  jq -n --arg f "$CLAUDE_PROJECT_DIR/$1" '{tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1 || true
}

line_count() {
  wc -l <"$CLAUDE_PROJECT_DIR/$1" | tr -d ' '
}

@test "an ignored generated artifact is left unwrapped" {
  write_md CHANGELOG.md
  run_hook CHANGELOG.md
  [ "$(line_count CHANGELOG.md)" -eq 3 ]
  grep -qF "$LONG" "$CLAUDE_PROJECT_DIR/CHANGELOG.md"
}

@test "an ignored directory is left unwrapped" {
  write_md docs/solutions/note.md
  run_hook docs/solutions/note.md
  [ "$(line_count docs/solutions/note.md)" -eq 3 ]
  grep -qF "$LONG" "$CLAUDE_PROJECT_DIR/docs/solutions/note.md"
}

@test "an ignored suffix glob is left unwrapped" {
  write_md bundle.min.md
  run_hook bundle.min.md
  [ "$(line_count bundle.min.md)" -eq 3 ]
}

@test "a normal file is still wrapped" {
  # The control: the gate must exclude the listed paths, not disable the hook.
  write_md README.md
  run_hook README.md
  [ "$(line_count README.md)" -gt 3 ]
}

@test "a repo-local ignores list is honored too" {
  printf 'ignores:\n  - "vendored/**"\n' >"$CLAUDE_PROJECT_DIR/.markdownlint-cli2.yaml"
  mkdir -p "$CLAUDE_PROJECT_DIR/vendored"
  write_md vendored/upstream.md
  run_hook vendored/upstream.md
  [ "$(line_count vendored/upstream.md)" -eq 3 ]
}
