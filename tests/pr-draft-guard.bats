#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that denies a command opening a pull
# request ready for review: gh pr create without --draft, gh stack submit
# without --auto or with --open.
#
# Run: bats tests/pr-draft-guard.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/pr-draft-guard.sh"
SETTINGS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json"

load lib/json-parser

# Runs the hook on a faked Bash tool call and echoes ALLOW, DENY, or HOOK_ERROR.
classify() {
  local out rc=0
  out=$(bash_payload "$1" | "$HOOK" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "HOOK_ERROR"
  elif [ -z "$out" ]; then
    echo "ALLOW"
  elif jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1; then
    echo "DENY"
  else
    printf 'OTHER:%s' "$out"
  fi
}

# The command the deny's next_step carries.
rebuilt() {
  bash_payload "$1" | "$HOOK" | jaq -r '.hookSpecificOutput.permissionDecisionReason' \
    | sed -n '/^next_step \[/,/^Then, once/p' | sed '1d;$d'
}

# The command is denied, and the command the deny hands back passes the hook.
# With a second argument, that command is exactly the one the deny hands back.
assert_denied_and_fixed() {
  local fixed
  [ "$(classify "$1")" = "DENY" ]
  fixed=$(rebuilt "$1")
  echo "rebuilt: $fixed"
  [ -z "${2-}" ] || [ "$fixed" = "$2" ]
  [ "$(classify "$fixed")" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# DENY: gh pr create without a draft flag
# ---------------------------------------------------------------------------

@test "gh pr create with no draft flag → DENY, rebuilt with --draft" {
  assert_denied_and_fixed 'gh pr create --base dev --title t --body-file /tmp/b.md' \
    'gh pr create --draft --base dev --title t --body-file /tmp/b.md'
}

@test "gh pr new, the alias, → DENY" {
  assert_denied_and_fixed 'gh pr new --title t' 'gh pr new --draft --title t'
}

@test "gh pr create --dry-run with no draft flag → DENY" {
  assert_denied_and_fixed 'gh pr create --dry-run --base dev --title probe --body-file /dev/null' \
    'gh pr create --draft --dry-run --base dev --title probe --body-file /dev/null'
}

@test "gh pr create --draft=false → DENY, the false flag removed from the rebuilt command" {
  assert_denied_and_fixed 'gh pr create --draft=false --base dev' 'gh pr create --draft --base dev'
}

@test "gh pr create ... --draft=false last → DENY, the false flag removed" {
  assert_denied_and_fixed 'gh pr create --base dev --draft=false' 'gh pr create --draft --base dev'
}

@test "gh pr create -d=false → DENY" {
  assert_denied_and_fixed 'gh pr create -t x -d=false' 'gh pr create --draft -t x'
}

@test "gh pr create --draft=0 and --draft=F → DENY" {
  assert_denied_and_fixed 'gh pr create --draft=0 --base dev'
  assert_denied_and_fixed 'gh pr create --draft=F --base dev'
}

@test "gh pr create --draft then --draft=false: the last occurrence wins → DENY" {
  assert_denied_and_fixed 'gh pr create --draft --draft=false'
}

@test "gh pr create with --draft in the title text → DENY" {
  assert_denied_and_fixed 'gh pr create --title "add --draft to the guard" --body-file /tmp/b.md'
}

@test "gh pr create -td: the title is \"d\", not a draft flag → DENY" {
  assert_denied_and_fixed 'gh pr create -td' 'gh pr create --draft -td'
}

@test "gh pr create --title --draft: the value of --title → DENY" {
  assert_denied_and_fixed 'gh pr create --title --draft' 'gh pr create --draft --title --draft'
}

@test "gh pr create -- --draft: after -- nothing is a flag → DENY" {
  assert_denied_and_fixed 'gh pr create -- --draft'
}

# ---------------------------------------------------------------------------
# DENY: flags before and after the subcommand
# ---------------------------------------------------------------------------

@test "gh -R o/r pr create → DENY" {
  assert_denied_and_fixed 'gh -R o/r pr create -t x' 'gh -R o/r pr create --draft -t x'
}

@test "gh --repo o/r pr create → DENY" {
  assert_denied_and_fixed 'gh --repo o/r pr create -t x' 'gh --repo o/r pr create --draft -t x'
}

@test "gh --repo=o/r pr create → DENY" {
  assert_denied_and_fixed 'gh --repo=o/r pr create -t x'
}

@test "gh pr -R o/r create → DENY" {
  assert_denied_and_fixed 'gh pr -R o/r create -t x' 'gh pr -R o/r create --draft -t x'
}

@test "gh pr create -R o/r → DENY" {
  assert_denied_and_fixed 'gh pr create -R o/r -t x' 'gh pr create --draft -R o/r -t x'
}

@test "gh pr create -Rd: the repo is \"d\" → DENY" {
  assert_denied_and_fixed 'gh pr create -Rd'
}

# ---------------------------------------------------------------------------
# DENY: the command sits in a compound command, a wrapper, or a substitution
# ---------------------------------------------------------------------------

@test "git push && gh pr create → DENY, the whole command rebuilt" {
  assert_denied_and_fixed 'git push && gh pr create --base dev' 'git push && gh pr create --draft --base dev'
}

@test "cd dir; gh pr create → DENY" {
  assert_denied_and_fixed 'cd /tmp; gh pr create --base dev' 'cd /tmp; gh pr create --draft --base dev'
}

@test "false || gh pr create → DENY" {
  assert_denied_and_fixed 'false || gh pr create --base dev'
}

@test "a command on its own line → DENY" {
  assert_denied_and_fixed $'git push\ngh pr create --base dev' $'git push\ngh pr create --draft --base dev'
}

@test "gh pr create wrapped across lines with backslashes → DENY" {
  assert_denied_and_fixed $'gh pr create \\\n  --base dev \\\n  --title t'
}

@test "gh pr create piped into another command → DENY" {
  assert_denied_and_fixed 'gh pr create --title t | cat' 'gh pr create --draft --title t | cat'
}

@test "gh pr create inside \$( ) → DENY" {
  assert_denied_and_fixed 'url=$(gh pr create --title t --body-file /tmp/b.md)' \
    'url=$(gh pr create --draft --title t --body-file /tmp/b.md)'
}

@test "gh pr create in a subshell and in a group → DENY" {
  assert_denied_and_fixed '(gh pr create --title t)'
  assert_denied_and_fixed '{ gh pr create --title t; }'
}

@test "gh pr create after a variable assignment or a wrapper → DENY" {
  assert_denied_and_fixed 'GH_TOKEN=x gh pr create --title t' 'GH_TOKEN=x gh pr create --draft --title t'
  assert_denied_and_fixed 'env FOO=1 gh pr create --title t'
  assert_denied_and_fixed 'command gh pr create --title t'
  assert_denied_and_fixed 'sudo -n gh pr create --title t'
}

@test "gh by path → DENY" {
  assert_denied_and_fixed '/home/linuxbrew/.linuxbrew/bin/gh pr create --title t'
}

@test "gh pr create after a heredoc that writes a file → DENY" {
  assert_denied_and_fixed $'cat > /tmp/b.md <<\'EOF\'\nbody\nEOF\ngh pr create --body-file /tmp/b.md' \
    $'cat > /tmp/b.md <<\'EOF\'\nbody\nEOF\ngh pr create --draft --body-file /tmp/b.md'
}

@test "two gh pr create commands → both rebuilt" {
  assert_denied_and_fixed 'gh pr create --title a; gh pr create --title b' \
    'gh pr create --draft --title a; gh pr create --draft --title b'
}

@test "a draft gh pr create beside one without → DENY, only the second rebuilt" {
  assert_denied_and_fixed 'gh pr create --draft --title a; gh pr create --title b' \
    'gh pr create --draft --title a; gh pr create --draft --title b'
}

# ---------------------------------------------------------------------------
# DENY: gh stack submit
# ---------------------------------------------------------------------------

@test "gh stack submit with no --auto → DENY, rebuilt with --auto" {
  assert_denied_and_fixed 'gh stack submit' 'gh stack submit --auto'
}

@test "gh stack submit --open → DENY, --open replaced by --auto" {
  assert_denied_and_fixed 'gh stack submit --open' 'gh stack submit --auto'
}

@test "gh stack submit --auto --open → DENY, --open removed" {
  assert_denied_and_fixed 'gh stack submit --auto --open' 'gh stack submit --auto'
}

@test "gh stack submit --open --auto: the stack is auto but --open still marks it ready → DENY" {
  assert_denied_and_fixed 'gh stack submit --open --auto' 'gh stack submit --auto'
}

@test "gh stack submit --auto=false → DENY" {
  assert_denied_and_fixed 'gh stack submit --auto=false' 'gh stack submit --auto'
}

@test "gh stack submit --remote --auto: --auto is the remote's name → DENY" {
  assert_denied_and_fixed 'gh stack submit --remote --auto' 'gh stack submit --auto --remote --auto'
}

@test "gh stack submit --open=false with no --auto → DENY" {
  assert_denied_and_fixed 'gh stack submit --open=false'
}

@test "gh stack submit after a push, with --remote → DENY" {
  assert_denied_and_fixed 'git push && gh stack submit --remote origin' \
    'git push && gh stack submit --auto --remote origin'
}

# ---------------------------------------------------------------------------
# The deny a reader acts on
# ---------------------------------------------------------------------------

@test "the deny names the reason, the rerun command, and the gh pr ready step" {
  run --separate-stderr "$HOOK" <<<"$(bash_payload 'gh pr create --base dev --title t')"
  echo "status=$status stdout=$output stderr=$stderr"
  [ "$status" -eq 0 ]
  text=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $text == "pr-draft-guard denied [pr-not-draft]: "* ]]
  [[ $text == *$'\nnext_step [rerun-as-draft]: '* ]]
  [[ $text == *$'\ngh pr create --draft --base dev --title t\n'* ]]
  [[ $text == *"every review the PR needs is done, its fixes are in, and each verdict is in a PR comment"* ]]
  [[ $text == *$'\ngh pr ready <number>\n'* ]]
  [[ $text == *$'\ndocs: ~/.claude/guides/git-and-github.md'* ]]
  [ "$(jaq -r '.systemMessage' <<<"$output")" = 'pr-draft-guard denied [pr-not-draft]: `gh pr create` without --draft opens the PR ready for review' ]
}

@test "a gh stack submit deny carries its own reason code" {
  run "$HOOK" <<<"$(bash_payload 'gh stack submit --open')"
  [ "$status" -eq 0 ]
  text=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $text == "pr-draft-guard denied [stack-submit-not-draft]: "* ]]
  [[ $text == *$'\ngh stack submit --auto\n'* ]]
}

