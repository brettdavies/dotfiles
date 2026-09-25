#!/usr/bin/env bats
# Tests for sync-dev-after-release.sh path discovery.
#
# The backport used to copy a hardcoded CHANGELOG.md, so any other file the
# release branch touched stayed on main alone and the next overlay restored
# dev's copy over it. These cases pin the discovery that replaced the constant:
# what gets adopted, what is withheld as contested, and what is excluded because
# it belongs to dev by design.
#
# A local bare repo stands in for origin and `gh` is stubbed, so nothing here
# reaches the network.

setup() {
  # An inherited GIT_DIR outranks `-C`, so every git call below would retarget
  # whichever repo the caller was in. Git exports these to hooks, so a
  # hook-invoked run reaches this file with them set.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  REPO_SRC="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
  ORIGIN="$TMP/origin.git"
  WORK="$TMP/work"
  BIN="$TMP/bin"

  # `gh release view --json isDraft` must report a published release, and
  # `gh pr create` leaves a copy of the body it was handed.
  mkdir -p "$BIN"
  export PR_BODY_COPY="$TMP/pr-body.md"
  cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) echo false ;;
  *"pr create"*)
    while [[ $# -gt 0 ]]; do [[ "$1" == "--body-file" ]] && cp "$2" "$PR_BODY_COPY"; shift; done ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$BIN/gh"
  PATH="$BIN:$PATH"

  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK"
  git -C "$WORK" symbolic-ref HEAD refs/heads/main
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name Test
  git -C "$WORK" config commit.gpgsign false
  # The user gitconfig sets tag.gpgsign, which turns a bare `git tag` into an
  # annotated signed tag and fails for want of a message.
  git -C "$WORK" config tag.gpgsign false

  # The script resolves the guarded set through the real workflow + resolver.
  mkdir -p "$WORK/scripts/release" "$WORK/.github/workflows"
  cp "$REPO_SRC/scripts/release/guarded-paths.sh" "$WORK/scripts/release/"
  cp "$REPO_SRC/.github/workflows/guard-main-docs.yml" "$WORK/.github/workflows/"
  cp "$REPO_SRC/scripts/sync-dev-after-release.sh" "$WORK/scripts/"

  # --- the previous release: main and dev agree here ---
  mkdir -p "$WORK/docs/plans" "$WORK/stow/tmuxinator"
  echo "old changelog" >"$WORK/CHANGELOG.md"
  echo "readme v1" >"$WORK/README.md"
  echo "settings v1" >"$WORK/settings.json"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "release: 2026.01.01"
  git -C "$WORK" tag 2026.01.01
  git -C "$WORK" push -q -u origin main
  git -C "$WORK" push -q --tags

  git -C "$WORK" branch dev
  git -C "$WORK" push -q -u origin dev
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Move main to a new release, mirroring the overlay: dev's tree plus whatever
# the release branch edited on top.
_release_main() {
  git -C "$WORK" switch -q main
  "$@"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "release: 2026.02.02"
  git -C "$WORK" tag 2026.02.02
  git -C "$WORK" push -q origin main
  git -C "$WORK" push -q --tags
  git -C "$WORK" switch -q dev
}

_run_sync() {
  cd "$WORK" || return 1
  run env PATH="$PATH" bash scripts/sync-dev-after-release.sh "$@"
}

# _run_sync_regen EXIT STDERR ARGS...: _run_sync with the stub generator set to
# exit EXIT after printing STDERR.
_run_sync_regen() {
  local regen_exit="$1" regen_stderr="$2"
  shift 2
  cd "$WORK" || return 1
  run env PATH="$PATH" REGEN_EXIT="$regen_exit" REGEN_STDERR="$regen_stderr" \
    bash scripts/sync-dev-after-release.sh "$@"
}

@test "adopts a file only the release branch changed" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-prep"* ]]
  [[ "$output" == *"CHANGELOG.md"* ]]
}

@test "withholds a file both branches changed since the previous tag" {
  # dev moves README.md, and so does the release branch.
  git -C "$WORK" switch -q dev
  echo "readme dev" >"$WORK/README.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "docs: dev edits readme"
  git -C "$WORK" push -q origin dev

  _release_main bash -c "echo 'readme release' > '$WORK/README.md'"
  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"contested"* ]]
  [[ "$output" == *"README.md"* ]]
  [[ "$output" == *"NOT adopted"* ]]
}

@test "--include-contested adopts what was otherwise withheld" {
  git -C "$WORK" switch -q dev
  echo "readme dev" >"$WORK/README.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "docs: dev edits readme"
  git -C "$WORK" push -q origin dev

  _release_main bash -c "echo 'readme release' > '$WORK/README.md'"
  _run_sync 2026.02.02 --include-contested --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"per --include-contested"* ]]
  [[ "$output" == *"README.md"* ]]
}

