#!/usr/bin/env bats
# The post-merge and post-checkout hooks relink the claude and secrets packages
# when an update changes them, only from the checkout the deploy target's links
# resolve into, and never fail the git command.
#
# Run: bats tests/restow-on-pull.bats
#
# Each test builds an origin, a deployed clone ("main") whose hooks are the
# ones in this working tree, and a sandbox deploy target. A probe stands in for
# scripts/stow-deploy where a test only needs to know whether and how the hook
# called it; the others run the real script against the sandbox.

bats_require_minimum_version 1.5.0

setup() {
  # An inherited GIT_DIR outranks -C, so every git call below would retarget
  # whichever repo the caller was in.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  load lib/dotfiles-fixture

  FIX="$BATS_TEST_TMPDIR"
  T="$FIX/home"
  export STOW_DEPLOY_TARGET="$T"
  mkdir -p "$T" "$FIX/bin"
  # The hooks call Git LFS and git-crypt; neither may reach the real tools.
  printf '#!/bin/sh\necho "git-lfs $*" >>"%s/lfs.log"\n' "$FIX" >"$FIX/bin/git-lfs"
  printf '#!/bin/sh\nexit 0\n' >"$FIX/bin/git-crypt"
  chmod +x "$FIX/bin/git-lfs" "$FIX/bin/git-crypt"
  PATH="$FIX/bin:$PATH"

  fixture_repo "$FIX/seed"
  cp -R "$FIXTURE_SRC/.githooks" "$FIX/seed/"
  fixture_git "$FIX/seed" add -A
  fixture_git "$FIX/seed" commit -q -m hooks
  git init -q --bare -b dev "$FIX/origin.git"
  fixture_git "$FIX/seed" push -q "$FIX/origin.git" dev
  clone main
}

# clone <name>: a clone of origin with this working tree's hooks turned on.
clone() {
  git clone -q "$FIX/origin.git" "$FIX/$1"
  git -C "$FIX/$1" config core.hooksPath .githooks
}

# upstream <path> <content> [mode]: commit a file to origin's dev from a
# scratch clone that runs no hooks.
upstream() {
  local up="$FIX/up"
  [ -d "$up" ] || git clone -q "$FIX/origin.git" "$up"
  fixture_git "$up" pull -q
  mkdir -p "$(dirname "$up/$1")"
  printf '%s\n' "$2" >"$up/$1"
  [ -z "${3:-}" ] || chmod "$3" "$up/$1"
  fixture_git "$up" add -A
  fixture_git "$up" commit -q -m "change $1"
  fixture_git "$up" push -q origin dev
}

# deploy <clone>: stow both packages from <clone> into the sandbox target.
deploy() {
  "$FIX/$1/scripts/stow-deploy" --headless --only claude secrets >/dev/null 2>&1
}

# link <clone> <package path> <target path>: one link by hand, as stow makes it.
link() {
  mkdir -p "$(dirname "$T/$3")"
  ln -s "$FIX/$1/$2" "$T/$3"
}

# probe <clone> [status]: replace <clone>'s stow-deploy with a recorder that
# exits with [status].
probe() {
  cat >"$FIX/$1/scripts/stow-deploy" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$FIX/probe.log"
env | grep '^GIT_' >>"$FIX/probe.env" || true
echo "probe output"
exit ${2:-0}
EOF
  chmod +x "$FIX/$1/scripts/stow-deploy"
}

probe_calls() {
  [ -f "$FIX/probe.log" ] && wc -l <"$FIX/probe.log" | tr -d ' ' || echo 0
}

pull() {
  fixture_git "$FIX/$1" pull -q "${@:2}"
}

# ---------------------------------------------------------------------------
# Restowing what changed
# ---------------------------------------------------------------------------

@test "a pull that adds a claude script links it before git returns" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  deploy main
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$T/.fixture-new.sh" -ef "$FIX/main/stow/claude/dot-fixture-new.sh" ]
  [[ "$output" == *"restow: claude relinked"* ]]
}

@test "a pull that changes neither package calls nothing and prints nothing new" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main
  upstream README.md 'readme'
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(probe_calls)" -eq 0 ]
  [[ "$output" != *restow* ]]
}

@test "a package whose links resolve through a nested dot- directory counts as deployed here" {
  upstream stow/claude/dot-claude/nested.sh '#!/bin/sh' 755
  fixture_git "$FIX/main" -c core.hooksPath=/dev/null pull -q
  link main stow/claude/dot-claude/nested.sh .claude/nested.sh
  probe main
  upstream stow/claude/dot-fixture-settings.json '{"changed": true}'
  run pull main
  echo "$output"
  [ "$(probe_calls)" -eq 1 ]
  [ "$(cat "$FIX/probe.log")" = "--headless --only claude" ]
}

@test "a pull that changes secrets restows it where the target holds its links" {
  link main stow/secrets/dot-secrets .secrets
  probe main
  upstream stow/secrets/dot-config/never-send/list 'value'
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/probe.log")" = "--headless --only secrets" ]
}

@test "a pull that changes secrets skips it silently where the target holds none of its links" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main
  upstream stow/secrets/dot-config/never-send/list 'value'
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(probe_calls)" -eq 0 ]
  [[ "$output" != *restow* ]]
}

@test "a pull links a new script while a claude file carries uncommitted edits" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  deploy main
  printf '{"model": "edited"}\n' >"$FIX/main/stow/claude/dot-fixture-settings.json"
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$T/.fixture-new.sh" -ef "$FIX/main/stow/claude/dot-fixture-new.sh" ]
}