@test "a deny of --draft=false names the flag it found" {
  run "$HOOK" <<<"$(bash_payload 'gh pr create --draft=false')"
  [ "$status" -eq 0 ]
  [[ $(jaq -r '.systemMessage' <<<"$output") == *'`gh pr create --draft=false` opens the PR ready for review' ]]
}

# ---------------------------------------------------------------------------
# ALLOW: a draft
# ---------------------------------------------------------------------------

@test "gh pr create --draft → ALLOW" {
  [ "$(classify 'gh pr create --draft --base dev --title t --body-file /tmp/b.md')" = "ALLOW" ]
}

@test "gh pr create -d → ALLOW" {
  [ "$(classify 'gh pr create -d --base dev --title t')" = "ALLOW" ]
}

@test "gh pr create --draft=true, =1, =TRUE → ALLOW" {
  [ "$(classify 'gh pr create --draft=true --title t')" = "ALLOW" ]
  [ "$(classify 'gh pr create --draft=1 --title t')" = "ALLOW" ]
  [ "$(classify 'gh pr create --draft=TRUE --title t')" = "ALLOW" ]
}

@test "gh pr create with --draft last → ALLOW" {
  [ "$(classify 'gh pr create --base dev --title t --body-file /tmp/b.md --draft')" = "ALLOW" ]
}

