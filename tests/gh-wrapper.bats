#!/usr/bin/env bats
# Tests for the gh CLI wrapper that blocks AI merges to main
#
# Run: bats tests/gh-wrapper.bats

WRAPPER="$BATS_TEST_DIRNAME/../stow/gh/dot-local/bin/gh"

# A PATH where the wrapper is reachable under a spelling other than
# $HOME/.local/bin/gh, followed by a fake real gh that records its invocation.
# HOME points at an empty dir so the host's own ~/.local/bin/gh cannot leak
# into the run.
setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/alias" "$TMP/real" "$TMP/home"
  ln -s "$WRAPPER" "$TMP/alias/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "${FAKE_GH_MARKER:?}"' 'echo "fake real gh"' >"$TMP/real/gh"
  chmod +x "$TMP/real/gh"
  export FAKE_GH_MARKER="$TMP/fake-gh-ran"
  FAKE_PATH="$TMP/alias:$TMP/real:/usr/bin:/bin"
  unset GH_REPO
}

teardown() {
  rm -rf "$TMP"
}

# Resolves an absolute path because every caller runs `timeout` under a
# constructed PATH that omits the Homebrew prefix. Probing the ambient PATH and
# then invoking the bare name passes the guard on macOS and still dies at 127,
# since GNU coreutils installs no /usr/bin/timeout there.
_require_timeout() {
  TIMEOUT_BIN="$(command -v timeout || true)"
  [ -n "$TIMEOUT_BIN" ] || skip "timeout not installed"
}

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "gh wrapper passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$WRAPPER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# find_real_gh
# ---------------------------------------------------------------------------

@test "gh wrapper finds real gh binary" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # Run a passthrough command — if find_real_gh fails, the wrapper exits 1
  run "$WRAPPER" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh version"* ]]
}

@test "gh wrapper skips itself when reachable under an alias path" {
  _require_timeout
  # The alias dir sits ahead of the fake real gh. A wrapper that fails to
  # recognise the alias as itself execs it and spins in place; timeout turns
  # that spin into exit 124 instead of a hung test.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
  [ -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper skips a separate copy of itself on PATH" {
  _require_timeout
  # A second checkout (a worktree, a fleet scratch clone) puts another copy of
  # this wrapper on PATH: same content, different inode, so an identity check
  # alone hands it to exec and the guard fires. The real gh is a binary; a
  # candidate carrying the guard marker is a wrapper and must be skipped.
  mkdir -p "$TMP/copy"
  cp "$WRAPPER" "$TMP/copy/gh"
  chmod +x "$TMP/copy/gh"
  run env HOME="$TMP/home" PATH="$TMP/copy:$TMP/real:/usr/bin:/bin" "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
  [ -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper refuses to run when it has already re-entered itself" {
  _require_timeout
  # exec keeps the PID, so a wrapper that execs itself arrives with its own
  # PID already in the marker. Reproduce that hop without the PATH walk.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" "$TIMEOUT_BIN" 3 \
    bash -c 'export GH_MERGE_GUARD_PID=$$; exec "$1" --version' _ "$WRAPPER"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL:"* ]]
  [[ "$output" == *"$WRAPPER"* ]]
  [ ! -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper passes through when an ancestor set the marker" {
  _require_timeout
  # A gh extension or credential helper launched by the real gh calls gh by
  # name again. It inherits the ancestor's marker but runs under its own PID,
  # so the guard must not fire.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" GH_MERGE_GUARD_PID=1 \
    "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
}

# ---------------------------------------------------------------------------
# Passthrough behavior
# ---------------------------------------------------------------------------

@test "gh wrapper passes non-merge commands through" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # gh pr list requires auth + repo context. CI typically has neither
  # for this checkout (no GH_TOKEN, no remote tracking). Skip unless
  # we can prove auth works.
  if ! gh auth status >/dev/null 2>&1; then
    skip "gh not authenticated (no GH_TOKEN in env)"
  fi
  run "$WRAPPER" pr list --state closed --limit 1
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Merge guard
# ---------------------------------------------------------------------------

# A fake real gh that resolves `pr view` the way gh does: a PR URL names its own
# repository, else --repo, else GH_REPO, else the working directory's repository,
# here local/here. A base comes from $TMP/prs/<owner>/<repo>/<selector>, `current`
# standing for the current branch's PR, and a missing file is gh's "no pull
# requests found". It writes to stderr on every lookup, as gh's update notice
# does, so a guard that folds stderr into the base reads noise instead of `main`.
# Every other call only records its arguments: nothing in this suite can merge.
_fake_gh_with_prs() {
  cat >"$TMP/real/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" != "pr view" ]]; then
  printf '%s\n' "$*" >>"${FAKE_GH_MARKER:?}"
  exit 0
fi
shift 2
repo=${GH_REPO:-local/here}
selector=current
while (($#)); do
  case $1 in
    --repo) repo=${2:-${GH_REPO:-local/here}}; shift 2 ;;
    --json | --jq) shift 2 ;;
    --) shift ;;
    *) selector=$1; shift ;;
  esac
