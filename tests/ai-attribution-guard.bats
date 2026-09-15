#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that blocks AI-attribution trailers from
# reaching a commit object or a GitHub artifact.
#
# Run: bats tests/ai-attribution-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ai-attribution-guard.sh"

setup() {
  TMPDIR_T=$(mktemp -d)
}

teardown() {
  rm -rf "$TMPDIR_T"
}

# Echoes one of: ALLOW, DENY, HOOK_ERROR.
classify() {
  local cmd=$1
  local out
  local rc
  out=$(jaq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}' | "$HOOK" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "HOOK_ERROR"
  elif [ -z "$out" ]; then
    echo "ALLOW"
  elif printf '%s' "$out" | jaq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "DENY"
  else
    printf 'OTHER:%s' "$out"
  fi
}

# Writes $2 to a file under the test tmpdir and echoes the path.
fixture() {
  local name=$1 body=$2
  printf '%s\n' "$body" > "$TMPDIR_T/$name"
  printf '%s' "$TMPDIR_T/$name"
}

# ---------------------------------------------------------------------------
# DENY — inline
# ---------------------------------------------------------------------------

@test "git commit -m with Co-Authored-By: Claude → DENY" {
  [ "$(classify 'git commit -m "fix: thing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"')" = "DENY" ]
}

@test "git commit -m with Co-authored-by lowercase → DENY" {
  [ "$(classify 'git commit -m "fix: thing

Co-authored-by: Claude <noreply@anthropic.com>"')" = "DENY" ]
}

@test "gh pr create --body with generated-with line → DENY" {
  [ "$(classify 'gh pr create --title t --body "does the thing

Generated with [Claude Code](https://claude.com/claude-code)"')" = "DENY" ]
}

@test "gh pr comment --body with robot emoji → DENY" {
  [ "$(classify 'gh pr comment 12 --body "🤖 Generated with Claude Code"')" = "DENY" ]
}

@test "gh issue create --body with an anthropic-addressed trailer → DENY" {
  [ "$(classify 'gh issue create --title t --body "filed it

Reported-By: Claude Code <noreply@anthropic.com>"')" = "DENY" ]
}

@test "prose naming the anthropic address mid-sentence → ALLOW" {
  [ "$(classify 'gh issue create --title t --body "reported by noreply@anthropic.com"')" = "ALLOW" ]
}

@test "gh release create --notes with attribution → DENY" {
  [ "$(classify 'gh release create v1.0.0 --notes "notes

Co-Authored-By: Claude <noreply@anthropic.com>"')" = "DENY" ]
}

# ---------------------------------------------------------------------------
# DENY — the flag names a file and the trailer is inside it
# ---------------------------------------------------------------------------

@test "git commit --file whose body carries the trailer → DENY" {
  local f
  f=$(fixture msg.md 'fix: thing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>')
  [ "$(classify "git commit --file $f")" = "DENY" ]
}

@test "git commit -F whose body carries the trailer → DENY" {
  local f
  f=$(fixture msg.md 'fix: thing

Co-Authored-By: Claude <noreply@anthropic.com>')
  [ "$(classify "git commit -F $f")" = "DENY" ]
}

@test "gh pr create --body-file whose body carries the trailer → DENY" {
  local f
  f=$(fixture body.md 'Ships the thing.

🤖 Generated with [Claude Code](https://claude.com/claude-code)')
  [ "$(classify "gh pr create --base dev --title t --body-file $f")" = "DENY" ]
}

@test "gh release create --notes-file whose body carries the trailer → DENY" {
  local f
  f=$(fixture notes.md 'Release notes.

Co-Authored-By: Anthropic <noreply@anthropic.com>')
  [ "$(classify "gh release create v1.0.0 --notes-file $f")" = "DENY" ]
}

# ---------------------------------------------------------------------------
# ALLOW — clean artifacts
# ---------------------------------------------------------------------------

@test "git commit --file with a clean body → ALLOW" {
  local f
  f=$(fixture msg.md 'fix(scope): thing

Explains why.')
  [ "$(classify "git commit --file $f")" = "ALLOW" ]
}

@test "gh pr create --body-file with a clean body → ALLOW" {
  local f
  f=$(fixture body.md '## Summary

Ships the thing.')
  [ "$(classify "gh pr create --base dev --title t --body-file $f")" = "ALLOW" ]
}

@test "git commit -m clean → ALLOW" {
  [ "$(classify 'git commit -m "fix(scope): thing"')" = "ALLOW" ]
}

@test "a human co-author is not AI attribution → ALLOW" {
  [ "$(classify 'git commit -m "feat: thing

Co-Authored-By: Jane Roe <jane@example.com>"')" = "ALLOW" ]
}

@test "unrelated command mentioning claude → ALLOW" {
  [ "$(classify 'rg -n "Co-Authored-By: Claude" src/')" = "ALLOW" ]
}

@test "commit message naming the trailer to ban it → ALLOW" {
  local f
  f=$(fixture msg.md 'feat(claude): guard AI-attribution trailers

Denies a body carrying `Co-Authored-By: Claude`, a `Generated with [Claude
Code]` line, or the vendor noreply address.')
  [ "$(classify "git commit --file $f")" = "ALLOW" ]
}

@test "PR body documenting the rule → ALLOW" {
  local f
  f=$(fixture body.md '## Summary

The hook rejects `Co-Authored-By: Claude` in trailer position. Prose that
quotes noreply@anthropic.com mid-sentence still passes.')
  [ "$(classify "gh pr create --base dev --title t --body-file $f")" = "ALLOW" ]
}

@test "bulleted mention of the trailer → ALLOW" {
  local f
  f=$(fixture msg.md 'docs: record the attribution ban

- `Co-Authored-By: Claude` is never appended.
- 🤖 Generated with markers are stripped.')
  [ "$(classify "git commit --file $f")" = "ALLOW" ]
}

@test "git log reading trailers → ALLOW" {
  [ "$(classify 'git log -1 --format=%B | grep Co-Authored-By')" = "ALLOW" ]
}

@test "missing body file is not an accusation → ALLOW" {
  [ "$(classify "git commit --file $TMPDIR_T/absent.md")" = "ALLOW" ]
}

@test "empty command → ALLOW" {
  [ "$(classify '')" = "ALLOW" ]
}
