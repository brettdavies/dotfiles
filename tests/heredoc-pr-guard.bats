#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that blocks heredoc-into-body antipatterns
# in gh PR/issue/release/comment commands and git commit -m.
#
# Run: bats tests/heredoc-pr-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/heredoc-pr-guard.sh"

# Helper: send a faked Bash tool input (just `tool_input.command`) into the
# hook and classify the decision. Echoes one of: ALLOW, DENY, HOOK_ERROR.
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

# ---------------------------------------------------------------------------
# DENY cases — heredoc piped into a server-side artifact's body / notes / -m
# ---------------------------------------------------------------------------

@test "gh pr create --body heredoc → DENY" {
    [ "$(classify 'gh pr create --base dev --title test --body "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "gh pr edit --body heredoc → DENY" {
    [ "$(classify 'gh pr edit 99 --body "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "gh pr comment --body heredoc → DENY" {
    [ "$(classify 'gh pr comment 73 --body "$(cat <<EOF
LGTM
EOF
)"')" = "DENY" ]
}

@test "gh pr review --body heredoc → DENY" {
    [ "$(classify 'gh pr review 73 --approve --body "$(cat <<EOF
nice
EOF
)"')" = "DENY" ]
}

@test "gh issue create --body heredoc → DENY" {
    [ "$(classify 'gh issue create --title bug --body "$(cat <<EOF
repro
EOF
)"')" = "DENY" ]
}

@test "gh issue edit --body heredoc → DENY" {
    [ "$(classify 'gh issue edit 12 --body "$(cat <<EOF
update
EOF
)"')" = "DENY" ]
}

@test "gh issue comment --body heredoc → DENY" {
    [ "$(classify 'gh issue comment 12 --body "$(cat <<EOF
note
EOF
)"')" = "DENY" ]
}

@test "gh release create --notes heredoc → DENY" {
    [ "$(classify 'gh release create v1.0 --notes "$(cat <<EOF
release
EOF
)"')" = "DENY" ]
}

@test "git commit -m heredoc → DENY" {
    [ "$(classify 'git commit -m "$(cat <<EOF
feat: thing
EOF
)"')" = "DENY" ]
}

@test "git commit --message heredoc → DENY" {
    [ "$(classify 'git commit --message "$(cat <<EOF
feat: x
EOF
)"')" = "DENY" ]
}

# ---------------------------------------------------------------------------
# ALLOW cases — file-flag variants, legit heredoc uses
# ---------------------------------------------------------------------------

@test "gh pr create --body-file → ALLOW" {
    [ "$(classify 'gh pr create --base dev --title test --body-file /tmp/pr.md')" = "ALLOW" ]
}

@test "gh pr comment --body-file → ALLOW" {
    [ "$(classify 'gh pr comment 73 --body-file /tmp/c.md')" = "ALLOW" ]
}

@test "gh issue create --body-file → ALLOW" {
    [ "$(classify 'gh issue create --title bug --body-file /tmp/i.md')" = "ALLOW" ]
}

@test "gh release create --notes-file → ALLOW" {
    [ "$(classify 'gh release create v1.0 --notes-file /tmp/notes.md')" = "ALLOW" ]
}

@test "git commit --file → ALLOW" {
    [ "$(classify 'git commit --file /tmp/msg.md')" = "ALLOW" ]
}

@test "gh pr create with heredoc in --title only, --body-file clean → ALLOW" {
    [ "$(classify 'gh pr create --title "$(cat <<EOF
multi-line title
EOF
)" --body-file /tmp/pr.md')" = "ALLOW" ]
}

@test "gh pr create --body-file first, heredoc later in unrelated flag → ALLOW" {
    [ "$(classify 'gh pr create --body-file /tmp/pr.md --title "$(cat <<EOF
x
EOF
)"')" = "ALLOW" ]
}

@test "cat > file <<EOF (writing config files) → ALLOW" {
    [ "$(classify 'cat > /tmp/foo <<EOF
hello
EOF')" = "ALLOW" ]
}

@test "bash <<EOF (embedded script) → ALLOW" {
    [ "$(classify 'bash <<EOF
echo hi
EOF')" = "ALLOW" ]
}

@test "ssh host bash <<EOF (remote script) → ALLOW" {
    [ "$(classify 'ssh host bash <<EOF
hostname
EOF')" = "ALLOW" ]
}

@test "plain ls (no heredoc) → ALLOW" {
    [ "$(classify 'ls -la /tmp')" = "ALLOW" ]
}

@test "gh repo create (no body/notes flag) → ALLOW" {
    [ "$(classify 'gh repo create foo --public')" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# Red team — adversarial bypass attempts that should still DENY
# ---------------------------------------------------------------------------

@test "RED: indent-stripping heredoc <<-EOF still DENY" {
    [ "$(classify 'gh pr create --body "$(cat <<-EOF
		body
		EOF
)"')" = "DENY" ]
}

@test "RED: heredoc with unusual marker name still DENY" {
    [ "$(classify 'gh pr create --body "$(cat <<MARKER
body
MARKER
)"')" = "DENY" ]
}

@test "RED: extra space between << and marker still DENY" {
    [ "$(classify 'gh pr create --body "$(cat << EOF
body
EOF
)"')" = "DENY" ]
}

@test "RED: extra whitespace between flags still DENY" {
    [ "$(classify 'gh   pr   create   --body   "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "RED: subshell wrapping still DENY" {
    [ "$(classify '(gh pr create --body "$(cat <<EOF
body
EOF
)")')" = "DENY" ]
}

@test "RED: chained command (cd && gh) still DENY" {
    [ "$(classify 'cd /tmp && gh pr create --body "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "RED: prepended environment var still DENY" {
    [ "$(classify 'GH_TOKEN=x gh pr create --body "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "RED: --body=value equals form (no value escape) still DENY" {
    [ "$(classify 'gh pr create --body="$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

@test "RED: heredoc operator with quoted marker <<'EOF' still DENY" {
    [ "$(classify "gh pr create --body \"\$(cat <<'EOF'
body
EOF
)\"")" = "DENY" ]
}

@test "RED: gh pr review --request-changes path still DENY" {
    [ "$(classify 'gh pr review 73 --request-changes --body "$(cat <<EOF
needs work
EOF
)"')" = "DENY" ]
}

@test "RED: multiline command with shell line-continuation still DENY" {
    [ "$(classify 'gh pr create \
  --base dev \
  --title test \
  --body "$(cat <<EOF
body
EOF
)"')" = "DENY" ]
}

# ---------------------------------------------------------------------------
# Red team — patterns that LOOK suspicious but should still ALLOW
# (false-positive guards: the hook must not over-match)
# ---------------------------------------------------------------------------

@test "RED: gh pr view --json body (no --body= flag) → ALLOW" {
    [ "$(classify 'gh pr view 73 --json body --jq .body > /tmp/body.md')" = "ALLOW" ]
}

@test "RED: comment mentions <<EOF but no body flag → ALLOW" {
    [ "$(classify 'echo \"see the <<EOF trap in CLAUDE.md\"')" = "ALLOW" ]
}

@test "RED: cat /tmp/body.md | gh pr edit --body-file - (stdin) → ALLOW" {
    [ "$(classify 'cat /tmp/body.md | gh pr edit 73 --body-file -')" = "ALLOW" ]
}

@test "RED: gh pr list (no body, has dashes) → ALLOW" {
    [ "$(classify 'gh pr list --base dev --state open --limit 10')" = "ALLOW" ]
}

@test "RED: shell function definition containing heredoc → ALLOW" {
    [ "$(classify 'helper() { cat <<EOF
foo
EOF
}')" = "ALLOW" ]
}

@test "RED: heredoc piped into curl (different tool) → ALLOW" {
    [ "$(classify 'curl -X POST https://api.example/foo -d @- <<EOF
{\"key\": \"val\"}
EOF')" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# Red team — bypass attempts the hook CANNOT catch (documented limits)
# These tests assert the documented behavior, not necessarily the desired one.
# If we ever tighten the hook to catch these, flip the assertion.
# ---------------------------------------------------------------------------

@test "RED LIMIT: heredoc piped to /dev/stdin via --body-file - bypasses → ALLOW" {
    # `gh pr create --body-file - <<EOF` reads the heredoc from stdin into
    # --body-file. The hook sees --body-file (not --body) and the heredoc
    # operator, so it does NOT deny. This is a known limit — flag it in
    # CLAUDE.md as "don't do this either" rather than expanding the hook
    # to a regex that risks false positives on legitimate stdin pipelines.
    [ "$(classify 'gh pr create --body-file - <<EOF
body
EOF')" = "ALLOW" ]
}

@test "RED: bash -c wrapper still DENY (substring matching catches it)" {
    # `bash -c 'gh pr create --body "$(cat <<EOF...)"'` — even though the
    # antipattern is inside a single-quoted argument to bash -c, the hook's
    # regex sees the whole command string as one buffer, so the required
    # substrings (`gh pr create`, `--body `, `<<`) are all present. Not
    # bulletproof against arbitrary subprocess obfuscation, but catches the
    # naive wrapper bypass.
    [ "$(classify "bash -c 'gh pr create --body \"\$(cat <<EOF
body
EOF
)\"'")" = "DENY" ]
}
