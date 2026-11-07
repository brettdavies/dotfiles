#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/session-title.sh, the UserPromptSubmit hook that names a generic Claude session
# after its branch or PR through the hook's sessionTitle output.
#
# Run: bats tests/session-title.bats
#
# The hook reads Claude Code's payload on stdin and prints either one JSON object or nothing. It prints nothing for a
# session that already has a custom title, a slot, a prime, a base branch, a detached head, and anything that is not a
# git checkout. gh is a stub, git is real, and every checkout lives under BATS_TEST_TMPDIR.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/agent-slot

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/session-title.sh"

setup() {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  agent_slot_setup
  stub gh 'cat "$STUBS/gh-out" 2>/dev/null || echo "[]"; exit "$(cat "$STUBS/gh-exit" 2>/dev/null || echo 0)"'
}

# checkout DIR BRANCH [ORIGIN]: a git checkout on BRANCH with one commit, whose origin is a URL string no one fetches.
checkout() {
  git init -q -b "$2" "$1"
  git -C "$1" commit -q --allow-empty -m seed
  [[ -z ${3:-} ]] || git -C "$1" remote add origin "$3"
}

# fire CWD [SESSION_TITLE]: runs the hook for a UserPromptSubmit in CWD, with the session's custom title when given.
fire() {
  jaq -n -c --arg cwd "$1" --arg title "${2:-}" \
    '{hook_event_name: "UserPromptSubmit", session_id: "s1", prompt: "hello", cwd: $cwd}
      + (if $title == "" then {} else {session_title: $title} end)' | "$HOOK"
}

title_of() { jaq -r '.hookSpecificOutput.sessionTitle' <<<"$output"; }

# titled WANT: the last run printed the title WANT; a miss shows what it printed.
titled() { [ "$(title_of 2>/dev/null)" = "$1" ] || { echo "want title '$1', hook printed: ${output:-nothing}"; false; }; }

# untitled: the last run printed nothing; a miss shows what it printed.
untitled() { [ -z "$output" ] || { echo "want no title, hook printed: $output"; false; }; }

HOOKS_LOG() { printf '%s' "$AGENT_SLOT_STATE_DIR/logs/hooks.log"; }

gh_calls() { grep -c '^gh ' "$CALLS" || true; }

@test "a feature branch with no PR titles the session after the repo and the branch" {
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jaq -e '. == {hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: "widget-branch-fix-login-timeout"}}' <<<"$output"
}

@test "a branch with an open PR is titled the way a slot for that PR is named" {
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  printf '%s' '[{"number": 887, "title": "Fix the login timeout"}]' >"$STUBS/gh-out"
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-pr887-fix-the-login-timeout
  grep -qF -- 'gh pr list --repo acme/widget --head fix/login-timeout --state open --json number,title,isCrossRepository --limit 100' "$CALLS"
}

@test "a gh that fails leaves the title to the branch" {
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  printf '1' >"$STUBS/gh-exit"
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-branch-feat-dark-mode
}

@test "gh answering with something that is not a PR list leaves the title to the branch" {
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  printf '%s' 'not json' >"$STUBS/gh-out"
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-branch-feat-dark-mode
}

@test "a checkout with no origin is titled by its directory's name and never asks gh" {
  checkout "$T/work/scratch" feat/try-it
  run --separate-stderr fire "$T/work/scratch"
  [ "$status" -eq 0 ]
  titled scratch-branch-feat-try-it
  [ "$(gh_calls)" -eq 0 ]
}

@test "a title past 64 characters keeps its source and loses the slug's last words" {
  checkout "$T/work/widget" feat/one-two-three-four-five-six-seven-eight-nine-ten-eleven-twelve git@github.com:acme/widget.git
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-branch-feat-one-two-three-four-five-six-seven-eight-nine
  [[ $(title_of) =~ ^[A-Za-z0-9][A-Za-z0-9_/-]{0,63}$ ]]
}

@test "a session that already has a custom title keeps it, and the hook runs no gh" {
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  run --separate-stderr fire "$T/work/widget" my-own-name
  [ "$status" -eq 0 ]
  untitled
  [ "$(gh_calls)" -eq 0 ]
}

