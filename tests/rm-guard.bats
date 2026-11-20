#!/usr/bin/env bats
# Tests for the PreToolUse Bash hook that denies a command deleting files for
# good wherever the shell would run it, and rebuilds it with trash.
#
# Run: bats tests/rm-guard.bats
# run-tests: parallel

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/rm-guard.sh"
SETTINGS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json"

load lib/json-parser

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

# The command is denied, and its rebuilt form is $2.
# Args: command, rebuilt command
assert_rebuilt() {
  decide "$1"
  echo "decision=$DECISION text=$TEXT"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == "rm-guard denied [permanent-delete]: "* ]]
  [[ "$TEXT" == *"next_step [use-trash]: rerun it with trash in place of each deletion:"* ]]
  [ "$(next_command)" = "$2" ]
}

setup() { command -v jaq >/dev/null 2>&1 || skip "jaq not available"; }

# ---------------------------------------------------------------------------
# Denied: rm and git rm wherever the shell runs them
# ---------------------------------------------------------------------------

@test "an rm in the script ssh runs is denied and rebuilt with trash" {
  assert_rebuilt "timeout 30 ssh -o BatchMode=yes linux-server '…; rm -f /tmp/statusline.legacy.sh'" \
    "timeout 30 ssh -o BatchMode=yes linux-server '…; trash /tmp/statusline.legacy.sh'"
  [[ "$TEXT" == *$'\n  rm -f /tmp/statusline.legacy.sh (inside ssh)\n'* ]]
}

@test "an rm after other steps in the script ssh runs is denied" {
  assert_rebuilt "timeout 30 ssh -o BatchMode=yes linux-server '…; python3 -I /tmp/sockstdin-check.py …; rm -f /tmp/sockstdin-check.py'" \
    "timeout 30 ssh -o BatchMode=yes linux-server '…; python3 -I /tmp/sockstdin-check.py …; trash /tmp/sockstdin-check.py'"
}

@test "a script ssh runs keeps its newlines, so an rm on its own line is found" {
  assert_rebuilt $'ssh host \'\n  set -e\n  rm -rf /tmp/a\n\'' $'ssh host \'\n  set -e\n  trash /tmp/a\n\''
}

@test "a local rm -f is denied and rebuilt as trash" {
  assert_rebuilt 'rm -f x' 'trash x'
  [[ "$TEXT" == *$'\n  rm -f x\n'* ]]
}

@test "git rm is denied, rebuilt as trash, and says how to stage the deletion" {
  assert_rebuilt 'git rm x' 'trash x'
  [[ "$TEXT" == *'after trash, `git add -- <path>` stages it.'* ]]
}

@test "an rm in the script bash -c runs is denied" {
  assert_rebuilt "bash -c 'rm x'" "bash -c 'trash x'"
  [[ "$TEXT" == *"rm x (inside bash -c)"* ]]
}

@test "sh -c and zsh -c scripts are read like bash -c" {
  assert_rebuilt "sh -c 'rm a' && zsh -lc 'rm b'" "sh -c 'trash a' && zsh -lc 'trash b'"
}

@test "an rm that eval runs is denied" {
  assert_rebuilt 'eval "rm x"' 'eval "trash x"'
}

@test "an rm in a command substitution, quoted or not, is denied" {
  assert_rebuilt 'echo "$(rm -v x)" `rm y`' 'echo "$(trash x)" `trash y`'
  assert_rebuilt 'x=$(rm -v a)' 'x=$(trash a)'
}

@test "an rm behind a wrapper is denied, and the wrapper stays" {
  assert_rebuilt 'sudo -u bob rm x' 'sudo -u bob trash x'
  assert_rebuilt 'env FOO=1 nice -n 5 gtime -f %e rm x' 'env FOO=1 nice -n 5 gtime -f %e trash x'
  assert_rebuilt 'timeout -k 5 30 rm x && nohup rm y' 'timeout -k 5 30 trash x && nohup trash y'
}