done
if [[ $selector =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)$ ]]; then
  repo=${BASH_REMATCH[1]}
  selector=${BASH_REMATCH[2]}
fi
echo "A new release of gh is available" >&2
cat "$TMP/prs/$repo/$selector"
EOF
  export TMP
}

_pr_base() {
  mkdir -p "$TMP/prs/$1"
  printf '%s\n' "$3" >"$TMP/prs/$1/$2"
}

# Prepending the fake is enough: the wrapper stops at the first gh that is not
# itself, and a merge command line never reads the PR freeze file under HOME.
_gh() {
  gh_status=0
  gh_output=$(env PATH="$TMP/alias:$TMP/real:$PATH" "$WRAPPER" "$@" 2>&1) || gh_status=$?
  echo "gh $*: status=$gh_status output=$gh_output"
}

_assert_refused() {
  [ "$gh_status" -eq 1 ]
  [[ "$gh_output" == *"Blocked:"*"$1"* ]]
  [ ! -e "$FAKE_GH_MARKER" ]
}

_assert_forwarded_verbatim() {
  [ "$gh_status" -eq 0 ]
  [ "$(cat "$FAKE_GH_MARKER")" = "$*" ]
  rm -f "$FAKE_GH_MARKER"
}

# The arguments name PR 46 of other/there while the working directory's own #46
# has the opposite base. The first half is the fail-open: #46 here targets dev,
# #46 there targets main, and a guard that reads this directory lets it through.
_expect_guard_reads_other_there() {
  _fake_gh_with_prs
  _pr_base local/here 46 dev
  _pr_base other/there 46 main
  _gh "$@"
  _assert_refused "merging into main"
  _pr_base local/here 46 main
  _pr_base other/there 46 dev
  _gh "$@"
  _assert_forwarded_verbatim "$@"
}

# The arguments name PR 46 of the working directory's own repository.
_expect_guard_reads_46_here() {
  _fake_gh_with_prs
  _pr_base local/here 46 main
  _gh "$@"
  _assert_refused "merging into main"
  _pr_base local/here 46 dev
  _gh "$@"
  _assert_forwarded_verbatim "$@"
}

@test "merge guard reads the repository from -R x after the number" {
  _expect_guard_reads_other_there pr merge 46 -R other/there --squash
}

@test "merge guard reads the repository from -R x before the number" {
  _expect_guard_reads_other_there pr merge -R other/there 46 --squash
}

@test "merge guard reads the repository from -R=x" {
  _expect_guard_reads_other_there pr merge 46 -R=other/there --squash
}

@test "merge guard reads the repository from -Rx" {
  _expect_guard_reads_other_there pr merge 46 -Rother/there --squash
}

@test "merge guard reads the repository from --repo x after the number" {
  _expect_guard_reads_other_there pr merge 46 --repo other/there --squash
}

@test "merge guard reads the repository from --repo x before the number" {
  _expect_guard_reads_other_there pr merge --repo other/there 46 --squash
}

@test "merge guard reads the repository from --repo=x" {
  _expect_guard_reads_other_there pr merge 46 --repo=other/there --squash
}

@test "merge guard reads the repository from a bundle of short flags" {
  _expect_guard_reads_other_there pr merge -sdR other/there 46
}

@test "merge guard reads the repository from GH_REPO" {
  GH_REPO=other/there _expect_guard_reads_other_there pr merge 46 --squash
}

@test "merge guard lets -R win over GH_REPO, as gh does" {
  _pr_base wrong/repo 46 dev
  GH_REPO=wrong/repo _expect_guard_reads_other_there pr merge 46 -R other/there --squash
}

@test "merge guard reads the repository from a full PR URL" {
  _expect_guard_reads_other_there pr merge https://github.com/other/there/pull/46 --squash
}

