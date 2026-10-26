#!/usr/bin/env bats
# The real .githooks gates, run by git from a linked worktree and from the main
# clone, must keep git's hook environment away from the tools they start.
#
# Run: bats tests/hook-git-env.bats
#
# Each gate script is replaced by a probe that records its arguments and then
# builds a repository of its own with `git -C`, the way a test fixture does. A
# GIT_DIR or GIT_INDEX_FILE the probe inherits from the hook outranks `-C`, so
# the probe's commit lands in the repository being committed or pushed instead.

bats_require_minimum_version 1.5.0

REPO="$BATS_TEST_DIRNAME/.."
GATES='lint-shell lint-workflows run-tests core-env-guard.sh'

setup() {
  # An inherited GIT_DIR outranks `-C`, so every git call below would retarget
  # whichever repo the caller was in. Git exports these to hooks, so a
  # hook-invoked run reaches this file with them set.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  FIX="$BATS_TEST_TMPDIR"
  ORIGIN="$FIX/origin.git"
  MAIN="$FIX/main"
  WT="$FIX/wt"
  mkdir -p "$FIX/bin" "$FIX/children"

  for t in shellcheck actionlint bats git-lfs; do
    printf '#!/bin/sh\nexit 0\n' >"$FIX/bin/$t"
  done
  # The pre-commit gate refuses unsigned commits, so commits sign through a
  # stand-in gpg that reports the status line git waits for.
  cat >"$FIX/bin/fake-gpg" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nstub\n-----END PGP SIGNATURE-----\n'
EOF
  chmod +x "$FIX"/bin/*

  git init -q --bare "$ORIGIN"
  git init -q -b dev "$MAIN"
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name test
  git -C "$MAIN" config commit.gpgsign true
  git -C "$MAIN" config gpg.format openpgp
  git -C "$MAIN" config gpg.program "$FIX/bin/fake-gpg"
  git -C "$MAIN" config user.signingkey test
  git -C "$MAIN" config core.hooksPath /dev/null

  mkdir -p "$MAIN/.githooks/lib" "$MAIN/scripts" "$MAIN/tests"
  cp "$REPO/.githooks/pre-commit" "$REPO/.githooks/pre-push" "$MAIN/.githooks/"
  cp "$REPO"/.githooks/lib/*.sh "$MAIN/.githooks/lib/"
  for s in $GATES; do
    _probe >"$MAIN/scripts/$s"
    chmod +x "$MAIN/scripts/$s"
  done
  printf '#!/usr/bin/env bats\n' >"$MAIN/tests/t.bats"
  printf '#!/bin/sh\necho a\n' >"$MAIN/a.sh"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m seed
  git -C "$MAIN" remote add origin "$ORIGIN"
  git -C "$MAIN" push -q -u origin dev

  git -C "$MAIN" worktree add -q -b feat/x "$WT"
  printf '#!/bin/sh\necho b\n' >"$WT/b.sh"
  git -C "$WT" add b.sh
  git -C "$WT" commit -q -m 'add b.sh'
}

# A gate script stand-in. It records its name and arguments, then creates a
# repository under children/ and commits a file to it. It exits 0 whatever its
# git calls did, like a tool that never checks them, so each test reads the
# repositories for its verdict rather than the hook's exit status.
_probe() {
  cat <<EOF
#!/bin/sh
printf '%s %s\n' "\${0##*/}" "\$*" >>"$FIX/probe.log"
d=\$(mktemp -d "$FIX/children/repo.XXXXXX")
git -C "\$d" init -q
echo x >"\$d/x"
git -C "\$d" add x
git -C "\$d" -c user.name=probe -c user.email=probe@example.com -c commit.gpgsign=false commit -q -m probe
exit 0
EOF
}

enable_hooks() {
  git -C "$MAIN" config core.hooksPath .githooks
}

# git with the stub tools first on PATH, so every gate the hooks look for runs.
hooked_git() {
  PATH="$FIX/bin:$PATH" git "$@"
}

