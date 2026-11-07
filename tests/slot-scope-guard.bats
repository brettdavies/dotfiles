#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/slot-scope-guard.sh, the Claude hook that holds a slot's `git push` to the paths its
# brief's Touches: line declares: a push whose commits change a path outside the record's scope.touches globs, and that
# no scope-grant ledger line covers, is denied.
#
# Run: bats tests/slot-scope-guard.bats
#
# The fixtures are those of tests/slot-review-cap.bats: a pane shell that records its own pid as the pane's #{pane_pid},
# then `claude` (a symlink to bash, so /proc comm reads claude), then the hook.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/slot-scope-guard.sh"
RUNS='"$@"; exit $?'

setup_file() {
  load lib/platform
  require_linux "the hook finds the pane's top-level Claude through /proc"
}

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0" TMUX_PANE=%3
  FAKE=$T/fake
  mkdir -p "$FAKE"
  ln -s "$(command -v bash)" "$FAKE/claude"
  printf '%s' repo-1 >"$STUBS/pane-session"
  printf '#!/usr/bin/env bash\nprintf %%s "$$" >"$STUBS/pane-pid"\n"$@"\nexit $?\n' >"$T/pane-shell"
  chmod +x "$T/pane-shell"
  stub tmux '
case " $* " in
  *" display "*) printf "%s\t%s\t%s\n" "$(cat "$STUBS/pane-session")" "$(cat "$STUBS/pane-pid")" /dev/null ;;
esac'
  SLOT=$AGENT_SLOT_ROOT/repo/1
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
  HOOKS_LOG=$AGENT_SLOT_STATE_DIR/logs/hooks.log
  slot repo 1 '{"created_at": "2020-01-01T00:00:00Z",
    "scope": {"touches": ["scripts/agent-slot/**", "tests/*.bats", "docs/guide.md"], "adds": "none"}}'
  mkdir -p "$SLOT/old" "$SLOT/scripts/agent-slot"
  printf 'x\n' >"$SLOT/old/legacy.txt"
  printf 'x\n' >"$SLOT/scripts/agent-slot/verb.sh"
  git -C "$SLOT" add old scripts
  git -C "$SLOT" commit -q -m seed
  git -C "$SLOT" update-ref refs/remotes/origin/main HEAD
  git -C "$SLOT" checkout -q -b feat/one
}

fire() { "$T/pane-shell" "$FAKE/claude" -c "$RUNS" claude "$HOOK"; }

# bash_call COMMAND [CWD]: a PreToolUse payload for the Bash tool, from the slot's Claude, which works in CWD (default:
# the slot).
bash_call() {
  jaq -n -c --arg cwd "${2:-$SLOT}" --arg c "$1" '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd,
    tool_name: "Bash", tool_input: {command: $c}, tool_use_id: "tu1"}' | fire
}

# commit PATH...: a commit on the slot's branch that writes each path.
commit() {
  local p
  for p in "$@"; do
    mkdir -p "$SLOT/$(dirname "$p")"
    printf '%s\n' "$RANDOM" >"$SLOT/$p"
    git -C "$SLOT" add "$p"
  done
  git -C "$SLOT" commit -q -m change
}

# push: a `git push` the hook allows, so it prints nothing.
push() {
  run bash_call "${1:-git push origin feat/one}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# grant_line REPO N PATHSPEC: a scope-grant ledger line, as the operator's verb writes one.
grant_line() {
  jaq -n -c --arg repo "$1" --argjson n "$2" --arg spec "$3" \
    '{schema: "dotfiles.agent-slot/1", ts: "2026-01-01T00:00:00Z", event: "scope-grant", repo: $repo, slot: $n,
      pathspec: $spec}' >>"$LEDGER"
}

