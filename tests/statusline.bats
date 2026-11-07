#!/usr/bin/env bats
# Tests for stow/claude/dot-claude/statusline.sh, the status line of every Claude session.
#
# Run: bats tests/statusline.bats
#
# A prime's Claude keeps its <repo>-prime title, so its status line shows the work it is on instead: the label
# session-title.sh gives a generic session, from the branch or the open PR, and nothing on a base branch. A prime is a
# session named *-prime in a prime checkout, a clone with an origin directly under the dev root, which these tests put
# at BATS_TEST_TMPDIR. Every other session's line is unchanged. The checkouts are real git repos, and stderr is dropped:
# a clean repo makes the git counts print "integer expression expected", which leaves the line itself intact.
# run-tests: parallel

STATUSLINE="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/statusline.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  T=$BATS_TEST_TMPDIR
  export GIT_CONFIG_GLOBAL=$T/gitconfig
  git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
  git config --file "$GIT_CONFIG_GLOBAL" user.name Test
  git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
  export AGENT_SLOT_DEV=$T AGENT_SLOT_EXTRA_PRIMES=
}

# checkout DIR BRANCH: a git checkout on BRANCH with one commit and an origin no one fetches.
checkout() {
  git init -q -b "$2" "$1"
  git -C "$1" commit -q --allow-empty -m seed
  git -C "$1" remote add origin "git@github.com:acme/${1##*/}.git"
}

# line SESSION_NAME CWD [PR_NUMBER] [REPO_NAME]: the status line Claude Code would draw, colour codes removed.
# SESSION_NAME is empty for a session with no name; the repo is acme/REPO_NAME when given.
line() {
  jq -n -c --arg name "$1" --arg cwd "$2" --arg pr "${3:-}" --arg repo "${4:-}" \
    '{model: {display_name: "Opus"}, workspace: {current_dir: $cwd}, context_window: {remaining_percentage: 80}}
      + (if $name == "" then {} else {session_name: $name} end)
      + (if $repo == "" then {} else {workspace: {current_dir: $cwd, repo: {host: "github.com", owner: "acme", name: $repo}}} end)
      + (if $pr == "" then {} else {pr: {number: ($pr | tonumber), url: "https://github.com/acme/widget/pull/1"}} end)' |
    "$STATUSLINE" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g'
}

@test "a prime on a feature branch shows the work it is on after its git segment" {
  checkout "$T/widget" fix/login-timeout
  run line widget-prime "$T/widget" "" widget
  [ "$status" -eq 0 ]
  [[ $output == *" | fix/login-timeout | task:widget-branch-fix-login-timeout | O | ctx:80%" ]]
}

@test "a prime whose branch has an open PR shows the PR's label" {
  checkout "$T/widget" fix/login-timeout
  run line widget-prime "$T/widget" 887 widget
  [ "$status" -eq 0 ]
  [[ $output == *" | task:widget-pr887-fix-login-timeout | O"* ]]
}

@test "a prime on a base branch shows no task, and its line matches a session that is not a prime's" {
  local branch prime other
  for branch in main master dev develop release/2026.11.06; do
    rm -rf "$T/widget"
    checkout "$T/widget" "$branch"
    prime=$(line widget-prime "$T/widget" "" widget)
    other=$(line widget-pr7-fix "$T/widget" "" widget)
    [[ $prime != *task:* ]] || { echo "$branch: $prime"; false; }
    [ "$prime" = "$other" ]
  done
}

@test "a prime on a detached head shows no task" {
  checkout "$T/widget" fix/login-timeout
  git -C "$T/widget" checkout -q --detach
  run line widget-prime "$T/widget" "" widget
  [ "$status" -eq 0 ]
  [[ $output != *task:* ]]
}

@test "a session that is not a prime's shows no task, whatever its name" {
  local name
  checkout "$T/widget" fix/login-timeout
  for name in '' my-own-name widget-pr887-fix-login-timeout fix-login prime primer; do
    run line "$name" "$T/widget" 887 widget
    [ "$status" -eq 0 ]
    [[ $output != *task:* ]] || { echo "name '$name': $output"; false; }
  done
}

@test "a prime in a checkout with no repo in the payload is labelled by the directory's name" {
  checkout "$T/scratch" feat/try-it
  run line scratch-prime "$T/scratch"
  [ "$status" -eq 0 ]
  [[ $output == *" | task:scratch-branch-feat-try-it | O"* ]]
}

@test "a prime outside a git checkout shows no task and still draws the line" {
  mkdir -p "$T/plain"
  run line plain-prime "$T/plain" "" plain
  [ "$status" -eq 0 ]
  [[ $output == *" | O | ctx:80%" ]]
  [[ $output != *task:* ]]
}

@test "the line is one line however the prime is labelled" {
  checkout "$T/widget" fix/login-timeout
  run line widget-prime "$T/widget" 887 widget
  [ "${#lines[@]}" -eq 1 ]
}

@test "a session named like a prime's, in a checkout that is not a prime's, shows no task" {
  checkout "$T/elsewhere/widget" fix/login-timeout
  run line widget-prime "$T/elsewhere/widget" "" widget
  [ "$status" -eq 0 ]
  [[ $output != *task:* ]] || { echo "$output"; false; }
}

@test "a generic session titled from a branch that ends in -prime shows no task" {
  checkout "$T/elsewhere/widget" fix/agent-slot-prime
  run line widget-branch-fix-agent-slot-prime "$T/elsewhere/widget" "" widget
  [ "$status" -eq 0 ]
  [[ $output != *task:* ]] || { echo "$output"; false; }
}

@test "a prime on the branch origin's HEAD names shows no task" {
  checkout "$T/widget" trunk
  git -C "$T/widget" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run line widget-prime "$T/widget" "" widget
  [ "$status" -eq 0 ]
  [[ $output != *task:* ]] || { echo "$output"; false; }
}
