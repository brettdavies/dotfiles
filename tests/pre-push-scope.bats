#!/usr/bin/env bats
# Tests for .githooks/lib/push-scope.sh and the skip decision in
# .githooks/pre-push.
#
# Run: bats tests/pre-push-scope.bats

REPO="$BATS_TEST_DIRNAME/.."
LIB="$REPO/.githooks/lib/push-scope.sh"
ZERO=0000000000000000000000000000000000000000

bats_require_minimum_version 1.5.0

# A working repository with a bare origin whose dev holds one shell file, so
# a new ref has a base to compare against and a pushed sha exists on both
# sides. Every test starts from this state.
setup() {
  FIX="$(mktemp -d)"
  WORK="$FIX/work"
  git init -q --bare "$FIX/origin.git"
  git init -q -b dev "$WORK"
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name test
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config core.hooksPath /dev/null
  printf '#!/bin/sh\necho a\n' >"$WORK/a.sh"
  git -C "$WORK" add a.sh
  git -C "$WORK" commit -qm one
  git -C "$WORK" remote add origin "$FIX/origin.git"
  git -C "$WORK" push -q -u origin dev
  DEV_SHA=$(git -C "$WORK" rev-parse HEAD)
}

teardown() {
  rm -rf "$FIX"
}

commit_file() {
  printf '%s\n' "$2" >"$WORK/$1"
  git -C "$WORK" add "$1"
  git -C "$WORK" commit -qm "add $1"
  git -C "$WORK" rev-parse HEAD
}

# scope <line>...: feed the given ref-update lines to push_delivered_files
# from inside the fixture, as the hook does.
scope() {
  run bash -c '. "$1"; cd "$2"; shift 2; printf "%s\n" "$@" | push_delivered_files' _ "$LIB" "$WORK" "$@"
}

# ---------------------------------------------------------------------------
# push_delivered_files: what the push adds to the remote
# ---------------------------------------------------------------------------

