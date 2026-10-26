#!/usr/bin/env bats
# The markdownlint config that governs a markdown file is the one in that file's
# own directory tree, not the one belonging to the directory the session started
# in. An Edit can target a repo other than CLAUDE_PROJECT_DIR, and resolving
# config from the session's repo would apply the wrong MD013 width and the wrong
# `ignores` list to the file being written, reflowing a repo whose committed
# markdown owns its own wrapping (MD013.line_length >= 9999).

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO_SRC/stow/claude/dot-claude/auto-format.sh"

  # Without yq the hook reads no config at all: md_ignored() returns early and
  # max_len keeps its hardcoded default, so every assertion here is vacuous.
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  # Deliberately NOT under /tmp: the hook skips scratch paths before any
  # formatting step, so a /tmp sandbox makes every assertion pass without the
  # hook doing anything. TMPDIR is cleared for the same reason.
  unset TMPDIR
  _sandbox_root="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-tests"
  mkdir -p "$_sandbox_root"
  TMP=$(mktemp -d "$_sandbox_root/auto-format-config.XXXXXX")

  # A sandbox HOME so the hook resolves its helpers and global config here.
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  cp "$REPO_SRC/stow/claude/dot-claude/md-wrap.py" "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC"/stow/claude/dot-claude/md_wrap_*.py "$HOME/.claude/"
  chmod +x "$HOME/.claude/md-wrap.py"
  cp "$REPO_SRC/stow/claude/dot-markdownlint-cli2.yaml" "$HOME/.markdownlint-cli2.yaml"

  # The session's repo wraps at 120. Every test below edits a file outside it.
  export CLAUDE_PROJECT_DIR="$TMP/session"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  write_config "$CLAUDE_PROJECT_DIR" 120

  # The repo the edits actually target, elsewhere on disk. It has to be a git
  # work tree: the hook's walk stops at the first config or `.git`, and without
  # one it climbs out of the sandbox and, on a host whose real home holds a
  # markdownlint config, reads that config instead of the sandbox HOME's.
  OTHER="$TMP/other"
  git init -q "$OTHER"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

LONG='This is a deliberately long prose line that runs past one hundred and twenty characters so any wrapper reaching it would split the line in two.'

# write_config DIR WIDTH [IGNORE_GLOB]
write_config() {
  {
    printf 'config:\n  MD013:\n    line_length: %s\n' "$2"
    if [ -n "${3:-}" ]; then printf 'ignores:\n  - "%s"\n' "$3"; fi
  } >"$1/.markdownlint-cli2.yaml"
}

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

@test "the target repo's 9999 opt-out is honored from a session rooted elsewhere" {
  write_config "$OTHER" 9999
  write_md "$OTHER/README.md"
  run_hook "$OTHER/README.md"
  [ "$(line_count "$OTHER/README.md")" -eq 3 ]
  grep -qF "$LONG" "$OTHER/README.md"
}

@test "the target repo's width wins over the session repo's" {
  # The inverse of the case above: the gate must read the target repo's config,
  # not merely skip whenever some config says 9999.
  write_config "$CLAUDE_PROJECT_DIR" 9999
  write_config "$OTHER" 120
  write_md "$OTHER/README.md"
  run_hook "$OTHER/README.md"
  [ "$(line_count "$OTHER/README.md")" -gt 3 ]
}

@test "the target repo's own ignores list is honored" {
  write_config "$OTHER" 120 'vendored/**'
  write_md "$OTHER/vendored/upstream.md"
  run_hook "$OTHER/vendored/upstream.md"
  [ "$(line_count "$OTHER/vendored/upstream.md")" -eq 3 ]
}

@test "the config is found from a nested subdirectory, not just the repo root" {
  write_config "$OTHER" 9999
  write_md "$OTHER/deep/deeper/note.md"
  run_hook "$OTHER/deep/deeper/note.md"
  [ "$(line_count "$OTHER/deep/deeper/note.md")" -eq 3 ]
}

@test "a file under a symlinked docs/solutions is left alone by the upstream opt-out" {
  # docs/solutions symlinks to a separate repo that declares 9999, the way the
  # shared solutions-docs clone does in every consuming repo.
  UPSTREAM="$TMP/upstream"
  mkdir -p "$UPSTREAM" "$OTHER/docs"
  write_config "$UPSTREAM" 9999
  write_config "$OTHER" 120
  ln -s "$UPSTREAM" "$OTHER/docs/solutions"
  write_md "$OTHER/docs/solutions/note.md"
  run_hook "$OTHER/docs/solutions/note.md"
  [ "$(line_count "$OTHER/docs/solutions/note.md")" -eq 3 ]
  grep -qF "$LONG" "$UPSTREAM/note.md"
}

@test "a symlinked docs/solutions with no upstream config is still ignored" {
  # The other gate: with nothing to find upstream the walk reaches the consuming
  # repo, so the path stays docs/solutions-relative and the global ignore glob
  # matches. Resolving the path physically would strip that prefix and reflow
  # the shared repo.
  UPSTREAM="$TMP/upstream"
  mkdir -p "$UPSTREAM" "$OTHER/docs"
  write_config "$OTHER" 120
  ln -s "$UPSTREAM" "$OTHER/docs/solutions"
  write_md "$OTHER/docs/solutions/note.md"
  run_hook "$OTHER/docs/solutions/note.md"
  [ "$(line_count "$OTHER/docs/solutions/note.md")" -eq 3 ]
}

@test "a repo with no config of its own falls back to the global width" {
  # The control: absent a local config the global 120 applies and the file wraps.
  write_md "$OTHER/README.md"
  run_hook "$OTHER/README.md"
  [ "$(line_count "$OTHER/README.md")" -gt 3 ]
}
