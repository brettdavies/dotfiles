#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that denies a piped `git commit` whose
# message file a later step deletes or moves.
#
# Run: bats tests/piped-commit-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/piped-commit-guard.sh"

# Feed a faked Bash tool input to the hook. Sets DECISION (ALLOW, DENY, or
# HOOK_ERROR) and TEXT (the deny reason shown to the agent).
# Args: command
decide() {
  local out rc
  out=$(jaq -n --arg cmd "$1" '{tool_input: {command: $cmd}}' | "$HOOK" 2>&1)
  rc=$?
  TEXT=""
  if [ "$rc" -ne 0 ]; then
    DECISION=HOOK_ERROR
    TEXT=$out
  elif [ -z "$out" ]; then
    DECISION=ALLOW
  elif printf '%s' "$out" | jaq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    DECISION=DENY
    TEXT=$(printf '%s' "$out" | jaq -r '.hookSpecificOutput.permissionDecisionReason')
  else
    DECISION="OTHER:$out"
  fi
}

# Everything between the "next_step" line and the "docs:" line: the rebuilt command.
next_command() { awk '/^docs: / { exit } f { print } /^next_step/ { f = 1 }' <<<"$TEXT"; }

setup() { command -v jaq >/dev/null 2>&1 || skip "jaq not available"; }

# ---------------------------------------------------------------------------
# Denied: the pipe's status, not the commit's, decides whether the file goes
# ---------------------------------------------------------------------------

@test "a commit piped into tail before trash of its message file is denied" {
  decide 'git commit --file /tmp/m.md | tail -2 && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"[commit-status-masked-by-pipe]"* ]]
  [[ "$TEXT" == *'`git commit --file /tmp/m.md | tail -2` exits with the status of `tail`'* ]]
  [[ "$TEXT" == *'`trash /tmp/m.md` runs even when the commit fails'* ]]
  [[ "$TEXT" == *"next_step [rerun-unpiped]"* ]]
  [ "$(next_command)" = 'git commit --file /tmp/m.md && trash /tmp/m.md' ]
}

@test "the rebuilt command drops the 2>&1 that only fed the pipe" {
  decide 'git commit --file /tmp/m.md 2>&1 | tail -5 && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit --file /tmp/m.md && trash /tmp/m.md' ]
}

@test "rm and mv of the message file are denied like trash" {
  decide 'git commit -F /tmp/m.md | tail && rm -f /tmp/m.md'
  [ "$DECISION" = DENY ]
  decide 'git commit --file=/tmp/m.md | cat && mv /tmp/m.md /tmp/sent/'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit --file=/tmp/m.md && mv /tmp/m.md /tmp/sent/' ]
}

@test "a semicolon after the pipe is denied and rebuilt as &&" {
  decide 'git commit --file /tmp/m.md | tail -1; trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit --file /tmp/m.md && trash /tmp/m.md' ]
}

@test "a stderr pipe |& is denied" {
  decide 'git commit --file /tmp/m.md |& tail -3 && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit --file /tmp/m.md && trash /tmp/m.md' ]
}

@test "every stage of a longer pipe is dropped from the rebuilt command" {
  decide "git commit -F /tmp/m.md | tail -3 | sed 's/^/  /' && trash /tmp/m.md"
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit -F /tmp/m.md && trash /tmp/m.md' ]
}

@test "the commands before the commit stay in the rebuilt command" {
  decide 'cd repo && git add a.md && git commit --file /tmp/m.md | tail -2 && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'cd repo && git add a.md && git commit --file /tmp/m.md && trash /tmp/m.md' ]
}

# ---------------------------------------------------------------------------
# Red team: spellings that must still be denied
# ---------------------------------------------------------------------------

@test "RED: the message file named through a variable on both sides" {
  decide 'MSG=/tmp/commit-msg-1.md; git commit --file "$MSG" | tail -2 && trash "$MSG"'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'MSG=/tmp/commit-msg-1.md; git commit --file "$MSG" && trash "$MSG"' ]
}

@test "RED: \${MSG} on one side and \$MSG on the other" {
  decide 'git commit --file "${MSG}" | tail && trash $MSG'
  [ "$DECISION" = DENY ]
}

@test "RED: a variable in the commit and its literal value in the trash" {
  decide 'MSG=/tmp/m.md; git commit --file "$MSG" | tail && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: a glob in the trash that matches the message file" {
  decide 'git commit --file /tmp/commit-msg-01a.md | tail && trash /tmp/commit-msg-*.md'
  [ "$DECISION" = DENY ]
}

@test "RED: git global options, an env prefix, and commit options before -F" {
  decide 'GIT_EDITOR=true git -C sub -c commit.gpgsign=true commit -s -F /tmp/m.md | tail -3 && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: -F bundled with other short options or attached to its value" {
  decide 'git commit -sF /tmp/m.md | tail && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  decide 'git commit -F/tmp/m.md | tail && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: a subshell or a brace group around the commit is piped" {
  decide '(git commit --file /tmp/m.md) | tail && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = '(git commit --file /tmp/m.md) && trash /tmp/m.md' ]
  decide '{ git commit --file /tmp/m.md; } 2>&1 | tail && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: a command substitution that pipes the commit" {
  decide 'out=$(git commit --file /tmp/m.md 2>&1 | tail -1) && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'out=$(git commit --file /tmp/m.md) && trash /tmp/m.md' ]
}