@test "an rm in a trap's command is denied" {
  assert_rebuilt "tmp=\$(mktemp -d); trap 'rm -rf \"\$tmp\"' EXIT" "tmp=\$(mktemp -d); trap 'trash \"\$tmp\"' EXIT"
}

@test "an rm that fd -x runs is denied" {
  assert_rebuilt 'fd -e pyc -x rm' 'fd -e pyc -x trash'
}

@test "an rm after eval -- is denied" {
  assert_rebuilt "eval -- 'rm x'" "eval -- 'trash x'"
}

@test "an rm after nohup -- is denied" {
  assert_rebuilt 'nohup -- rm x' 'nohup -- trash x'
}

@test "a heredoc delimiter quoted with a backslash still ends its body" {
  assert_rebuilt $'cat <<\\EOF >/dev/null\nhello\nEOF\nrm -rf /tmp/x' $'cat <<\\EOF >/dev/null\nhello\nEOF\ntrash /tmp/x'
}

@test "a \$'...' string does not hide the rm after it" {
  assert_rebuilt "echo \$'don\\'t'; rm -f x" "echo \$'don\\'t'; trash x"
}

@test "an rm after a += assignment prefix is denied" {
  assert_rebuilt 'X+=1 rm x' 'X+=1 trash x'
}

@test "an rm in the script dash -c runs is denied" {
  assert_rebuilt "dash -c 'rm x'" "dash -c 'trash x'"
}

@test "gfind -delete is denied like find -delete" {
  assert_rebuilt "gfind . -name '*.pyc' -delete" "gfind . -name '*.pyc' -exec trash {} + -prune"
}

@test "an rm after a newline or a tab is denied, which the JSON writes as \n and \t" {
  assert_rebuilt $'cd d\nrm x' $'cd d\ntrash x'
  assert_rebuilt $'find .\t-delete' $'find .\t-exec trash {} + -prune'
}

@test "an unquoted \$( ) leaves the rest of its command one command" {
  assert_rebuilt 'find $(pwd) -name x -delete' 'find $(pwd) -name x -exec trash {} + -prune'
  assert_rebuilt "ssh \$(cat h) 'rm -f x'" "ssh \$(cat h) 'trash x'"
}

@test "a ) quoted inside a \$( ) body does not end it" {
  assert_rebuilt "echo \"\$(echo ')'; rm -rf x)\"" "echo \"\$(echo ')'; trash x)\""
  assert_rebuilt "x=\$(printf ')'; rm y)" "x=\$(printf ')'; trash y)"
}

@test "a << inside (( )) is not a heredoc, so the lines after it are read" {
  assert_rebuilt $'for i in 1 2; do ((m = 1 << i)); done\nrm -f /tmp/x' $'for i in 1 2; do ((m = 1 << i)); done\ntrash /tmp/x'
}

@test "a script written as \$'...' or \$\"...\" is read, with its escapes" {
  decide "bash -c \$'cd /tmp\\nrm -f x'"
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"rm -f x (inside bash -c)"* ]]
  decide "eval \$'rm x'"
  [ "$DECISION" = DENY ]
  decide 'bash -c $"rm x"'
  [ "$DECISION" = DENY ]
}

@test "every deletion in one command is rebuilt" {
  assert_rebuilt 'rm a; ssh h "rm b" && find . -delete' 'trash a; ssh h "trash b" && find . -exec trash {} + -prune'
}

# ---------------------------------------------------------------------------
# Denied: the forms the deny rules cannot see
# ---------------------------------------------------------------------------

@test "xargs rm is denied" {
  assert_rebuilt 'fd -e pyc | xargs -0 rm -f' 'fd -e pyc | xargs -0 trash'
}

@test "find -exec rm is denied" {
  assert_rebuilt "find . -name '*.pyc' -exec rm -f {} +" "find . -name '*.pyc' -exec trash {} +"
}

@test "find -delete is denied and rebuilt as -exec trash" {
  assert_rebuilt "find . -name '*.pyc' -delete" "find . -name '*.pyc' -exec trash {} + -prune"
}