@test "a base branch gets no title" {
  local branch
  for branch in main master dev develop release/2026.11.06; do
    rm -rf "$T/work/widget"
    checkout "$T/work/widget" "$branch" git@github.com:acme/widget.git
    run --separate-stderr fire "$T/work/widget"
    [ "$status" -eq 0 ]
    untitled || { echo "branch $branch"; false; }
  done
  [ "$(gh_calls)" -eq 0 ]
}

@test "a detached head gets no title" {
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  git -C "$T/work/widget" checkout -q --detach
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  untitled
}

@test "a directory that is not a git checkout, and one that does not exist, get no title" {
  mkdir -p "$T/work/plain"
  run --separate-stderr fire "$T/work/plain"
  [ "$status" -eq 0 ]
  untitled
  run --separate-stderr fire "$T/work/missing"
  [ "$status" -eq 0 ]
  untitled
}

@test "a slot's own Claude gets no title, on a feature branch or from a directory below its root" {
  slot widget 1 '{"task": "t"}'
  git -C "$AGENT_SLOT_ROOT/widget/1" checkout -q -b fix/login-timeout
  mkdir -p "$AGENT_SLOT_ROOT/widget/1/src"
  run --separate-stderr fire "$AGENT_SLOT_ROOT/widget/1"
  [ "$status" -eq 0 ]
  untitled
  run --separate-stderr fire "$AGENT_SLOT_ROOT/widget/1/src"
  untitled
  [ "$(gh_calls)" -eq 0 ]
}

@test "a prime on a feature branch gets no title, so it keeps the name its repo gives it" {
  prime widget
  git -C "$AGENT_SLOT_DEV/widget" checkout -q -b fix/login-timeout
  run --separate-stderr fire "$AGENT_SLOT_DEV/widget"
  [ "$status" -eq 0 ]
  untitled
  [ "$(gh_calls)" -eq 0 ]
}

@test "an extra prime outside the dev root gets no title either" {
  checkout "$T/extra/notes" fix/login-timeout git@github.com:acme/notes.git
  AGENT_SLOT_EXTRA_PRIMES=$T/extra/notes run --separate-stderr fire "$T/extra/notes"
  [ "$status" -eq 0 ]
  untitled
}

@test "a linked worktree of a prime is a checkout of its own and is titled by its branch" {
  prime widget
  git -C "$AGENT_SLOT_DEV/widget" worktree add -q -b fix/login-timeout "$T/work/widget-wt"
  run --separate-stderr fire "$T/work/widget-wt"
  [ "$status" -eq 0 ]
  titled widget-branch-fix-login-timeout
}

@test "a payload with no cwd gets no title, whatever directory the hook runs in" {
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  run --separate-stderr bash -c 'cd "$1" && printf "{\"hook_event_name\":\"UserPromptSubmit\"}" | "$2"' x "$T/work/widget" "$HOOK"
  [ "$status" -eq 0 ]
  untitled
}

@test "a payload that arrives on a socket, as Claude Code hands it to a hook, is read" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  checkout "$T/work/widget" fix/login-timeout git@github.com:acme/widget.git
  # shellcheck disable=SC2016 # python source
  local on_socket='import os, socket, sys
a, b = socket.socketpair()
a.sendall(sys.stdin.buffer.read())
a.shutdown(socket.SHUT_WR)
os.dup2(b.fileno(), 0)
os.execv(sys.argv[1], sys.argv[1:2])'
  run --separate-stderr bash -c 'jaq -n -c --arg cwd "$1" "{hook_event_name: \"UserPromptSubmit\", cwd: \$cwd}" | python3 -I -B -c "$2" "$3"' \
    x "$T/work/widget" "$on_socket" "$HOOK"
  [ "$status" -eq 0 ]
  titled widget-branch-fix-login-timeout
}

@test "an empty or malformed payload exits 0 and prints nothing" {
  run --separate-stderr bash -c 'printf "" | "$1"' x "$HOOK"
  [ "$status" -eq 0 ]
  untitled
  run --separate-stderr bash -c 'printf "{not json" | "$1"' x "$HOOK"
  [ "$status" -eq 0 ]
  untitled
}

