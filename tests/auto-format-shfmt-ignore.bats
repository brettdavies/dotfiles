#!/usr/bin/env bats
# The auto-format hook's shell arm honors the `.editorconfig` ignore sections.
#
# The canonical `.editorconfig` marks generated shell completions and test data
# `ignore = true`, because a test compares those files byte for byte and a
# generator owns the completions. shfmt applies `ignore` to an explicit path
# only under `--apply-ignore`, so without it a one-line edit to a fixture
# reformats the whole file.

setup() {
  # An inherited GIT_DIR outranks `-C`, so the hook's work-tree probe would read
  # whichever repo the caller was in. Git exports these to hooks.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO_SRC/stow/claude/dot-claude/auto-format.sh"

  # A git work tree, so the hook formats it even when mktemp lands under /tmp.
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  git init -q "$REPO"
  cp "$REPO_SRC/stow/claude/dot-editorconfig" "$REPO/.editorconfig"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

UNFORMATTED=$'if true;then\necho a\nfi\n'
FORMATTED=$'if true; then\n  echo a\nfi\n'

# write_sh PATH: the unformatted script at PATH inside the repo.
write_sh() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s' "$UNFORMATTED" >"$REPO/$1"
}

# run_hook PATH: feed the hook a PostToolUse payload for that file.
run_hook() {
  jq -n --arg f "$REPO/$1" '{tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1 || true
}

# assert_content PATH EXPECTED: the file's bytes equal EXPECTED, else a diff.
assert_content() {
  diff -u <(printf '%s' "$2") "$REPO/$1"
}

@test "a shell file under fixtures/ is left byte-identical" {
  write_sh tests/fixtures/sample.sh
  run_hook tests/fixtures/sample.sh
  assert_content tests/fixtures/sample.sh "$UNFORMATTED"
}

@test "a generated completion is left byte-identical" {
  write_sh completions/tool.sh
  run_hook completions/tool.sh
  assert_content completions/tool.sh "$UNFORMATTED"
}

@test "a shell file outside the ignored paths is formatted" {
  # The control: the ignore sections must exclude their paths, not disable the arm.
  write_sh scripts/sample.sh
  run_hook scripts/sample.sh
  assert_content scripts/sample.sh "$FORMATTED"
}