# reason: the denial the last `run` printed.
reason() { jaq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"; }

# unrelated_branch: the checked-out branch shares no line of work with the task's, so a push the hook judges answers with the
# retask message.
unrelated_branch() {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b feat/two origin/main
  commit scripts/agent-slot/two.sh
}

# silent COMMAND...: the hook prints nothing for each; fails naming every command it denied.
silent() {
  local c missed=()
  for c in "$@"; do
    run bash_call "$c"
    [ -z "$output" ] || missed+=("$c")
  done
  ((${#missed[@]} == 0)) || {
    printf 'denied: %s\n' "${missed[@]}"
    false
  }
}

# denied COMMAND...: the hook denies each; fails naming every command it let through.
denied() {
  local c missed=()
  for c in "$@"; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || missed+=("$c")
  done
  ((${#missed[@]} == 0)) || {
    printf 'not denied: %s\n' "${missed[@]}"
    false
  }
}

@test "a push from a branch unrelated to the task's branch is denied, naming retask" {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b feat/two origin/main
  commit scripts/agent-slot/two.sh
  run bash_call 'git push origin feat/two'
  [ "$status" -eq 0 ]
  [[ $(reason) == *'agent-slot retask repo/1'* ]]
  [[ $(reason) == *feat/one* ]]
}

@test "the guard holds in a slot whose brief declared no scope" {
  jaq 'del(.scope)' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b feat/two origin/main
  commit scripts/agent-slot/two.sh
  run bash_call 'git push origin feat/two'
  [[ $(reason) == *'agent-slot retask'* ]]
}

@test "a branch change chained before the push gets the chain rule, not a verdict on the branch it leaves" {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b feat/two origin/main
  commit scripts/agent-slot/two.sh
  run bash_call 'git switch feat/one && git push origin feat/one'
  [ "$status" -eq 0 ]
  [[ $(reason) == *'as its own command'* ]]
  [[ $(reason) != *'share no line of work'* ]]
}

@test "a branch stacked on the task's branch is the same task, and is allowed" {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b feat/two
  commit scripts/agent-slot/two.sh
  push 'git push origin feat/two'
}

@test "a probe's branch beside the task's is allowed, whichever one is checked out" {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" checkout -q -b probe/ci origin/main
  commit scripts/agent-slot/two.sh
  push 'git push origin probe/ci'
  git -C "$SLOT" checkout -q feat/one
  push
}

@test "a branch whose work the base already holds is no second task" {
  commit scripts/agent-slot/one.sh
  git -C "$SLOT" update-ref refs/remotes/origin/main feat/one
  git -C "$SLOT" checkout -q -b feat/two origin/main
  commit scripts/agent-slot/two.sh
  push 'git push origin feat/two'
}

@test "a push whose commits change only declared paths is allowed" {
  commit scripts/agent-slot/lib/new.sh tests/a.bats docs/guide.md
  push
}

@test "a push with one undeclared path is denied, naming the path and the step that goes on" {
  commit scripts/agent-slot/lib/new.sh README.md
  run bash_call "git push origin feat/one"
  [ "$status" -eq 0 ]
  jaq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"README.md"* ]]
  [[ $reason != *"scripts/agent-slot/lib/new.sh"* ]]
  [[ $reason == *'`scripts/agent-slot/**`, `tests/*.bats`, `docs/guide.md`'* ]]
  [[ $reason == *"Revert that change"* ]]
  [[ $reason == *"git restore --source=origin/main --staged --worktree -- <path>"* ]]
  [[ $reason != *"git rm"* ]]
  [[ $reason == *'record it under "Not in scope" in the PR body'* ]]
  [[ $reason == *"send the coordinating session a request for a scope grant"* ]]
  [[ $reason == *"the operator grants paths by running \`agent-slot grant-scope repo/1 <pathspec>\` at a terminal, once per pathspec"* ]]
  [[ $reason == *"which you cannot run yourself"* ]]
}

@test "every undeclared path is named, a deleted one and both sides of a rename included" {
  commit src/a.ts docs/other.md
  git -C "$SLOT" rm -q old/legacy.txt
  git -C "$SLOT" mv scripts/agent-slot/verb.sh lib-verb.sh
  git -C "$SLOT" commit -q -m move
  run bash_call "git push"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  for p in src/a.ts docs/other.md old/legacy.txt lib-verb.sh; do
    [[ $reason == *"$p"* ]] || {
      echo "missing $p in: $reason"
      false
    }
  done
  [[ $reason != *"scripts/agent-slot/verb.sh"* ]]
}

@test "a file moved from an undeclared path into a declared one names the old path" {
  printf 'distinct legacy content\n' >"$SLOT/old/legacy.txt"
  git -C "$SLOT" commit -q -am "legacy content"
  git -C "$SLOT" update-ref refs/remotes/origin/main HEAD
  git -C "$SLOT" mv old/legacy.txt scripts/agent-slot/moved.sh
  git -C "$SLOT" commit -q -m move
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  [[ $output == *"old/legacy.txt"* ]]
}

@test "a commit chained before the push is refused, since the hook cannot judge a commit it has not seen" {
  commit scripts/agent-slot/ok.sh
  local c
  for c in "git add -A && git commit --file m && git push" "git commit -m x; git push" "git pull --rebase && git push" \
    "git -C . merge main && git push" "git checkout feat/other && git push origin HEAD" "git switch feat/other && git push" \
    "git commit -m 'handle the -d flag' && git push" "git commit -m 'subject; body' && git push"; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || {
      echo "not denied: $c"
      false
    }
    reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
    [[ $reason == *"run \`git push\` as its own command"* ]]
  done
  push "git push"
}

@test "the push is recognised after timeout, nice, and git options that take a value" {
  commit README.md
  local c
  for c in "timeout 600 git push" "nice -n 5 git push" "git --git-dir .git push" "if ! git push; then :; fi" \
    "while ! git push; do :; done" 'x=`git push`'; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || {
      echo "not denied: $c"
      false
    }
  done
}

@test "a pathspec directory and a glob without a slash both cover what git says they cover" {
  jaq -c '.scope.touches = ["old", "*.md"]' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  commit old/deep/er.txt docs/note.md
  push
  commit old.txt
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  [[ $output == *"old.txt"* ]]
}

@test "a record without scope.touches is never denied" {
  jaq -c 'del(.scope)' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  commit README.md
  push
}

@test "a scope grant covers its matching paths for its own slot only" {
  commit README.md docs/other.md
  grant_line repo 1 README.md
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  [[ $output == *"docs/other.md"* ]]
  [[ $output != *"README.md"* ]]
  grant_line repo 1 'docs/*'
  push
  : >"$LEDGER"
  grant_line repo 2 '*'
  grant_line other 1 '*'
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
}

@test "a grant the operator's verb wrote covers its paths, and the verb's grant for another slot does not" {
  slot repo 2
  commit README.md
  python3 -I "$BATS_TEST_DIRNAME/lib/with-tty.py" repo/2 env -u TMUX -u TMUX_PANE -u CLAUDECODE "$AGENT_SLOT" grant-scope repo/2 README.md \
    >/dev/null
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  python3 -I "$BATS_TEST_DIRNAME/lib/with-tty.py" repo/1 env -u TMUX -u TMUX_PANE -u CLAUDECODE "$AGENT_SLOT" grant-scope repo/1 README.md \
    >/dev/null
  jaq -e 'select(.event == "scope-grant") | .repo == "repo" and .slot == 1 and .pathspec == "README.md"' "$LEDGER"
  push
}

@test "a grant from before the slot was made does not cover a reused slot" {
  commit README.md
  jaq -c '.created_at = "2999-01-01T00:00:00Z"' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  grant_line repo 1 README.md
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
}

@test "the push is recognised in a compound command, after an assignment, and with git's own options" {
  commit README.md
  local c
  for c in "cd $SLOT && git push -u origin feat/one" "FOO=1 git push" "git -C $SLOT push" "git status; git push" \
    $'git status\ngit push' "(git push)" "git --no-pager push --force-with-lease"; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || {
      echo "not denied: $c"
      false
    }
  done
}

@test "the push is recognised behind a wrapper, a path, a keyword, or a shell -c" {
  commit README.md
  local c
  for c in "time git push" "/usr/bin/git push" 'bash -c "git push"' "bash -c 'git push origin x'" "if git push; then :; fi" \
    "{ git push; }" "command git push" "env X=1 git push" "! git push" "nohup git push" "sudo -u me git push"; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || {
      echo "not denied: $c"
      false
    }
  done
}

@test "a push that sends nothing, a dry run or a branch deletion, is not judged" {
  commit README.md
  local c
  for c in "git push --dry-run" "git push origin --delete feat/stale" "git push -d origin feat/stale"; do
    run bash_call "$c"
    [ -z "$output" ] || {
      echo "denied: $c"
      false
    }
  done
}

@test "a no-op flag on another command in the line does not excuse the push, and a no-op push does not excuse a later one" {
  commit README.md
  local c
  for c in "git push -u origin feat/one && git branch -d feat/old" "git push && gh pr create -d --title x" \
    "git push && git push origin --delete feat/stale" "git push origin --delete feat/stale && git push"; do
    run bash_call "$c"
    [[ $output == *'"deny"'* ]] || {
      echo "not denied: $c"
      false
    }
  done
}

@test "the chained-command denial names the command that moves HEAD, and only one before the push counts" {
  commit scripts/agent-slot/ok.sh
  run bash_call "git pull --rebase && git push"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"runs \`git pull\` before it pushes"* ]]
  [[ $reason == *"run \`git push\` as its own command"* ]]
  push "git push; git reset --soft HEAD"
}

@test "a grant whose pathspec git rejects is skipped and logged, and the record's own globs still decide" {
  commit scripts/agent-slot/ok.sh
  grant_line repo 1 ':(bogus)README.md'
  push
  grep -q 'scope-grant pathspec :(bogus)README.md' "$HOOKS_LOG"
  commit README.md
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"README.md"* ]]
  [[ $reason != *"is not a git pathspec"* ]]
}