@test "RED: the pipe and the trash on continuation lines" {
  decide 'git commit --file /tmp/m.md \
  | tail -2 \
  && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: the trash on the next line of the command" {
  decide 'git commit --file /tmp/m.md | tail -2
trash /tmp/m.md'
  [ "$DECISION" = DENY ]
  [ "$(next_command)" = 'git commit --file /tmp/m.md &&
trash /tmp/m.md' ]
}

@test "RED: rm reached through command, a backslash, or a path" {
  decide 'git commit -F /tmp/m.md | tail && command rm -f /tmp/m.md'
  [ "$DECISION" = DENY ]
  decide 'git commit -F /tmp/m.md | tail && \rm /tmp/m.md'
  [ "$DECISION" = DENY ]
  decide 'git commit -F /tmp/m.md | tail && /bin/rm /tmp/m.md'
  [ "$DECISION" = DENY ]
}

@test "RED: an if whose condition is the piped commit" {
  decide 'if git commit -F /tmp/m.md | tail -2; then trash /tmp/m.md; fi'
  [ "$DECISION" = DENY ]
}

@test "RED: pipefail does not cover a semicolon after the pipe" {
  decide 'set -o pipefail; git commit --file /tmp/m.md | tail -2; trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

# ---------------------------------------------------------------------------
# Allowed
# ---------------------------------------------------------------------------

@test "an unpiped commit before trash of its message file is allowed" {
  decide 'git commit --file /tmp/m.md && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "piping an unrelated command is allowed" {
  decide 'git log --oneline | head -3 && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
  decide 'git commit --file /tmp/m.md && git log -1 --stat | tail -3 && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
  decide 'git log | head; git commit --file /tmp/m.md && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "a piped commit with no destructive step after it is allowed" {
  decide 'git commit --file /tmp/m.md 2>&1 | tail -15; echo "rc=${PIPESTATUS[0]}"'
  [ "$DECISION" = ALLOW ]
}

@test "a piped commit followed by trash of some other file is allowed" {
  decide 'git commit --file /tmp/m.md | tail && trash /tmp/build.log'
  [ "$DECISION" = ALLOW ]
}

@test "a piped commit with -m and no message file is allowed" {
  decide 'git commit -m "fix: x" | tail && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "a trash before the piped commit is allowed" {
  decide 'trash /tmp/m.md; git commit --file /tmp/m.md | tail'
  [ "$DECISION" = ALLOW ]
}

@test "a commit that reads the pipe as its last stage is allowed" {
  decide 'cat /tmp/m.md | git commit -F - && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "a trash inside the piped group, gated on the commit, is allowed" {
  decide '{ git commit --file /tmp/m.md && trash /tmp/m.md; } 2>&1 | tail -3'
  [ "$DECISION" = ALLOW ]
}

@test "process substitution is not a pipe" {
  decide 'git commit --file /tmp/m.md > >(tail -2) && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "pipefail before the commit with && to the trash is allowed" {
  decide 'set -o pipefail; git commit --file /tmp/m.md | tail -2 && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
  decide 'set -euo pipefail
git commit --file /tmp/m.md 2>&1 | tail -2 && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

@test "other git subcommands are not commits" {
  decide 'git commit-tree HEAD^{tree} -F /tmp/m.md | tail && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
  decide 'git log --grep commit -F | head && trash /tmp/m.md'
  [ "$DECISION" = ALLOW ]
}

# ---------------------------------------------------------------------------
# Red team: text that only mentions the pattern
# ---------------------------------------------------------------------------

@test "RED: the pattern inside quotes is allowed" {
  decide "rg 'git commit --file m | tail && trash m' docs/"
  [ "$DECISION" = ALLOW ]
  decide 'echo "git commit -F m | tail && trash m"'
  [ "$DECISION" = ALLOW ]
}

@test "RED: the pattern inside a heredoc body is allowed" {
  decide "cat >/tmp/x.sh <<'EOF'
git commit --file /tmp/m.md | tail && trash /tmp/m.md
EOF
bash -n /tmp/x.sh"
  [ "$DECISION" = ALLOW ]
}

@test "RED: the pattern in a comment is allowed" {
  decide 'git commit --file /tmp/m.md && trash /tmp/m.md  # never: git commit -F f | tail && trash f'
  [ "$DECISION" = ALLOW ]
}

# The guard does not follow the commit's status through a variable, so a step
# gated on PIPESTATUS is still denied; the unpiped form is the one that passes.
@test "RED LIMIT: a step gated on PIPESTATUS is still denied" {
  decide 'git commit --file /tmp/m.md 2>&1 | tail -4; rc=${PIPESTATUS[0]}; [ "$rc" -eq 0 ] && trash /tmp/m.md'
  [ "$DECISION" = DENY ]
}

# A script handed to `bash -c` is one quoted word here, and the guard reads
# only the command it was given.
@test "RED LIMIT: a bash -c script is not parsed" {
  decide "bash -c 'git commit -F /tmp/m.md | tail && trash /tmp/m.md'"
  [ "$DECISION" = ALLOW ]
}