@test "the hook is registered for UserPromptSubmit, synchronous, with a timeout" {
  local settings=$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json
  run jaq -c '[.hooks.UserPromptSubmit[].hooks[] | select(.command == "~/.claude/session-title.sh")]' "$settings"
  [ "$status" -eq 0 ]
  jaq -e 'length == 1 and (.[0] | .type == "command" and (.async // false) == false and (.timeout | type == "number" and . <= 10))' <<<"$output"
}

@test "a gh that hangs is cut off at its bound and leaves the title to the branch" {
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  stub gh 'sleep 30'
  local start=$SECONDS
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-branch-feat-dark-mode
  ((SECONDS - start < 10)) || { echo "the hook took $((SECONDS - start)) s"; false; }
}

@test "a failed gh lookup leaves a labelled line and gh's own output in hooks.log" {
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  stub gh 'echo "boom from gh" >&2; exit 1'
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  grep -Eq '^[0-9T:Z-]+ session-title\[[0-9]+\] reason=gh-pr-list-failed repo=acme/widget branch=feat/dark-mode$' "$(HOOKS_LOG)" ||
    { cat "$(HOOKS_LOG)" 2>&1; false; }
  grep -q 'boom from gh' "$(HOOKS_LOG)" || { cat "$(HOOKS_LOG)" 2>&1; false; }
}

@test "an origin that is not on GitHub is named from its path and never asked about" {
  checkout "$T/work/widget" feat/dark-mode https://gitlab.com/group/sub/widget.git
  printf '%s' '[{"number": 42, "title": "A PR in an unrelated GitHub repo"}]' >"$STUBS/gh-out"
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  titled widget-branch-feat-dark-mode
  [ "$(gh_calls)" -eq 0 ]
}

@test "a PR from another repository's fork never counts, and one from this repository does" {
  checkout "$T/work/widget" patch-1 git@github.com:acme/widget.git
  printf '%s' '[{"number": 5, "title": "A stranger fix", "isCrossRepository": true}]' >"$STUBS/gh-out"
  run --separate-stderr fire "$T/work/widget"
  titled widget-branch-patch-1
  printf '%s' '[{"number": 5, "title": "A stranger fix", "isCrossRepository": true},
    {"number": 9, "title": "Our fix", "isCrossRepository": false}]' >"$STUBS/gh-out"
  run --separate-stderr fire "$T/work/widget"
  titled widget-pr9-our-fix
}

@test "the branch origin's HEAD names is a base branch" {
  checkout "$T/work/widget" trunk git@github.com:acme/widget.git
  git -C "$T/work/widget" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  untitled
  [ "$(gh_calls)" -eq 0 ]
}

@test "a library that fails to load leaves a labelled line in hooks.log and prints nothing" {
  local fake=$T/fake
  mkdir -p "$fake/stow/claude/dot-claude" "$fake/scripts"
  cp "$HOOK" "$fake/stow/claude/dot-claude/session-title.sh"
  cp -R "$BATS_TEST_DIRNAME/../scripts/agent-slot" "$fake/scripts/agent-slot"
  printf 'if then\n' >"$fake/scripts/agent-slot/lib/items.sh"
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  HOOK=$fake/stow/claude/dot-claude/session-title.sh run --separate-stderr fire "$T/work/widget"
  [ "$status" -eq 0 ]
  untitled
  grep -Eq 'session-title\[[0-9]+\] reason=lib-load-failed lib=items.sh next="cd ~/dotfiles && scripts/stow-deploy --headless --only claude"$' "$(HOOKS_LOG)" ||
    { cat "$(HOOKS_LOG)" 2>&1; false; }
}

@test "an origin URL whose repo name holds a newline gets the session no title, and the hook still returns" {
  checkout "$T/work/widget" feat/dark-mode git@github.com:acme/widget.git
  git -C "$T/work/widget" config remote.origin.url $'git@github.com:acme/wid\nget.git'
  run --separate-stderr timeout 20 "$HOOK" <<<"{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"$T/work/widget\"}"
  [ "$status" -eq 0 ] || { echo "status $status, stdout: $output"; false; }
  untitled
}