@test "gh pr create --draft=false then --draft: the last occurrence wins → ALLOW" {
  [ "$(classify 'gh pr create --draft=false --draft')" = "ALLOW" ]
}

@test "gh pr create with -d in a bundle → ALLOW" {
  [ "$(classify 'gh pr create -dt "a title"')" = "ALLOW" ]
  [ "$(classify 'gh pr create -fd')" = "ALLOW" ]
  [ "$(classify 'gh pr create -dR o/r')" = "ALLOW" ]
  [ "$(classify 'gh pr create -d=true')" = "ALLOW" ]
}

@test "gh -R o/r pr create --draft and gh pr -R o/r create -d → ALLOW" {
  [ "$(classify 'gh -R o/r pr create --draft -t x')" = "ALLOW" ]
  [ "$(classify 'gh pr -R o/r create -d -t x')" = "ALLOW" ]
}

@test "git push && gh pr create --draft → ALLOW" {
  [ "$(classify 'git push && gh pr create --draft --base dev')" = "ALLOW" ]
}

@test "gh pr create --draft with a heredoc-written body file → ALLOW" {
  [ "$(classify $'cat > /tmp/b.md <<\'EOF\'\nbody\nEOF\ngh pr create --draft --body-file /tmp/b.md')" = "ALLOW" ]
}