# Every repository a probe created holds the probe's commit, and at least one
# probe ran.
children_own_their_commits() {
  local d n=0
  for d in "$FIX"/children/repo.*; do
    [ -d "$d/.git" ] || {
      echo "no repository of its own: $d"
      return 1
    }
    [ "$(git -C "$d" log --format=%s 2>&1)" = probe ] || {
      echo "no probe commit in $d"
      return 1
    }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# assert_head DIR SHA: DIR's HEAD is still SHA and its tree is clean.
assert_head() {
  local now
  now=$(git -C "$1" rev-parse HEAD)
  [ "$now" = "$2" ] || {
    echo "HEAD moved from $2 to $now:"
    git -C "$1" log --format='  %h %s' "$2..$now"
    return 1
  }
  [ -z "$(git -C "$1" status --porcelain)" ]
}

# assert_one_commit DIR BEFORE MESSAGE: DIR's branch gained exactly one commit
# since BEFORE, with MESSAGE, and its tree is clean.
assert_one_commit() {
  local log
  log=$(git -C "$1" log --format=%s "$2..HEAD")
  [ "$log" = "$3" ] || {
    echo "commits since $2:"
    printf '  %s\n' "$log"
    return 1
  }
  [ -z "$(git -C "$1" status --porcelain)" ]
}

# The main clone is still a non-bare work tree. A probe's `git init` under the
# worktree's GIT_DIR writes core.bare = true into the shared config, after
# which every checkout refuses `git commit`.
assert_main_clone_is_work_tree() {
  [ "$(git -C "$MAIN" config --get core.bare)" = false ] || {
    echo "core.bare in the shared config: $(git -C "$MAIN" config --get core.bare)"
    return 1
  }
  [ "$(git -C "$MAIN" rev-parse --is-inside-work-tree 2>&1)" = true ]
}

@test "a push from a linked worktree leaves its branch alone and each child its own repository" {
  enable_hooks
  before=$(git -C "$WT" rev-parse HEAD)
  run hooked_git -C "$WT" push -q origin feat/x
  assert_main_clone_is_work_tree
  assert_head "$WT" "$before"
  children_own_their_commits
  [ "$status" -eq 0 ]
  [ "$(git -C "$ORIGIN" rev-parse feat/x)" = "$before" ]
}

@test "a commit from a linked worktree records only its own change" {
  enable_hooks
  before=$(git -C "$WT" rev-parse HEAD)
  printf '# change\n' >>"$WT/tests/t.bats"
  git -C "$WT" add tests/t.bats
  run hooked_git -C "$WT" commit -q -m change
  assert_main_clone_is_work_tree
  assert_one_commit "$WT" "$before" change
  children_own_their_commits
  [ "$status" -eq 0 ]
}

# The commit modes below build a temporary index. The hook's own staged-path
# lookup has to read it, so the gate it starts names the file being committed.

@test "commit -a from a linked worktree checks the change it commits" {
  enable_hooks
  before=$(git -C "$WT" rev-parse HEAD)
  printf '# change\n' >>"$WT/tests/t.bats"
  run hooked_git -C "$WT" commit -q -a -m change
  assert_main_clone_is_work_tree
  assert_one_commit "$WT" "$before" change
  grep -qx 'core-env-guard.sh tests/t.bats' "$FIX/probe.log"
  children_own_their_commits
  [ "$status" -eq 0 ]
}

@test "commit <path> from a linked worktree checks the change it commits" {
  enable_hooks
  before=$(git -C "$WT" rev-parse HEAD)
  printf '# change\n' >>"$WT/tests/t.bats"
  run hooked_git -C "$WT" commit -q -m change tests/t.bats
  assert_main_clone_is_work_tree
  assert_one_commit "$WT" "$before" change
  grep -qx 'core-env-guard.sh tests/t.bats' "$FIX/probe.log"
  children_own_their_commits
  [ "$status" -eq 0 ]
}

@test "commit -a from the main clone checks the change it commits" {
  enable_hooks
  before=$(git -C "$MAIN" rev-parse HEAD)
  printf '# change\n' >>"$MAIN/tests/t.bats"
  run hooked_git -C "$MAIN" commit -q -a -m change
  assert_main_clone_is_work_tree
  assert_one_commit "$MAIN" "$before" change
  grep -qx 'core-env-guard.sh tests/t.bats' "$FIX/probe.log"
  children_own_their_commits
  [ "$status" -eq 0 ]
}

@test "pre-commit starts every gate without the git environment" {
  grep -q 'gate_spawn ' "$REPO/.githooks/pre-commit"
  bare=$(grep -n 'gate_spawn ' "$REPO/.githooks/pre-commit" | grep -v 'gate_spawn [a-z-]* git_env_isolated ' || true)
  [ -z "$bare" ] || {
    echo "gates started with the hook's git environment:"
    echo "$bare"
    false
  }
}