@test "discovers a file the release branch deleted" {
  # The 2026.09.14 regression: dev added a config after the previous release and
  # the release branch deleted it. A CHANGELOG-only backport missed it entirely.
  git -C "$WORK" switch -q dev
  echo "session config" >"$WORK/stow/tmuxinator/paxel.yml"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "feat: add a session config"
  git -C "$WORK" push -q origin dev

  # The overlay takes dev's tree, then the release branch drops the config. main
  # never had it, so the deletion shows up only as a dev-vs-main difference.
  git -C "$WORK" switch -q main
  git -C "$WORK" checkout -q dev -- .
  rm -f "$WORK/stow/tmuxinator/paxel.yml"
  echo "new changelog" >"$WORK/CHANGELOG.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "release: 2026.02.02"
  git -C "$WORK" tag 2026.02.02
  git -C "$WORK" push -q origin main
  git -C "$WORK" push -q --tags
  git -C "$WORK" switch -q dev

  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"paxel.yml"* ]]
}

@test "never proposes a guarded path" {
  # docs/plans lives on dev by design; main lacking it is correct, so adopting
  # main's state would delete it from dev.
  git -C "$WORK" switch -q dev
  echo "a plan" >"$WORK/docs/plans/some-plan.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "docs: add a plan"
  git -C "$WORK" push -q origin dev

  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"some-plan.md"* ]]
}

@test "exits without a branch when dev already matches main" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"

  # Simulate the backport having already merged into dev.
  git -C "$WORK" switch -q dev
  git -C "$WORK" checkout -q origin/main -- CHANGELOG.md
  git -C "$WORK" commit -q -m "chore(release): backport"
  git -C "$WORK" push -q origin dev

  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in sync"* ]]
  run git -C "$WORK" rev-parse --verify --quiet chore/sync-dev-after-2026.02.02
  [ "$status" -ne 0 ]
}

@test "--only narrows the set to the named path" {
  git -C "$WORK" switch -q dev
  echo "readme dev" >"$WORK/README.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "docs: dev edits readme"
  git -C "$WORK" push -q origin dev

  _release_main bash -c "echo 'readme release' > '$WORK/README.md'; echo 'new changelog' > '$WORK/CHANGELOG.md'"

  # README.md and CHANGELOG.md both diverged; only the changelog is named.
  _run_sync 2026.02.02 --only CHANGELOG.md
  [ "$status" -eq 0 ]

  run git -C "$WORK" show --name-only --format= "chore/sync-dev-after-2026.02.02"
  [[ "$output" == *"CHANGELOG.md"* ]]
  [[ "$output" != *"README.md"* ]]
}

@test "--only refuses a path that is not a diverged candidate" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync 2026.02.02 --only docs/plans/some-plan.md
  [ "$status" -eq 64 ]
  [[ "$output" == *"not a diverged, unguarded path"* ]]
  [ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = dev ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
  run git -C "$WORK" rev-parse --verify --quiet chore/sync-dev-after-2026.02.02
  [ "$status" -ne 0 ]
  # A rerun is refused only for the same reason, not for a leftover branch.
  _run_sync 2026.02.02 --only docs/plans/some-plan.md
  [ "$status" -eq 64 ]
}

@test "rejects an unknown flag" {
  _run_sync 2026.02.02 --bogus
  [ "$status" -eq 64 ]
}

@test "the backport commit carries every diverged path, not just CHANGELOG.md" {
  # The end-to-end regression guard. A hardcoded CHANGELOG-only backport commits
  # one file and leaves the rest on main, which is how the 2026.09.14 release
  # stranded a stow payload and three session configs.
  git -C "$WORK" switch -q dev
  echo "session config" >"$WORK/stow/tmuxinator/paxel.yml"
  echo "accounts v1" >"$WORK/settings.json"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "feat: add a session config"
  git -C "$WORK" push -q origin dev

  # The release branch: dev's tree, minus the config, with settings reverted.
  git -C "$WORK" switch -q main
  git -C "$WORK" checkout -q dev -- .
  rm -f "$WORK/stow/tmuxinator/paxel.yml"
  echo "settings v1" >"$WORK/settings.json"
  echo "new changelog" >"$WORK/CHANGELOG.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "release: 2026.02.02"
  git -C "$WORK" tag 2026.02.02
  git -C "$WORK" push -q origin main
  git -C "$WORK" push -q --tags
  git -C "$WORK" switch -q dev

  _run_sync 2026.02.02 --include-contested
  [ "$status" -eq 0 ]

  run git -C "$WORK" show --stat --name-status "chore/sync-dev-after-2026.02.02"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGELOG.md"* ]]
  [[ "$output" == *"D"*"paxel.yml"* ]]
  [[ "$output" == *"settings.json"* ]]
}