@test "merge guard lets a PR URL win over -R, as gh does" {
  _pr_base wrong/repo 46 dev
  _expect_guard_reads_other_there pr merge -R wrong/repo https://github.com/other/there/pull/46 --squash
}

@test "merge guard sees -R given between pr and merge" {
  _expect_guard_reads_other_there pr -R other/there merge 46 --squash
}

@test "merge guard sees --repo=x given between pr and merge" {
  _expect_guard_reads_other_there pr --repo=other/there merge 46 --squash
}

@test "merge guard sees -R given before pr" {
  _expect_guard_reads_other_there -R other/there pr merge 46 --squash
}

@test "merge guard finds the number when a flag before merge swallows it" {
  _expect_guard_reads_46_here pr --squash 46 merge
}

@test "merge guard finds the number when a flag before pr swallows it" {
  _expect_guard_reads_46_here --squash 46 pr merge
}

@test "merge guard does not take a flag's value for the PR" {
  local value_flags=(-t --subject -b --body -F --body-file -A --author-email --match-head-commit)
  local flag
  for flag in "${value_flags[@]}"; do
    _expect_guard_reads_46_here pr merge "$flag" hello 46 --squash
  done
}

@test "merge guard does not take an attached flag value for the PR" {
  _expect_guard_reads_46_here pr merge --subject=hello 46 --squash
  _expect_guard_reads_46_here pr merge -thello 46 --squash
  _expect_guard_reads_46_here pr merge -dt hello 46
}

@test "merge guard reads a PR named after --" {
  _expect_guard_reads_46_here pr merge --squash -- 46
}

@test "merge guard reads the current branch's PR when none is named" {
  _fake_gh_with_prs
  _pr_base local/here current main
  _gh pr merge --squash
  _assert_refused "merging into main"
  _pr_base local/here current dev
  _gh pr merge --squash
  _assert_forwarded_verbatim pr merge --squash
}

@test "merge guard refuses master as it refuses main" {
  _fake_gh_with_prs
  _pr_base other/there 46 master
  _gh pr merge 46 -R other/there
  _assert_refused "merging into master"
}

@test "merge guard fails closed when the PR cannot be found" {
  _fake_gh_with_prs
  _gh pr merge 46 -R other/there --squash
  _assert_refused "cannot determine"
}

@test "merge guard fails closed when the lookup answers with no base" {
  _fake_gh_with_prs
  _pr_base other/there 46 ''
  _gh pr merge 46 -R other/there --squash
  _assert_refused "cannot determine"
}

@test "merge guard fails closed on a flag it does not know" {
  _fake_gh_with_prs
  _pr_base local/here 46 dev
  _gh pr merge --flag-from-a-later-gh hello 46
  _assert_refused "--flag-from-a-later-gh"
}

@test "merge guard fails closed on more than one PR" {
  _fake_gh_with_prs
  _pr_base local/here 46 dev
  _pr_base local/here 47 main
  _gh pr merge 46 47
  _assert_refused "47"
}

@test "merge guard lets merge help through with no lookup" {
  _fake_gh_with_prs
  _gh pr merge --help
  _assert_forwarded_verbatim pr merge --help
  _gh pr merge 46 -h
  _assert_forwarded_verbatim pr merge 46 -h
}

@test "merge guard does not read --help as help when it is a flag's value" {
  _expect_guard_reads_46_here pr merge -t --help 46
}

@test "merge guard does not read --help as help after --" {
  _fake_gh_with_prs
  _pr_base local/here --help main
  _gh pr merge -- --help
  _assert_refused "merging into main"
}

@test "merge guard ignores a command line that only mentions pr merge" {
  _fake_gh_with_prs
  _gh issue comment 5 --body 'the pr merge failed'
  _assert_forwarded_verbatim issue comment 5 --body 'the pr merge failed'
  _gh search prs 'pr merge' --repo other/there
  _assert_forwarded_verbatim search prs 'pr merge' --repo other/there
}

@test "merge guard ignores a pr subcommand that has merge as a value" {
  _fake_gh_with_prs
  _gh pr comment 46 --body merge
  _assert_forwarded_verbatim pr comment 46 --body merge
  _gh pr --body merge comment 46
  _assert_forwarded_verbatim pr --body merge comment 46
}

@test "gh wrapper is executable" {
  [ -x "$WRAPPER" ]
}

@test "gh wrapper uses bash" {
  head -1 "$WRAPPER" | grep -q "bash"
}