@test "gh stack submit --auto → ALLOW" {
  [ "$(classify 'gh stack submit --auto')" = "ALLOW" ]
}

@test "gh stack submit --auto --remote origin and --auto=true → ALLOW" {
  [ "$(classify 'gh stack submit --auto --remote origin')" = "ALLOW" ]
  [ "$(classify 'gh stack submit --auto=true')" = "ALLOW" ]
}

@test "gh stack submit --open=false --auto → ALLOW" {
  [ "$(classify 'gh stack submit --open=false --auto')" = "ALLOW" ]
}

@test "gh stack submit --open then --open=false with --auto → ALLOW: the last occurrence wins" {
  [ "$(classify 'gh stack submit --auto --open --open=false')" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# ALLOW: help
# ---------------------------------------------------------------------------

@test "gh pr create --help and -h → ALLOW" {
  [ "$(classify 'gh pr create --help')" = "ALLOW" ]
  [ "$(classify 'gh pr create -h')" = "ALLOW" ]
  [ "$(classify 'gh pr create --base dev --help')" = "ALLOW" ]
}

@test "gh stack submit --help → ALLOW" {
  [ "$(classify 'gh stack submit --help')" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# ALLOW: text that only mentions the command
# ---------------------------------------------------------------------------

@test "rg for the text → ALLOW" {
  [ "$(classify "rg 'gh pr create' docs")" = "ALLOW" ]
  [ "$(classify 'rg "gh stack submit" docs')" = "ALLOW" ]
}

@test "echo of the text, quoted and not → ALLOW" {
  [ "$(classify 'echo "gh pr create --base dev"')" = "ALLOW" ]
  [ "$(classify 'echo gh pr create --base dev')" = "ALLOW" ]
  [ "$(classify "printf '%s\n' 'gh stack submit'")" = "ALLOW" ]
}

@test "a heredoc body that writes a file mentioning the command → ALLOW" {
  [ "$(classify $'cat > /tmp/runbook.md <<\'EOF\'\nOpen it with:\ngh pr create --base dev\ngh stack submit\nEOF')" = "ALLOW" ]
}

@test "a heredoc body fed to another command → ALLOW" {
  [ "$(classify $'bash <<EOF\necho gh pr create\nEOF')" = "ALLOW" ]
}

@test "a commit message that mentions the command → ALLOW" {
  [ "$(classify 'git commit -m "docs: gh pr create needs --draft"')" = "ALLOW" ]
  [ "$(classify 'git commit --file /tmp/commit-msg.md')" = "ALLOW" ]
}

@test "a comment that mentions the command → ALLOW" {
  [ "$(classify $'ls # gh pr create --base dev\nls')" = "ALLOW" ]
}

@test "a PR body or comment that mentions the command → ALLOW" {
  [ "$(classify 'gh pr comment 12 --body-file /tmp/c.md')" = "ALLOW" ]
  [ "$(classify 'gh pr edit 12 --title "gh pr create without --draft"')" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# ALLOW: other commands
# ---------------------------------------------------------------------------

@test "other gh subcommands → ALLOW" {
  [ "$(classify 'gh pr view 12')" = "ALLOW" ]
  [ "$(classify 'gh pr ready 12')" = "ALLOW" ]
  [ "$(classify 'gh pr list --state open')" = "ALLOW" ]
  [ "$(classify 'gh pr merge 12 --squash')" = "ALLOW" ]
  [ "$(classify 'gh issue create --title bug --body-file /tmp/i.md')" = "ALLOW" ]
  [ "$(classify 'gh release create v1 --notes-file /tmp/n.md')" = "ALLOW" ]
  [ "$(classify 'gh stack view')" = "ALLOW" ]
  [ "$(classify 'gh stack init')" = "ALLOW" ]
  [ "$(classify 'gh run watch 1 --exit-status')" = "ALLOW" ]
}

@test "a script that runs gh itself → ALLOW: the hook sees only the command typed" {
  [ "$(classify 'bash scripts/sync-dev-after-release.sh 2026.11.10')" = "ALLOW" ]
  [ "$(classify 'scripts/upgrade/yazi-pins.sh --apply')" = "ALLOW" ]
}

@test "a command that never mentions gh → ALLOW" {
  [ "$(classify 'git status')" = "ALLOW" ]
  [ "$(classify 'create --new submit')" = "ALLOW" ]
}

@test "a gh command with no subcommand → ALLOW" {
  [ "$(classify 'gh')" = "ALLOW" ]
  [ "$(classify 'gh pr')" = "ALLOW" ]
  [ "$(classify 'gh -R o/r')" = "ALLOW" ]
}

@test "an empty command and a call with no command → ALLOW" {
  [ "$(classify '')" = "ALLOW" ]
  run "$HOOK" <<<'{"tool_name":"Read","tool_input":{"file_path":"/tmp/gh-create.txt"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a trigger in the description alone allows: the decoded command decides" {
  run "$HOOK" <<<"$(jaq -nc --arg d 'run gh pr create to open it' '{tool_name: "Bash", tool_input: {command: "ls -la", description: $d}}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Without a working JSON parser the guard blocks what it checks, never allows it
# ---------------------------------------------------------------------------

@test "with neither jaq nor jq, a call this guard checks is blocked naming the fix" {
  run_hook_with_parser none "$HOOK" "$(bash_payload 'gh pr create --title t')"
  assert_parser_block json-parser-missing
  [[ $REASON == "pr-draft-guard blocked [json-parser-missing]: "* ]]
  [ "${REASON##*$'\n'}" = 'brew install jaq' ]
}

@test "with neither jaq nor jq, a call without this guard's trigger text still runs" {
  run_hook_with_parser none "$HOOK" "$(bash_payload 'brew install jaq')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "with jq and no jaq, the guard denies as it does with jaq" {
  assert_same_deny_with_jq "$HOOK" "$(bash_payload 'git push && gh pr create --title t')"
}

@test "with a jaq that fails, the guard blocks naming its own failure" {
  run_hook_with_parser broken "$HOOK" "$(bash_payload 'gh pr create --title t')"
  assert_parser_block guard-internal-error
  [[ $REASON == "pr-draft-guard failed [guard-internal-error] at line "* ]]
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

@test "settings.json runs the guard on Bash right after piped-commit-guard, blocking when it fails" {
  run jaq -c '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] as $h
    | ($h | map(.command) | index("~/.claude/piped-commit-guard.sh")) as $i
    | $h[$i + 1]' "$SETTINGS"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"command","command":"~/.claude/pr-draft-guard.sh","timeout":5,"onFailure":"block"}' ]
}

@test "the guard is registered once, and its file is executable" {
  run jaq '[.hooks.PreToolUse[] | .hooks[] | select(.command == "~/.claude/pr-draft-guard.sh")] | length' "$SETTINGS"
  [ "$output" = "1" ]
  [ -x "$HOOK" ]
}