@test "command rm is denied" {
  assert_rebuilt 'command rm x' 'command trash x'
}

@test "a backslashed rm is denied" {
  assert_rebuilt '\rm -rf x' 'trash x'
}

@test "rm by its path is denied" {
  assert_rebuilt '/bin/rm x' 'trash x'
}

# ---------------------------------------------------------------------------
# Denied without a rebuilt command
# ---------------------------------------------------------------------------

@test "git rm --cached and --dry-run are denied, sending the call to the user" {
  decide 'git rm --cached .env'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"next_step [ask-user]: git rm --cached and git rm --dry-run delete nothing on disk"* ]]
  [ -z "$(next_command)" ]
  decide 'git rm -rn dir'
  [[ "$TEXT" == *"next_step [ask-user]"* ]]
}

@test "git rm with --cached or --dry-run anywhere among its words sends the call to the user" {
  decide 'git rm x --cached'
  [[ "$TEXT" == *"next_step [ask-user]"* ]]
  decide 'git rm --dry-run x'
  [[ "$TEXT" == *"next_step [ask-user]"* ]]
}

@test "a deletion whose text cannot be mapped back is denied, to be edited by hand" {
  decide 'bash -c "rm \"$f\""'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"next_step [use-trash]: rerun it with trash in place of each deletion above; the command could not be rebuilt here, so edit it by hand."* ]]
  [ -z "$(next_command)" ]
  decide 'git -C sub rm x'
  [ "$DECISION" = DENY ]
  [[ "$TEXT" == *"edit it by hand."* ]]
}

# ---------------------------------------------------------------------------
# Allowed: a mention of rm that the shell does not run
# ---------------------------------------------------------------------------

@test "trash passes" {
  decide 'trash x'
  [ "$DECISION" = ALLOW ]
}

@test "a search pattern holding rm passes" {
  decide "rg 'rm -f' ."
  [ "$DECISION" = ALLOW ]
}

@test "quoted text holding rm passes, in ssh's script too" {
  decide 'echo "rm -rf is denied"'
  [ "$DECISION" = ALLOW ]
  decide "ssh h \"echo 'rm -rf is denied'\""
  [ "$DECISION" = ALLOW ]
  decide 'gh pr create --draft --title "Deny rm in ssh scripts" --body-file /tmp/b.md'
  [ "$DECISION" = ALLOW ]
}

@test "a commit whose message mentions rm passes, from a file or a heredoc" {
  printf 'Replace rm -rf with trash\n' >"$BATS_TEST_TMPDIR/msg.md"
  decide "git commit --file $BATS_TEST_TMPDIR/msg.md"
  [ "$DECISION" = ALLOW ]
  decide $'git commit --file - <<\'EOF\'\nrm -rf the cache\nEOF'
  [ "$DECISION" = ALLOW ]
}

@test "a heredoc body holding rm passes" {
  decide $'cat >notes.md <<\'EOF\'\nrm -rf /tmp/x\nEOF\necho done'
  [ "$DECISION" = ALLOW ]
}

@test "a comment holding rm passes" {
  decide $'# rm x\nls # rm y'
  [ "$DECISION" = ALLOW ]
}

@test "a command that only names rm or a delete option passes" {
  decide 'command -v rm && man rm'
  [ "$DECISION" = ALLOW ]
  decide 'docker run --rm img && rsync -a --delete a/ b/'
  [ "$DECISION" = ALLOW ]
}

@test "a word that only holds rm after a \$( ) passes" {
  decide 'cp $(mktemp) rm && ls $(pwd)/rm'
  [ "$DECISION" = ALLOW ]
}

@test "an array literal holding rm passes" {
  decide 'args=(rm -f x); echo "${args[@]}"'
  [ "$DECISION" = ALLOW ]
}

@test "a case pattern named rm passes" {
  decide 'case $op in mv|rm) echo x ;; esac'
  [ "$DECISION" = ALLOW ]
  decide $'case $op in\n  rm) echo removing ;;\nesac'
  [ "$DECISION" = ALLOW ]
}