@test "the denial says the hook judges the slot's own branch whatever the command pushes" {
  commit README.md
  run bash_call "git -C elsewhere push"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"The hook judges this slot's branch whatever the command pushes"* ]]
}

@test "a Touches: glob git rejects in the record denies the push naming it, rather than leaving it unguarded" {
  jaq -c '.scope.touches = ["src/**", ":(nonsense)x"]' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  commit scripts/agent-slot/ok.sh
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *':(nonsense)x'* ]]
  [[ $reason == *"is not a git pathspec"* ]]
}

@test "the denial names the slot, the base it diffed against, and how to ask, and warns about a branch built on another" {
  commit README.md
  run bash_call "git push"
  reason=$(jaq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ $reason == *"Slot repo/1"* ]]
  [[ $reason == *"commits on feat/one against origin/main"* ]]
  [[ $reason == *"as one \`SendMessage\`"* ]]
  [[ $reason == *"If your brief names no such session, leave the decision open in your plan and your report"* ]]
  [[ $reason == *"If these paths come from a branch you built on, do not revert them"* ]]
  [[ $reason == *"\`agent-slot whoami --output json\`"* ]]
}

@test "a command that is not a git push prints nothing, whatever the commits hold" {
  commit README.md
  local c
  for c in "git status" "git log --oneline" "echo git push" "git pull" "git commit -m 'no push'" "ls" "git pushed" \
    'echo "git push"' 'rg -n "git push" README.md' 'git commit -m "git push guard docs"' "git commit -m 'run git push later'"; do
    run bash_call "$c"
    [ -z "$output" ] || {
      echo "denied: $c"
      false
    }
  done
}