@test "a ref delete delivers nothing" {
  scope "(delete) $ZERO refs/heads/feat/x $DEV_SHA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an up-to-date push (empty stdin) delivers nothing" {
  scope ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an update to an existing ref delivers the files changed since the remote sha" {
  new=$(commit_file b.sh 'echo b')
  scope "refs/heads/dev $new refs/heads/dev $DEV_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "b.sh" ]
}

@test "an update whose remote sha is not in this repository is unknown" {
  new=$(commit_file b.sh 'echo b')
  scope "refs/heads/dev $new refs/heads/dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -eq 2 ]
}

@test "a new branch delivers the files changed since its base on origin/dev" {
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "refs/heads/feat/x $new refs/heads/feat/x $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "c.sh" ]
}

@test "a new branch identical to origin/dev delivers nothing" {
  git -C "$WORK" switch -qc feat/x
  scope "refs/heads/feat/x $DEV_SHA refs/heads/feat/x $ZERO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a new branch with no base to compare against is unknown" {
  git -C "$WORK" update-ref -d refs/remotes/origin/dev
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "refs/heads/feat/x $new refs/heads/feat/x $ZERO"
  [ "$status" -eq 2 ]
}

@test "a new branch falls back to origin/main as its base" {
  git -C "$WORK" update-ref refs/remotes/origin/main "$DEV_SHA"
  git -C "$WORK" update-ref -d refs/remotes/origin/dev
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "refs/heads/feat/x $new refs/heads/feat/x $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "c.sh" ]
}

@test "an annotated tag on a pushed commit delivers nothing" {
  git -C "$WORK" tag -a v1 -m v1
  tag=$(git -C "$WORK" rev-parse v1)
  [ "$tag" != "$DEV_SHA" ]
  scope "refs/tags/v1 $tag refs/tags/v1 $ZERO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an annotated tag on an unpushed commit delivers its files" {
  commit_file b.sh 'echo b' >/dev/null
  git -C "$WORK" tag -a v1 -m v1
  tag=$(git -C "$WORK" rev-parse v1)
  scope "refs/tags/v1 $tag refs/tags/v1 $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "b.sh" ]
}

@test "a history rewrite that keeps the tree delivers nothing" {
  git -C "$WORK" commit -q --amend -m "one, reworded"
  new=$(git -C "$WORK" rev-parse HEAD)
  [ "$new" != "$DEV_SHA" ]
  scope "+refs/heads/dev $new refs/heads/dev $DEV_SHA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a delete alongside a content push delivers only the content" {
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "(delete) $ZERO refs/heads/feat/old $DEV_SHA" \
    "refs/heads/feat/x $new refs/heads/feat/x $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "c.sh" ]
}

@test "one unknown ref makes the whole push unknown" {
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "refs/heads/feat/x $new refs/heads/feat/x $ZERO" \
    "refs/heads/dev $new refs/heads/dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -eq 2 ]
}

@test "files across refs are listed once each" {
  git -C "$WORK" switch -qc feat/x
  new=$(commit_file c.sh 'echo c')
  scope "refs/heads/feat/x $new refs/heads/feat/x $ZERO" \
    "refs/heads/feat/y $new refs/heads/feat/y $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "c.sh" ]
}

# ---------------------------------------------------------------------------
# push_files_gate_relevant: does any gate read what is delivered
# ---------------------------------------------------------------------------

@test "markdown alone is not gate-relevant" {
  run bash -c '. "$1"; printf "README.md\ndocs/a/b.md\n" | push_files_gate_relevant' _ "$LIB"
  [ "$status" -eq 1 ]
}

@test "one non-markdown path makes the delivery gate-relevant" {
  run bash -c '. "$1"; printf "README.md\nscripts/x\n" | push_files_gate_relevant' _ "$LIB"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pre-push end to end: does the gate run
# ---------------------------------------------------------------------------

# Install the real hook and lib into the fixture with stub gate scripts that
# record an invocation, and stub tools so every `command -v` succeeds.
install_hook_with_stubs() {
  mkdir -p "$WORK/.githooks/lib" "$WORK/scripts" "$FIX/bin"
  cp "$REPO/.githooks/pre-push" "$WORK/.githooks/pre-push"
  cp "$REPO"/.githooks/lib/*.sh "$WORK/.githooks/lib/"
  for s in lint-shell lint-workflows run-tests; do
    printf '#!/bin/sh\ntouch "%s/ran-%s"\n' "$FIX" "$s" >"$WORK/scripts/$s"
    chmod +x "$WORK/scripts/$s"
  done
  for t in shellcheck actionlint bats git-lfs; do
    printf '#!/bin/sh\nexit 0\n' >"$FIX/bin/$t"
    chmod +x "$FIX/bin/$t"
  done
}

# hook <line>...: run the installed pre-push with the given stdin lines.
hook() {
  run env PATH="$FIX/bin:$PATH" bash -c 'cd "$1"; url=$2; shift 2; printf "%s\n" "$@" | .githooks/pre-push origin "$url"' _ "$WORK" "$FIX/origin.git" "$@"
}

gate_ran() { [ -e "$FIX/ran-lint-shell" ] && [ -e "$FIX/ran-run-tests" ]; }

@test "hook: a ref delete skips the gate" {
  install_hook_with_stubs
  hook "(delete) $ZERO refs/heads/feat/x $DEV_SHA"
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "hook: an up-to-date push skips the gate" {
  install_hook_with_stubs
  hook ""
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "hook: a tag on a pushed commit skips the gate" {
  install_hook_with_stubs
  git -C "$WORK" tag -a v1 -m v1
  hook "refs/tags/v1 $(git -C "$WORK" rev-parse v1) refs/tags/v1 $ZERO"
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "hook: a markdown-only push skips the gate" {
  install_hook_with_stubs
  new=$(commit_file README.md 'hello')
  hook "refs/heads/dev $new refs/heads/dev $DEV_SHA"
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "hook: a ref list larger than the pipe buffer still exits clean" {
  install_hook_with_stubs
  # `git lfs pre-push` exits without draining stdin. Fed through a pipe, the
  # producing side takes SIGPIPE as soon as the ref list outgrows the pipe
  # buffer; pipefail promotes that 141 to the pipeline's status and set -e
  # aborts the push. Deletes keep the scope decision at "delivers nothing", so
  # the only thing under test is the handoff to git-lfs.
  local -a refs=()
  local i
  for i in $(seq 1 1000); do
    refs+=("(delete) $ZERO refs/heads/feat/a-branch-name-long-enough-to-matter-$i $DEV_SHA")
  done
  hook "${refs[@]}"
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "hook: a shell change runs the gate" {
  install_hook_with_stubs
  new=$(commit_file b.sh 'echo b')
  hook "refs/heads/dev $new refs/heads/dev $DEV_SHA"
  [ "$status" -eq 0 ]
  gate_ran
}

@test "hook: an unknown scope runs the gate" {
  install_hook_with_stubs
  new=$(commit_file README.md 'hello')
  hook "refs/heads/dev $new refs/heads/dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -eq 0 ]
  gate_ran
}

@test "hook: a failing gate script fails the push" {
  install_hook_with_stubs
  printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/run-tests"
  new=$(commit_file b.sh 'echo b')
  hook "refs/heads/dev $new refs/heads/dev $DEV_SHA"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# git push through the installed hook: the stdin shapes git really sends
# ---------------------------------------------------------------------------

# Activate the fixture's hook the way stow-deploy does for the real repo.
enable_hook() {
  install_hook_with_stubs
  git -C "$WORK" config core.hooksPath .githooks
}

@test "git push --delete skips the gate" {
  enable_hook
  git -C "$WORK" push -q origin dev:feat/x
  run env PATH="$FIX/bin:$PATH" git -C "$WORK" push -q origin --delete feat/x
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "git push with everything up to date skips the gate" {
  enable_hook
  run env PATH="$FIX/bin:$PATH" git -C "$WORK" push -q origin dev
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "git push of a tag on a pushed commit skips the gate" {
  enable_hook
  git -C "$WORK" tag -a v1 -m v1
  run env PATH="$FIX/bin:$PATH" git -C "$WORK" push -q origin v1
  [ "$status" -eq 0 ]
  run ! gate_ran
}

@test "git push of a shell change runs the gate" {
  enable_hook
  commit_file b.sh 'echo b' >/dev/null
  run env PATH="$FIX/bin:$PATH" git -C "$WORK" push -q origin dev
  [ "$status" -eq 0 ]
  gate_ran
}