# --- The PR body and exits before the commit -------------------------------

@test "an annotated tag's PR body cites the released commit" {
  git -C "$WORK" switch -q main
  echo "new changelog" >"$WORK/CHANGELOG.md"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "release: 2026.02.02"
  git -C "$WORK" tag -a -m 2026.02.02 2026.02.02
  git -C "$WORK" push -q origin main
  git -C "$WORK" push -q --tags
  git -C "$WORK" switch -q dev
  commit_short="$(git -C "$WORK" rev-parse --short '2026.02.02^{commit}')"
  tag_object_short="$(git -C "$WORK" rev-parse --short 2026.02.02)"
  [ "$commit_short" != "$tag_object_short" ]

  _run_sync 2026.02.02
  [ "$status" -eq 0 ]
  grep -qF "at \`$commit_short\`" "$PR_BODY_COPY"
  run grep -qF "$tag_object_short" "$PR_BODY_COPY"
  [ "$status" -ne 0 ]
}

@test "a dry run cuts no branch at any point and leaves dev clean" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
  [ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = dev ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
  run git -C "$WORK" rev-parse --verify --quiet chore/sync-dev-after-2026.02.02
  [ "$status" -ne 0 ]
  [[ "$(git -C "$WORK" reflog)" != *"chore/sync-dev-after-2026.02.02"* ]]
}

@test "a dry run succeeds beside a prior run's sync branch and leaves it untouched" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  git -C "$WORK" branch chore/sync-dev-after-2026.02.02 origin/dev
  prior="$(git -C "$WORK" rev-parse chore/sync-dev-after-2026.02.02)"
  _run_sync 2026.02.02 --dry-run
  [ "$status" -eq 0 ]
  [ "$(git -C "$WORK" rev-parse chore/sync-dev-after-2026.02.02)" = "$prior" ]
  [ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = dev ]
}

@test "a failed backport commit returns to dev and deletes the sync branch" {
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  mkdir -p "$TMP/hooks"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/hooks/pre-commit"
  chmod +x "$TMP/hooks/pre-commit"
  git -C "$WORK" config core.hooksPath "$TMP/hooks"

  _run_sync 2026.02.02
  [ "$status" -ne 0 ]
  [ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = dev ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
  run git -C "$WORK" rev-parse --verify --quiet chore/sync-dev-after-2026.02.02
  [ "$status" -ne 0 ]
}

# --- Post-sync regen check -----------------------------------------------------

# _vendor_regen_stub: a stub generator on main and dev that records each call
# and prints $REGEN_STDERR, plus a stub git-cliff on PATH.
_vendor_regen_stub() {
  printf '#!/usr/bin/env bash\n' >"$BIN/git-cliff"
  chmod +x "$BIN/git-cliff"
  git -C "$WORK" switch -q main
  cat >"$WORK/scripts/generate-changelog.py" <<'STUB'
#!/usr/bin/env bash
[[ -z "${REGEN_STDERR:-}" ]] || printf '%s\n' "$REGEN_STDERR" >&2
exit "${REGEN_EXIT:-0}"
STUB
  chmod +x "$WORK/scripts/generate-changelog.py"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "vendor the generator"
  git -C "$WORK" push -q origin main
  git -C "$WORK" switch -q dev
  git -C "$WORK" merge -q --ff-only origin/main
  git -C "$WORK" push -q origin dev
}

@test "a regen error warns with its reason, not a drift claim" {
  _vendor_regen_stub
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync_regen 1 'error: cliff.toml not found' 2026.02.02
  [ "$status" -eq 0 ]
  [[ "$output" == *"error: cliff.toml not found"* ]]
  [[ "$output" != *"PR bodies have drifted"* ]]
}

@test "a regen crash warns with the traceback's last line" {
  _vendor_regen_stub
  _release_main bash -c "echo 'new changelog' > '$WORK/CHANGELOG.md'"
  _run_sync_regen 1 'Traceback (most recent call last):
  File "scripts/generate-changelog.py", line 196, in fetch_pr
subprocess.TimeoutExpired: Command gh api timed out after 10 seconds' 2026.02.02
  [ "$status" -eq 0 ]
  [[ "$output" == *"subprocess.TimeoutExpired: Command gh api timed out after 10 seconds"* ]]
  [[ "$output" != *"Traceback (most recent call last)"* ]]
}