@test "a quoted pattern that mentions a push is not a push, in the commands that stopped xurl-rs/1" {
  unrelated_branch
  silent "rg -n 'gh pr edit|body-file|spec-drift-runbook|marker|git push|force' scripts/open-spec-refresh-pr.sh | cut -c1-200 | head -30" \
    $'cd /tmp && src=$(sed -n 28,36p guard.sh); eval "$src" 2>&1 | head -3; for c in "rg -n \'foo|git push\' file" "rg -n \'git push\' file" "echo done"; do if [[ $c =~ $PUSH_RE ]]; then echo "MATCH: $c"; else echo "no match: $c"; fi; done'
  run bash_call "git push origin feat/two"
  [[ $(reason) == *'agent-slot retask repo/1'* ]]
}

@test "separators and push text inside quotes that no shell runs are data, whatever the quote, flag, or line" {
  commit README.md
  silent 'echo "a; git push"' "echo 'a && git push'" 'printf "%s\n" "x | git push origin"' "grep -c 'x; git push' f" \
    $'echo "it\'s; git push"' $'echo \'say "hi"; git push\'' $'echo "say \\"x\\"; git push"' $'rg \'bash -c "git push"\' f' \
    $'echo \'one\ngit push\ntwo\'' $'git commit -m \'document it; git push comes last\'' "rg 'a|b' f | rg 'c|git push'" \
    'x=`rg "a; git push" f`' 'cat <<< "a; git push"'
}

@test "a real push is still found after, between, and around quoted text that holds separators" {
  commit README.md
  denied 'echo "a;b" && git push' "rg 'a|b' f; git push" "echo 'x;y' | git push" "git push origin feat/one && echo 'done; ok'" \
    $'echo "it\'s"; git push' $'echo \'say "hi"\'; git push' $'echo "a\\" b" ; git push ; echo "c\\" d"' \
    $'echo \\\' ; git push ; echo \\\'' 'cd "a b" && git push' "git push origin 'feat/one'" 'git push "origin" feat/one'
}