@test "an indented delimiter ends only a <<- heredoc, so a line under a << one stays body" {
  decide $'cat <<EOF\n  EOF\nrm -f x is text here\nEOF'
  [ "$DECISION" = ALLOW ]
}

# ---------------------------------------------------------------------------
# The fast path and the failure paths
# ---------------------------------------------------------------------------

@test "a payload without rm exits 0 with no output, before looking for a parser" {
  run --separate-stderr "$HOOK" <<<"$(bash_payload 'ls -la && git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  run_hook_with_parser none "$HOOK" "$(bash_payload 'ls -la && git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a payload that arrives on a socket is read, as Claude Code sends it" {
  # shellcheck disable=SC2016 # python source
  local on_socket='import os, socket, sys
a, b = socket.socketpair()
a.sendall(sys.stdin.buffer.read())
a.shutdown(socket.SHUT_WR)
os.dup2(b.fileno(), 0)
os.execv(sys.argv[1], sys.argv[1:2])'
  run --separate-stderr bash -c 'printf "%s" "$1" | python3 -I -B -c "$2" "$3"' x "$(bash_payload 'rm -f x')" "$on_socket" "$HOOK"
  echo "status=$status stdout=$output stderr=$stderr"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jaq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
  run --separate-stderr bash -c 'printf "%s" "$1" | python3 -I -B -c "$2" "$3"' x "$(bash_payload 'ls -la')" "$on_socket" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a 1.5 MB command is checked well inside the hook's 5 s timeout" {
  local start end
  {
    printf "git commit --file - <<'EOF'\n"
    printf 'rm -rf the cache, then rebuild it\n%.0s' $(seq 45000)
    printf 'EOF'
  } >"$BATS_TEST_TMPDIR/cmd.txt"
  [ "$(wc -c <"$BATS_TEST_TMPDIR/cmd.txt")" -gt 1500000 ]
  # shellcheck disable=SC2016 # $c is a jaq variable
  jaq -nc --rawfile c "$BATS_TEST_TMPDIR/cmd.txt" '{tool_name: "Bash", tool_input: {command: $c}}' >"$BATS_TEST_TMPDIR/payload.json"
  start=$(date +%s%N)
  run --separate-stderr "$HOOK" <"$BATS_TEST_TMPDIR/payload.json"
  end=$(date +%s%N)
  echo "status=$status took=$(((end - start) / 1000000)) ms"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $(((end - start) / 1000000)) -lt 2500 ]
}

@test "with neither jaq nor jq, a call holding rm is blocked naming the fix" {
  run_hook_with_parser none "$HOOK" "$(bash_payload 'rm -f x')"
  assert_parser_block json-parser-missing
  [[ $REASON == "rm-guard blocked [json-parser-missing]: "* ]]
  [ "${REASON##*$'\n'}" = 'brew install jaq' ]
}

@test "with jq and no jaq, the guard denies as it does with jaq" {
  assert_same_deny_with_jq "$HOOK" "$(bash_payload "ssh h 'rm -f x'")"
}

@test "with a jaq that fails, the guard blocks naming its own failure" {
  run_hook_with_parser broken "$HOOK" "$(bash_payload 'rm -f x')"
  assert_parser_block guard-internal-error
  [[ $REASON == "rm-guard failed [guard-internal-error] at line "* ]]
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

@test "settings.json runs the guard on Bash right after pr-draft-guard, blocking when it fails" {
  run jaq -c '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] as $h
    | ($h | map(.command) | index("~/.claude/pr-draft-guard.sh")) as $i
    | $h[$i + 1]' "$SETTINGS"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"command","command":"~/.claude/rm-guard.sh","timeout":5,"onFailure":"block"}' ]
}

@test "the guard is registered once, and its file is executable" {
  run jaq '[.hooks.PreToolUse[] | .hooks[] | select(.command == "~/.claude/rm-guard.sh")] | length' "$SETTINGS"
  [ "$output" = "1" ]
  [ -x "$HOOK" ]
}