@test "a rebasing pull links the upstream's new script" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  deploy main
  printf 'local\n' >"$FIX/main/LOCAL.md"
  fixture_git "$FIX/main" add LOCAL.md
  fixture_git "$FIX/main" -c core.hooksPath=/dev/null commit -q -m local
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run pull main --rebase
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$T/.fixture-new.sh" -ef "$FIX/main/stow/claude/dot-fixture-new.sh" ]
}

@test "switching branches restows on each switch that changes claude" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  fixture_git "$FIX/main" fetch -q
  fixture_git "$FIX/main" checkout -q -b side origin/dev
  fixture_git "$FIX/main" checkout -q dev
  [ "$(probe_calls)" -eq 2 ]
}

@test "a file checkout calls nothing" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main
  printf 'scratch\n' >"$FIX/main/stow/claude/dot-fixture-settings.json"
  fixture_git "$FIX/main" checkout -- stow/claude/dot-fixture-settings.json
  [ "$(probe_calls)" -eq 0 ]
}

@test "the pull that delivers the restow hook restows in that same pull" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  # A checkout whose hooks predate the restow: post-merge only exits.
  local old="$FIX/old"
  fixture_repo "$old"
  mkdir -p "$old/.githooks"
  printf '#!/bin/sh\nexit 0\n' >"$old/.githooks/post-merge"
  chmod +x "$old/.githooks/post-merge"
  fixture_git "$old" add -A
  fixture_git "$old" commit -q -m old-hooks
  git init -q --bare -b dev "$FIX/old-origin.git"
  fixture_git "$old" push -q "$FIX/old-origin.git" dev
  git clone -q "$FIX/old-origin.git" "$FIX/deployed"
  git -C "$FIX/deployed" config core.hooksPath .githooks
  "$FIX/deployed/scripts/stow-deploy" --headless --only claude >/dev/null 2>&1
  # The update brings the real hooks and a new claude script together.
  cp -R "$FIXTURE_SRC/.githooks/." "$old/.githooks/"
  printf '#!/bin/sh\n' >"$old/stow/claude/dot-fixture-new.sh"
  chmod +x "$old/stow/claude/dot-fixture-new.sh"
  fixture_git "$old" add -A
  fixture_git "$old" commit -q -m restow-hooks
  fixture_git "$old" push -q "$FIX/old-origin.git" dev
  run fixture_git "$FIX/deployed" pull -q
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$T/.fixture-new.sh" -ef "$FIX/deployed/stow/claude/dot-fixture-new.sh" ]
}

# ---------------------------------------------------------------------------
# Only the checkout that owns the links
# ---------------------------------------------------------------------------

@test "a second clone whose links the target does not hold never restows" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  clone slot
  probe slot
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run pull slot
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(probe_calls)" -eq 0 ]
  [ "$T/.fixture-settings.json" -ef "$FIX/main/stow/claude/dot-fixture-settings.json" ]
}

@test "a second clone with no sandbox target never restows into the real home" {
  clone slot
  probe slot
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run env -u STOW_DEPLOY_TARGET git -C "$FIX/slot" -c user.name=fixture -c user.email=fixture@example.com \
    -c commit.gpgsign=false pull -q
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(probe_calls)" -eq 0 ]
}

@test "a pull from a linked worktree starts stow-deploy without git's hook environment" {
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  fixture_git "$FIX/main" fetch -q
  # A new worktree's post-checkout gets an all-zero previous HEAD and stays quiet.
  run fixture_git "$FIX/main" worktree add -q -b wt "$FIX/wt" HEAD
  [ "$status" -eq 0 ]
  [[ "$output" != *restow* ]]
  fixture_git "$FIX/wt" branch -q -u origin/dev
  link wt stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe wt
  run pull wt
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(probe_calls)" -eq 1 ]
  run grep -E '^(GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE)=' "$FIX/probe.env"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Failures report and never fail git
# ---------------------------------------------------------------------------

@test "a failed restow warns with the rerun command last and leaves pull and checkout at exit 0" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main 5
  upstream stow/claude/dot-fixture-new.sh '#!/bin/sh' 755
  run pull main
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: restow-failed"* ]]
  [[ "$output" == *"exit 5"* ]]
  [[ "$output" == *"probe output"* ]]
  [[ "${lines[-1]}" == *"cd $FIX/main && STOW_DEPLOY_TARGET=$T scripts/stow-deploy --headless --only claude"* ]]
  run fixture_git "$FIX/main" checkout -q -b side HEAD~1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: restow-failed"* ]]
}

@test "a git failure inside the restow reports restow-internal-error and Git LFS still runs" {
  link main stow/claude/dot-fixture-settings.json .fixture-settings.json
  probe main
  # Git puts its own exec-path first on a hook's PATH, so a wrapper cannot fail
  # one git call from inside a real update. A previous HEAD that names no object
  # makes the restow's own git diff-tree fail instead.
  cd "$FIX/main"
  run "$FIX/main/.githooks/post-checkout" 1111111111111111111111111111111111111111 "$(git rev-parse HEAD)" 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: restow-internal-error"* ]]
  [[ "$output" == *"line "*"git diff-tree"* ]]
  [[ "${lines[-1]}" == *"scripts/stow-deploy --headless --only claude"* ]]
  [ "$(probe_calls)" -eq 0 ]
  grep -q '^git-lfs post-checkout ' "$FIX/lfs.log"
}