@test "a quoted script that a shell or eval runs is still read as commands" {
  commit README.md
  denied $'bash -c "rg \'x\' f; git push"' "sh -c 'cd x; git push'" "bash -lc 'x && git push'" 'eval "git status; git push"' \
    "eval 'a && git push'" 'eval "$(echo x)" "a; git push"' "sudo -u me bash -c 'x; git push'" "timeout 5 sh -c 'x | git push'" \
    "x=\$(eval 'a; git push')" '(eval "a; git push")' $'`eval \'a; git push\'`' "{ eval 'a; git push'; }"
}

@test "a script that eval runs inside a substitution is still refused as a chain when it moves HEAD" {
  commit README.md
  run bash_call "\$(eval 'git add -A; git commit -m x'); git push"
  [[ $output == *'"deny"'* ]]
  [[ $(reason) == *"run \`git push\` as its own command"* ]]
}

@test "a no-op flag inside a quoted string does not excuse the push" {
  commit README.md
  denied "git push -o 'skip; -d tmp' origin feat/one" "git push -o 'a && --dry-run x' origin feat/one"
}

@test "a command substitution inside double quotes is code, nested quotes included" {
  commit README.md
  denied 'echo "$(git push)"' $'echo "`git push`"' 'echo "x $(echo "b"; git push)"' 'bash -c "echo $(echo "x"); git push"' \
    'echo "result: $(git status && git push)"' 'echo "$(date)" "$(echo "b"; git push)"'
}

@test "text the reader does not model, a heredoc body, a comment, an ANSI-C string, or an open quote, is read as written" {
  commit README.md
  denied $'cat <<EOF\ndon\'t\nEOF\ngit push origin x\ncat <<EOF\nwon\'t\nEOF' $'echo x # don\'t\ngit push origin x\necho y # won\'t' \
    $'echo $\'\\\'\' ; git push ; echo $\'\\\'\'' $'echo \'oops; git push'
}

@test "a push counts the commits against the slot's base, not the commit before" {
  commit README.md
  git -C "$SLOT" update-ref refs/remotes/origin/main HEAD
  commit scripts/agent-slot/ok.sh
  push
}

@test "a base the clone has no origin ref for is logged and the push allowed" {
  commit README.md
  jaq -c '.base = "gone"' "$SLOT/.git/agent-slot.json" >"$T/record.new"
  mv "$T/record.new" "$SLOT/.git/agent-slot.json"
  push
  grep -q 'origin/gone' "$HOOKS_LOG"
}

@test "a push from a directory outside the slot is judged for the slot the pane belongs to" {
  commit README.md
  mkdir -p "$T/scratch"
  run bash_call "git push" "$T/scratch"
  [[ $output == *'"deny"'* ]]
}

@test "a subagent's push is judged as the slot's" {
  commit README.md
  run fire < <(jaq -n -c --arg cwd "$SLOT" '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd,
    tool_name: "Bash", tool_input: {command: "git push"}, agent_id: "a7", agent_type: "general-purpose"}')
  [[ $output == *'"deny"'* ]]
}

@test "a tool other than Bash is never judged" {
  commit README.md
  run fire < <(jaq -n -c --arg cwd "$SLOT" '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $cwd,
    tool_name: "Write", tool_input: {command: "git push"}}')
  [ -z "$output" ]
}

@test "outside a slot the hook prints nothing" {
  commit README.md
  export TMUX="/tmp/tmux-1000/default,4242,0"
  run bash_call "git push"
  [ -z "$output" ]
  unset TMUX
  run bash_call "git push"
  [ -z "$output" ]
  printf '%s' repo-1-files >"$STUBS/pane-session"
  export TMUX="$T/$AGENT_SLOT_TMUX_SOCKET,4242,0"
  run bash_call "git push"
  [ -z "$output" ]
}

@test "a slot whose record cannot be read has its push allowed" {
  commit README.md
  rm "$SLOT/.git/agent-slot.json"
  push
}

@test "a ledger that cannot be read leaves the declared paths in force" {
  commit README.md
  mkdir -p "$LEDGER"
  run bash_call "git push"
  [[ $output == *'"deny"'* ]]
}

@test "a malformed payload prints nothing and exits 0" {
  run fire <<<'not json {'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run fire <<<'git push'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
