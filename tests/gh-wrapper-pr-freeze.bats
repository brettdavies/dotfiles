#!/usr/bin/env bats
# Tests for the gh wrapper's PR freeze: no pull request or PR stack may be
# opened on a repository listed in the freeze file.
#
# Run: bats tests/gh-wrapper-pr-freeze.bats

WRAPPER="$BATS_TEST_DIRNAME/../stow/gh/dot-local/bin/gh"

# A fake real gh that records that it ran and echoes its stdin, sits right
# behind the wrapper at the front of PATH, so the wrapper's PATH walk stops
# there before the host's own gh. GH_PR_FREEZE_FILE keeps the host's freeze
# file out of the run.
setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/alias" "$TMP/real"
  ln -s "$WRAPPER" "$TMP/alias/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "${FAKE_GH_MARKER:?}"' 'echo "fake real gh"' '[ -t 0 ] || cat' >"$TMP/real/gh"
  chmod +x "$TMP/real/gh"
  export FAKE_GH_MARKER="$TMP/fake-gh-ran"
  export PATH="$TMP/alias:$TMP/real:$PATH"
  unset GH_REPO

  export GH_PR_FREEZE_FILE="$TMP/freeze.txt"
  printf '%s\n' '# frozen upstreams' 'tobi/qmd  # vetted on the fork first' '# someone/else' >"$GH_PR_FREEZE_FILE"

  FORK="$TMP/fork-clone"
  git init -q "$FORK"
  git -C "$FORK" remote add origin https://github.com/brettdavies/qmd.git
  git -C "$FORK" remote add upstream git@github.com:tobi/qmd.git

  OTHER="$TMP/other-clone"
  git init -q "$OTHER"
  git -C "$OTHER" remote add origin https://github.com/brettdavies/dotfiles.git
}

teardown() {
  rm -rf "$TMP"
}

# Runs the wrapper from checkout $1 with the remaining args.
gh_in() {
  local dir=$1
  shift
  cd "$dir" && gh "$@" </dev/null
}

blocked() {
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Blocked:"*"PR freeze"* ]]
  [ ! -e "$FAKE_GH_MARKER" ]
}

passed() {
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ -e "$FAKE_GH_MARKER" ]
}

# ---------------------------------------------------------------------------
# Blocked: pull requests aimed at a frozen repo
# ---------------------------------------------------------------------------

@test "unqualified pr create in a checkout with a frozen remote is blocked" {
  run gh_in "$FORK" pr create --title t --body-file /tmp/b.md
  blocked
}

@test "pr create -R frozen from an unrelated checkout is blocked" {
  run gh_in "$OTHER" pr create -R tobi/qmd --title t
  blocked
}

@test "pr create --repo=frozen is blocked" {
  run gh_in "$OTHER" pr create --repo=tobi/qmd --title t
  blocked
}

@test "pr create --repo with a host prefix and mixed case is blocked" {
  run gh_in "$OTHER" pr create --repo github.com/Tobi/QMD --title t
  blocked
}

@test "GH_REPO=frozen pr create is blocked" {
  run env GH_REPO=tobi/qmd gh pr create --title t </dev/null
  blocked
}

@test "unqualified stack submit in a checkout with a frozen remote is blocked" {
  run gh_in "$FORK" stack submit --auto
  blocked
}

@test "unqualified stack link in a checkout with a frozen remote is blocked" {
  run gh_in "$FORK" stack link --base main stack/a stack/b
  blocked
}

@test "stack submit with -R fork is still blocked, since gh-stack ignores -R" {
  run gh_in "$FORK" stack submit -R brettdavies/qmd
  blocked
}

@test "api POST to a frozen repo's pulls is blocked" {
  run gh_in "$OTHER" api -X POST repos/tobi/qmd/pulls -f title=t -f head=a -f base=main
  blocked
}

@test "api with fields (implicit POST) to a frozen repo's pulls is blocked" {
  run gh_in "$OTHER" api /repos/tobi/qmd/pulls -f title=t -f head=a -f base=main
  blocked
}

@test "api graphql createPullRequest in a field is blocked" {
  run gh_in "$OTHER" api graphql -f query='mutation { createPullRequest(input: {}) { pullRequest { url } } }'
  blocked
}

@test "api graphql createPullRequest on stdin is blocked" {
  run bash -c 'cd "$1" && printf "%s" "{\"query\": \"mutation { createPullRequest(input: {}) { clientMutationId } }\"}" | gh api graphql --input -' _ "$OTHER"
  blocked
}

# ---------------------------------------------------------------------------
# Passed: the fork, reads, comments, and repos the list does not name
# ---------------------------------------------------------------------------

@test "pr create -R fork in a checkout with a frozen remote passes" {
  run gh_in "$FORK" pr create -R brettdavies/qmd --base main --title t --draft
  passed
}

@test "GH_REPO=fork stack submit in a checkout with a frozen remote passes" {
  run bash -c 'cd "$1" && GH_REPO=brettdavies/qmd gh stack submit --auto </dev/null' _ "$FORK"
  passed
}

@test "unqualified pr create in a checkout with no frozen remote passes" {
  run gh_in "$OTHER" pr create --title t
  passed
}

@test "reads and comments on a frozen repo pass" {
  run gh_in "$FORK" pr view 983 -R tobi/qmd --json state
  passed
  rm -f "$FAKE_GH_MARKER"
  run gh_in "$FORK" issue comment 952 -R tobi/qmd --body-file /tmp/c.md
  passed
  rm -f "$FAKE_GH_MARKER"
  run gh_in "$FORK" pr comment 983 -R tobi/qmd --body-file /tmp/c.md
  passed
}

@test "api GET on a frozen repo's pulls passes" {
  run gh_in "$OTHER" api repos/tobi/qmd/pulls --jq '.[].number'
  passed
  rm -f "$FAKE_GH_MARKER"
  run gh_in "$OTHER" api -X GET repos/tobi/qmd/pulls -f state=open
  passed
}

@test "api POST to a PR's review comments on a frozen repo passes" {
  run gh_in "$OTHER" api repos/tobi/qmd/pulls/983/comments -f body=x
  passed
}

@test "api graphql query without createPullRequest passes stdin through" {
  run bash -c 'cd "$1" && printf "%s" "{\"query\": \"{ viewer { login } }\"}" | gh api graphql --input -' _ "$OTHER"
  passed
  [[ "$output" == *"viewer { login }"* ]]
}

@test "a repo named only in a comment line is not frozen" {
  run gh_in "$OTHER" pr create -R someone/else --title t
  passed
}

@test "an empty freeze file freezes nothing" {
  printf '# nothing frozen\n' >"$GH_PR_FREEZE_FILE"
  run gh_in "$FORK" pr create -R tobi/qmd --title t
  passed
}

@test "a missing freeze file freezes nothing" {
  rm -f "$GH_PR_FREEZE_FILE"
  run gh_in "$FORK" pr create -R tobi/qmd --title t
  passed
}
